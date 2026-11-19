%% Scripted WebSocket demo: three users on three WebSocket connections use
%% every engine function, and each live push the engine should deliver is
%% checked. The raw JSON frames are printed (">>" sent, "<<" received).
%%
%%   ./run.sh wsdemo [ws://localhost:8080/ws]
%%
%% Exits with status 0 when every request and push behaved as expected.
-module(reddit_ws_demo).
-export([main/1]).

main([]) -> main(["ws://localhost:8080/ws"]);
main([Url | _]) ->
    io:setopts([{encoding, unicode}]),
    application:ensure_all_started(public_key),
    put(failures, 0),
    step("alice, bob and carol open WebSocket connections to ~s", [Url]),
    [A, B, C] = [connect(Url) || _ <- [1, 2, 3]],
    {KeyA, PrivA} = reddit_signature:generate_key_pair(),
    {KeyB, PrivB} = reddit_signature:generate_key_pair(),

    step("register (alice and bob upload RSA-2048 public keys)", []),
    Sfx = free_suffix(A, KeyA, 0),
    Alice = <<"alice", Sfx/binary>>, Bob = <<"bob", Sfx/binary>>,
    Carol = <<"carol", Sfx/binary>>, Sub = <<"websockets", Sfx/binary>>,
    [reddit_ws_client:set_trace(Conn, true, Name)
     || {Conn, Name} <- [{A, Alice}, {B, Bob}, {C, Carol}]],
    expect(B, register, #{user => Bob, public_key => KeyB}),
    expect(C, register, #{user => Carol}),

    step("log in: each connection becomes that user's live session", []),
    [expect(Conn, login, #{user => Name})
     || {Conn, Name} <- [{A, Alice}, {B, Bob}, {C, Carol}]],

    step("alice creates r/~ts, bob and carol join it", [Sub]),
    expect(A, create_sub, #{sub => Sub}),
    expect(B, join_sub, #{sub => Sub}),
    expect(C, join_sub, #{sub => Sub}),

    step("alice posts a signed text post -> bob and carol get a live push", []),
    Title = <<"Hello over WebSocket">>,
    Body = <<"This post was sent as a JSON frame.">>,
    Sig = reddit_signature:sign(PrivA, reddit_signature:payload(Alice, Sub, Title, Body)),
    #{<<"id">> := Post} = expect(A, post, #{sub => Sub, title => Title, body => Body,
                                            signature => Sig}),
    push(B, Bob, <<"new_post">>),
    push(C, Carol, <<"new_post">>),

    step("bob comments -> alice is notified of the reply", []),
    #{<<"id">> := Cb} = expect(B, comment, #{parent_id => Post, body => <<"Nice post!">>}),
    push(A, Alice, <<"reply">>),

    step("carol replies to bob's comment (nested) -> bob is notified", []),
    expect(C, comment, #{parent_id => Cb, body => <<"Agreed with bob.">>}),
    push(B, Bob, <<"reply">>),

    step("votes: bob and carol upvote the post; alice downvotes bob's comment, "
         "then withdraws the vote", []),
    expect(B, vote, #{item_id => Post, direction => <<"up">>}),
    expect(C, vote, #{item_id => Post, direction => <<"up">>}),
    expect(A, vote, #{item_id => Cb, direction => <<"down">>}),
    expect(A, vote, #{item_id => Cb, direction => <<"none">>}),

    step("bob downloads the post with its comment tree and alice's public key", []),
    PostView = expect(B, get_post, #{post_id => Post}),
    reddit_ws_cli:print_post(PostView),
    expect(B, get_public_key, #{user => Alice}),

    step("bob reposts it with his own signature -> alice and carol get a push", []),
    RepostSig = reddit_signature:sign(PrivB, reddit_signature:payload(Bob, Sub, Title, Body)),
    expect(B, repost, #{post_id => Post, sub => Sub, signature => RepostSig}),
    push(A, Alice, <<"new_post">>),
    push(C, Carol, <<"new_post">>),

    step("carol reads her feed sorted hot, new and top", []),
    [begin
         Posts = expect(C, get_feed, #{sort => Sort, limit => 5}),
         io:format("  feed (~s):~n", [Sort]),
         [reddit_ws_cli:print_post_line(P) || P <- Posts]
     end || Sort <- [<<"hot">>, <<"new">>, <<"top">>]],

    step("karma", []),
    expect(A, get_karma, #{}),
    expect(C, get_karma, #{user => Bob}),

    step("direct messages: alice -> bob (live), bob reads and replies (live)", []),
    expect(A, send_dm, #{to => Bob, body => <<"Thanks for the comment!">>}),
    push(B, Bob, <<"dm">>),
    [#{<<"id">> := Dm} | _] = expect(B, get_dms, #{limit => 5}),
    expect(B, reply_dm, #{dm_id => Dm, body => <<"Any time.">>}),
    push(A, Alice, <<"dm">>),
    reddit_ws_cli:print_dms(expect(A, get_dms, #{})),

    step("errors come back as JSON too", []),
    expect(C, leave_sub, #{sub => Sub}),
    expect_error(C, post, #{sub => Sub, title => <<"x">>, body => <<"y">>}, <<"not_member">>),
    expect_error(C, post, #{sub => Sub, title => <<"forged">>, body => <<"y">>,
                            signature => Sig}, <<"no_public_key">>),
    expect_error(A, post, #{sub => Sub, title => <<"forged">>, body => <<"tampered">>,
                            signature => Sig}, <<"invalid_signature">>),
    expect_error(C, fly, #{}, <<"unknown_action">>),
    Anon = connect(Url),
    reddit_ws_client:set_trace(Anon, true, <<"anon">>),
    expect_error(Anon, get_feed, #{}, <<"not_logged_in">>),

    step("log out and close", []),
    expect(C, logout, #{}),
    expect(B, send_dm, #{to => Carol, body => <<"carol is offline now">>}),
    no_push(C, Carol),
    [reddit_ws_client:close(Conn) || Conn <- [A, B, C, Anon]],
    timer:sleep(200),

    case get(failures) of
        0 -> io:format("~nWebSocket demo finished: every request and push worked.~n"),
             halt(0);
        N -> io:format("~nWebSocket demo finished with ~b failure(s).~n", [N]),
             halt(1)
    end.

%% ---------------------------------------------------------------- helpers

connect(Url) ->
    case reddit_ws_client:connect(Url) of
        {ok, Conn} -> Conn;
        {error, Why} ->
            io:format("cannot connect to ~s: ~p~n", [Url, Why]),
            halt(1)
    end.

%% The demo can run again against the same server: if "alice" is taken,
%% use alice_1, bob_1, ... instead.
free_suffix(Conn, Key, N) ->
    Sfx = case N of 0 -> <<>>; _ -> <<"_", (integer_to_binary(N))/binary>> end,
    reddit_ws_client:set_trace(Conn, true, <<"alice", Sfx/binary>>),
    case reddit_ws_client:request(Conn, register,
                                  #{user => <<"alice", Sfx/binary>>, public_key => Key}) of
        ok -> Sfx;
        {error, <<"already_registered">>} -> free_suffix(Conn, Key, N + 1)
    end.

step(Fmt, Args) ->
    N = case get(step) of undefined -> 1; S -> S + 1 end,
    put(step, N),
    io:format("~n== ~b. " ++ Fmt ++ "~n", [N | Args]).

expect(Conn, Action, Params) ->
    case reddit_ws_client:request(Conn, Action, Params) of
        ok -> ok;
        {ok, Data} -> Data;
        {error, Why} -> fail("~p failed: ~p", [Action, Why]), undefined
    end.

expect_error(Conn, Action, Params, Expected) ->
    case reddit_ws_client:request(Conn, Action, Params) of
        {error, Expected} -> ok;
        Other -> fail("~p: expected error ~s, got ~p", [Action, Expected, Other])
    end.

push(Conn, Name, Type) ->
    receive
        {reddit_ws_push, Conn, Type, Data} ->
            reddit_ws_cli:print_push(<<"[", Name/binary, "] ">>, Type, Data)
    after 2000 ->
        fail("~ts did not receive a ~s push", [Name, Type])
    end.

no_push(Conn, Name) ->
    receive
        {reddit_ws_push, Conn, Type, _} -> fail("~ts got a ~s push while logged out", [Name, Type])
    after 300 ->
        io:format("  (no push for ~ts while logged out - correct)~n", [Name])
    end.

fail(Fmt, Args) ->
    put(failures, get(failures) + 1),
    io:format("  !! FAILED: " ++ Fmt ++ "~n", Args).
