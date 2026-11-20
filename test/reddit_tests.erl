%% Functional tests for the engine. Run with:  run.ps1 test   (or ./run.sh test)
-module(reddit_tests).
-include_lib("eunit/include/eunit.hrl").

-define(U(N), <<N>>).

ops_test_() ->
    {foreach,
     fun() -> {ok, _} = reddit_store:start(), ok end,
     fun(_) -> reddit_store:stop() end,
     [fun accounts/0,
      fun subreddits/0,
      fun posts_and_feed/0,
      fun nested_comments/0,
      fun votes_and_karma/0,
      fun reposts/0,
      fun signed_posts/0,
      fun direct_messages/0,
      fun search/0]}.

engine_test_() ->
    {setup,
     fun() -> ok = reddit_engine:start(2) end,
     fun(_) -> reddit_engine:stop() end,
     [fun live_notifications/0]}.

-define(WS_PORT, 18089).

websocket_test_() ->
    {setup,
     fun() ->
             ok = reddit_engine:start(2, #{push_posts => true}),
             {ok, _} = reddit_http:start(?WS_PORT),
             ok
     end,
     fun(_) -> reddit_http:stop(), reddit_engine:stop() end,
     [fun websocket_session/0, fun burst_connections/0, fun rest_session/0]}.

users(Names) -> [ok = reddit_ops:register_user(N) || N <- Names].

accounts() ->
    ?assertEqual(ok, reddit_ops:register_user(<<"alice">>)),
    ?assertEqual({error, already_registered}, reddit_ops:register_user(<<"alice">>)),
    ?assertEqual({error, invalid_name}, reddit_ops:register_user(<<>>)),
    ?assertEqual({ok, #{post_karma => 0, comment_karma => 0, total => 0}},
                 reddit_ops:get_karma(<<"alice">>)),
    ?assertEqual({error, no_such_user}, reddit_ops:get_karma(<<"nobody">>)).

subreddits() ->
    users([<<"alice">>, <<"bob">>]),
    ?assertEqual(ok, reddit_ops:create_sub(<<"alice">>, <<"erlang">>)),
    ?assertEqual({error, sub_exists}, reddit_ops:create_sub(<<"bob">>, <<"erlang">>)),
    ?assertEqual(1, reddit_ops:sub_member_count(<<"erlang">>)),   % creator joined
    ?assertEqual(ok, reddit_ops:join_sub(<<"bob">>, <<"erlang">>)),
    ?assertEqual({error, already_member}, reddit_ops:join_sub(<<"bob">>, <<"erlang">>)),
    ?assertEqual(2, reddit_ops:sub_member_count(<<"erlang">>)),
    ?assertEqual([<<"alice">>, <<"bob">>], reddit_ops:sub_members(<<"erlang">>)),
    ?assertEqual(ok, reddit_ops:leave_sub(<<"bob">>, <<"erlang">>)),
    ?assertEqual({error, not_member}, reddit_ops:leave_sub(<<"bob">>, <<"erlang">>)),
    ?assertEqual(1, reddit_ops:sub_member_count(<<"erlang">>)),
    ?assertEqual({error, no_such_sub}, reddit_ops:join_sub(<<"bob">>, <<"nope">>)).

posts_and_feed() ->
    users([<<"alice">>, <<"bob">>]),
    ok = reddit_ops:create_sub(<<"alice">>, <<"a">>),
    ok = reddit_ops:create_sub(<<"alice">>, <<"b">>),
    ok = reddit_ops:create_sub(<<"bob">>, <<"c">>),
    ?assertEqual({error, not_member},
                 reddit_ops:create_post(<<"bob">>, <<"a">>, <<"t">>, <<"x">>)),
    {ok, P1} = reddit_ops:create_post(<<"alice">>, <<"a">>, <<"first">>, <<"x">>),
    {ok, P2} = reddit_ops:create_post(<<"alice">>, <<"b">>, <<"second">>, <<"y">>),
    {ok, _P3} = reddit_ops:create_post(<<"bob">>, <<"c">>, <<"other">>, <<"z">>),
    {ok, Feed} = reddit_ops:get_feed(<<"alice">>, 10, new),
    ?assertEqual([P2, P1], [Id || #{id := Id} <- Feed]),     % newest first, no sub c
    ok = reddit_ops:leave_sub(<<"alice">>, <<"b">>),
    {ok, Feed2} = reddit_ops:get_feed(<<"alice">>, 10, hot),
    ?assertEqual([P1], [Id || #{id := Id} <- Feed2]),
    {ok, Feed3} = reddit_ops:get_feed(<<"bob">>, 1, new),
    ?assertEqual(1, length(Feed3)).

nested_comments() ->
    users([<<"alice">>, <<"bob">>]),
    ok = reddit_ops:create_sub(<<"alice">>, <<"a">>),
    {ok, P} = reddit_ops:create_post(<<"alice">>, <<"a">>, <<"t">>, <<"b">>),
    {ok, C1} = reddit_ops:comment(<<"bob">>, P, <<"top level">>),
    {ok, C2} = reddit_ops:comment(<<"alice">>, C1, <<"reply">>),
    {ok, C3} = reddit_ops:comment(<<"bob">>, C2, <<"reply to reply">>),
    {ok, C4} = reddit_ops:comment(<<"alice">>, P, <<"second top level">>),
    ?assertEqual({error, no_such_parent}, reddit_ops:comment(<<"bob">>, 99999, <<"x">>)),
    {ok, #{num_comments := 4, comments := Tree}} = reddit_ops:get_post(P),
    ?assertEqual(lists:sort([C1, C4]), lists:sort([Id || #{id := Id} <- Tree])),
    [#{replies := [#{id := C2, depth := 2, replies := [#{id := C3, depth := 3}]}]}] =
        [T || #{id := Id} = T <- Tree, Id =:= C1].

votes_and_karma() ->
    users([<<"alice">>, <<"bob">>, <<"carol">>]),
    ok = reddit_ops:create_sub(<<"alice">>, <<"a">>),
    {ok, P} = reddit_ops:create_post(<<"alice">>, <<"a">>, <<"t">>, <<"b">>),
    {ok, C} = reddit_ops:comment(<<"alice">>, P, <<"c">>),
    ok = reddit_ops:vote(<<"bob">>, P, up),
    ok = reddit_ops:vote(<<"carol">>, P, up),
    ok = reddit_ops:vote(<<"bob">>, P, up),                    % repeat: no effect
    ?assertMatch(#{up := 2, down := 0, score := 2}, reddit_ops:post_view(P)),
    ok = reddit_ops:vote(<<"carol">>, P, down),                % switch: -2
    ?assertMatch(#{up := 1, down := 1, score := 0}, reddit_ops:post_view(P)),
    ok = reddit_ops:vote(<<"bob">>, C, down),
    ok = reddit_ops:vote(<<"alice">>, P, up),                  % self vote: score only
    {ok, K} = reddit_ops:get_karma(<<"alice">>),
    ?assertEqual(#{post_karma => 0, comment_karma => -1, total => -1}, K),
    ok = reddit_ops:vote(<<"bob">>, C, none),                  % withdraw
    ?assertMatch({ok, #{comment_karma := 0}}, reddit_ops:get_karma(<<"alice">>)),
    ?assertEqual({error, no_such_item}, reddit_ops:vote(<<"bob">>, 99999, up)),
    ?assertEqual({error, bad_direction}, reddit_ops:vote(<<"bob">>, P, sideways)).

reposts() ->
    users([<<"alice">>, <<"bob">>]),
    ok = reddit_ops:create_sub(<<"alice">>, <<"a">>),
    ok = reddit_ops:create_sub(<<"bob">>, <<"b">>),
    {ok, P} = reddit_ops:create_post(<<"alice">>, <<"a">>, <<"orig">>, <<"text">>),
    {ok, R1} = reddit_ops:repost(<<"bob">>, <<"b">>, P),
    {ok, R2} = reddit_ops:repost(<<"bob">>, <<"b">>, R1),      % repost of a repost
    ?assertMatch(#{repost_of := P, title := <<"orig">>, sub := <<"b">>},
                 reddit_ops:post_view(R1)),
    ?assertMatch(#{repost_of := P}, reddit_ops:post_view(R2)).

signed_posts() ->
    {Pem, Private} = reddit_signature:generate_key_pair(),
    ?assertEqual(ok, reddit_ops:register_user(<<"alice">>, Pem)),
    ?assertMatch({ok, #{public_key := Pem}}, reddit_ops:get_public_key(<<"alice">>)),
    ok = reddit_ops:create_sub(<<"alice">>, <<"signed">>),
    User = <<"alice">>,
    Sub = <<"signed">>,
    Title = <<"signed post">>,
    Body = <<"verified by RSA-SHA256">>,
    Payload = reddit_signature:payload(User, Sub, Title, Body),
    Signature = reddit_signature:sign(Private, Payload),
    {ok, PostId} = reddit_ops:create_signed_post(User, Sub, Title, Body, Signature),
    ?assertMatch(#{signature_status := valid, signature := Signature},
                 reddit_ops:post_view(PostId)),
    ?assertEqual({error, invalid_signature},
                 reddit_ops:create_signed_post(User, Sub, <<"bad">>, Body,
                                               <<"not-a-signature">>)).

direct_messages() ->
    users([<<"alice">>, <<"bob">>, <<"carol">>]),
    {ok, D1} = reddit_ops:send_dm(<<"alice">>, <<"bob">>, <<"hi bob">>),
    {ok, [#{id := D1, from := <<"alice">>, body := <<"hi bob">>}]} =
        reddit_ops:get_dms(<<"bob">>, 10),
    ?assertEqual({error, not_recipient}, reddit_ops:reply_dm(<<"carol">>, D1, <<"x">>)),
    {ok, D2} = reddit_ops:reply_dm(<<"bob">>, D1, <<"hi alice">>),
    {ok, [#{id := D2, from := <<"bob">>, reply_to := D1}]} =
        reddit_ops:get_dms(<<"alice">>, 10),
    ?assertEqual({error, no_such_user}, reddit_ops:send_dm(<<"alice">>, <<"zed">>, <<"x">>)).

%% Through the engine workers: a connected user gets pushed DMs and replies.
live_notifications() ->
    W = fun(U) -> reddit_engine:worker_name(erlang:phash2(U, 2) + 1) end,
    Call = fun(U, Req) -> gen_server:call(W(U), Req) end,
    ok = Call(<<"eve">>, {register, <<"eve">>}),
    ok = Call(<<"dan">>, {register, <<"dan">>}),
    ok = Call(<<"eve">>, {connect, <<"eve">>, self()}),
    {ok, Dm} = Call(<<"dan">>, {send_dm, <<"dan">>, <<"eve">>, <<"hello">>}),
    receive {reddit_push, {dm, #{id := Dm, from := <<"dan">>}}} -> ok
    after 1000 -> error(no_dm_push)
    end,
    ok = Call(<<"eve">>, {create_sub, <<"eve">>, <<"s">>}),
    ok = Call(<<"dan">>, {join_sub, <<"dan">>, <<"s">>}),
    {ok, P} = Call(<<"eve">>, {post, <<"eve">>, <<"s">>, <<"t">>, <<"b">>}),
    {ok, C} = Call(<<"dan">>, {comment, <<"dan">>, P, <<"nice">>}),
    receive {reddit_push, {reply, #{comment_id := C, parent := P}}} -> ok
    after 1000 -> error(no_reply_push)
    end,
    ok = Call(<<"eve">>, {disconnect, <<"eve">>}),
    {ok, _} = Call(<<"dan">>, {send_dm, <<"dan">>, <<"eve">>, <<"offline">>}),
    receive {reddit_push, _} -> error(pushed_while_offline)
    after 200 -> ok
    end,
    ?assertMatch({ok, [_, _]}, Call(<<"eve">>, {get_dms, <<"eve">>, 10})).

%% ---------------------------------------------------------- JSON, WebSocket

json_decode_test() ->
    ?assertEqual({ok, #{<<"a">> => [1, -2.5, true, false, null, <<"x\"y\n", 16#e9/utf8>>],
                        <<"b">> => #{}}},
                 reddit_json:decode(<<" {\"a\": [1, -2.5, true, false, null, "
                                      "\"x\\\"y\\n\\u00e9\"], \"b\": {}} ">>)),
    ?assertEqual({ok, <<16#1F600/utf8>>}, reddit_json:decode(<<"\"\\ud83d\\ude00\"">>)),
    ?assertEqual({ok, 1000.0}, reddit_json:decode(<<"1e3">>)),
    [?assertEqual({error, invalid_json}, reddit_json:decode(Bad))
     || Bad <- [<<"{\"a\":1,}">>, <<"[1,]">>, <<"tru">>, <<"\"open">>, <<"1 2">>, <<>>]].

json_roundtrip_test() ->
    %% Control characters must be escaped for the output to be valid JSON.
    Term = #{<<"text">> => <<"ctrl", 1, " tab\t \"q\" \\ ", 16#4e16/utf8>>,
             <<"n">> => -3, <<"list">> => [<<>>, 7]},
    Encoded = reddit_json:encode(Term),
    ?assertEqual(nomatch, binary:match(Encoded, <<1>>)),
    ?assertEqual({ok, Term}, reddit_json:decode(Encoded)).

ws_frame_test() ->
    %% Example handshake from RFC 6455, section 1.3.
    ?assertEqual(<<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>,
                 reddit_ws:accept_key(<<"dGhlIHNhbXBsZSBub25jZQ==">>)),
    [begin
         Payload = binary:copy(<<"ab">>, Size),
         Frame = reddit_ws:encode_frame(1, Payload, Masked),
         ?assertEqual({frame, 1, 1, Payload, <<"rest">>},
                      reddit_ws:decode_frame(<<Frame/binary, "rest">>)),
         ?assertEqual(more, reddit_ws:decode_frame(binary:part(Frame, 0, byte_size(Frame) - 1)))
     end || Size <- [0, 3, 100, 40000], Masked <- [true, false]].

wait_listening(Port, 0) -> error({not_listening, Port});
wait_listening(Port, N) ->
    case gen_tcp:connect("localhost", Port, []) of
        {ok, S} -> gen_tcp:close(S);
        {error, _} -> timer:sleep(50), wait_listening(Port, N - 1)
    end.

ws_push(Conn, Type) ->
    receive {reddit_ws_push, Conn, Type, Data} -> Data
    after 1000 -> error({no_push, Type})
    end.

websocket_session() ->
    wait_listening(?WS_PORT, 40),
    Url = "ws://localhost:" ++ integer_to_list(?WS_PORT) ++ "/ws",
    {ok, A} = reddit_ws_client:connect(Url),
    {ok, B} = reddit_ws_client:connect(Url),
    R = fun reddit_ws_client:request/3,
    ?assertEqual({error, <<"not_logged_in">>}, R(A, get_feed, #{})),
    ok = R(A, register, #{user => <<"wsa">>}),
    ok = R(B, register, #{user => <<"wsb">>}),
    ?assertEqual({error, <<"no_such_user">>}, R(A, login, #{user => <<"nobody">>})),
    {ok, #{<<"user">> := <<"wsa">>}} = R(A, login, #{user => <<"wsa">>}),
    {ok, _} = R(B, login, #{user => <<"wsb">>}),
    ok = R(A, create_sub, #{sub => <<"ws">>}),
    ok = R(B, join_sub, #{sub => <<"ws">>}),
    {ok, #{<<"id">> := P}} = R(A, post, #{sub => <<"ws">>, title => <<"t">>, body => <<"b">>}),
    #{<<"id">> := P, <<"author">> := <<"wsa">>} = ws_push(B, <<"new_post">>),
    {ok, #{<<"id">> := C}} = R(B, comment, #{parent_id => P, body => <<"c">>}),
    #{<<"comment_id">> := C, <<"from">> := <<"wsb">>} = ws_push(A, <<"reply">>),
    ok = R(B, vote, #{item_id => P, direction => <<"up">>}),
    {ok, #{<<"score">> := 1, <<"comments">> := [#{<<"id">> := C}]}} =
        R(A, get_post, #{post_id => P}),
    {ok, [#{<<"id">> := P}]} = R(B, get_feed, #{sort => <<"new">>}),
    {ok, #{<<"total">> := 1}} = R(A, get_karma, #{}),
    %% A message over 64 KB uses the 64-bit frame length in both directions.
    Big = binary:copy(<<"0123456789">>, 7000),
    {ok, #{<<"id">> := Dm}} = R(B, send_dm, #{to => <<"wsa">>, body => Big}),
    #{<<"id">> := Dm, <<"from">> := <<"wsb">>} = ws_push(A, <<"dm">>),
    {ok, [#{<<"body">> := Big}]} = R(A, get_dms, #{limit => 1}),
    ?assertEqual({error, <<"unknown_action">>}, R(A, fly, #{})),
    ?assertEqual({error, <<"missing field: sub">>}, R(A, join_sub, #{})),
    ?assertEqual({error, <<"bad field: item_id">>},
                 R(A, vote, #{item_id => <<"x">>, direction => <<"up">>})),
    ok = R(A, logout, #{}),
    {ok, _} = R(B, send_dm, #{to => <<"wsa">>, body => <<"offline">>}),
    receive {reddit_ws_push, A, _, _} -> error(pushed_after_logout)
    after 200 -> ok
    end,
    reddit_ws_client:close(A),
    reddit_ws_client:close(B),
    timer:sleep(100).

%% Many clients connecting at the same moment must all be served. With the
%% gen_tcp default listen backlog (5), Windows refused most of such a burst.
burst_connections() ->
    wait_listening(?WS_PORT, 40),
    N = 200,
    Parent = self(),
    Pids = [spawn(fun() ->
                          receive go -> ok end,
                          Parent ! {burst, self(), health_check(?WS_PORT)}
                  end) || _ <- lists:seq(1, N)],
    [P ! go || P <- Pids],
    Results = [receive {burst, P, R} -> R after 15000 -> timeout end || P <- Pids],
    ?assertEqual([], [R || R <- Results, R =/= ok]).

health_check(Port) ->
    case gen_tcp:connect("localhost", Port, [binary, {active, false}], 10000) of
        {ok, S} ->
            ok = gen_tcp:send(S, <<"GET /api/health HTTP/1.1\r\nHost: localhost\r\n\r\n">>),
            R = gen_tcp:recv(S, 0, 10000),
            gen_tcp:close(S),
            case R of
                {ok, <<"HTTP/1.1 200", _/binary>>} -> ok;
                Other -> Other
            end;
        Error ->
            Error
    end.

%% ------------------------------------------------------------------ search

search() ->
    users([<<"alice">>, <<"bob">>]),
    ok = reddit_ops:create_sub(<<"alice">>, <<"erlang">>),
    ok = reddit_ops:create_sub(<<"bob">>, <<"elixir">>),
    ok = reddit_ops:join_sub(<<"bob">>, <<"erlang">>),
    {ok, P1} = reddit_ops:create_post(<<"alice">>, <<"erlang">>, <<"Hello OTP">>,
                                      <<"gen_server tips">>),
    {ok, P2} = reddit_ops:create_post(<<"bob">>, <<"elixir">>, <<"Phoenix">>,
                                      <<"hello from elixir">>),
    {ok, _} = reddit_ops:create_post(<<"bob">>, <<"erlang">>, <<"ETS">>, <<"tables">>),
    Ids = fun({ok, Posts}) -> [Id || #{id := Id} <- Posts] end,
    ?assertEqual([P2, P1], Ids(reddit_ops:search_posts(<<"HELLO">>, 10))),  % all subs, newest first
    ?assertEqual([P1], Ids(reddit_ops:search_posts(<<"hello gen_server">>, 10))),  % every word
    ?assertEqual([P2], Ids(reddit_ops:search_posts(<<"hello">>, 1))),
    ?assertEqual([], Ids(reddit_ops:search_posts(<<"nothing">>, 10))),
    ?assertEqual({error, empty_query}, reddit_ops:search_posts(<<"  ">>, 10)),
    {ok, All} = reddit_ops:list_subs(<<>>),
    ?assertEqual([<<"erlang">>, <<"elixir">>], [N || #{name := N} <- All]),  % most members first
    ?assertMatch({ok, [#{name := <<"elixir">>, members := 1, creator := <<"bob">>}]},
                 reddit_ops:list_subs(<<"ELIX">>)).

%% The REST endpoints through the generic client, and search over WebSocket.
rest_session() ->
    wait_listening(?WS_PORT, 40),
    Base = "http://localhost:" ++ integer_to_list(?WS_PORT),
    Call = fun(Method, Path, Params) ->
                   {Status, Body, _Micros} = reddit_rest_client:call(Base, Method, Path, Params),
                   {ok, Value} = reddit_json:decode(Body),
                   {Status, Value}
           end,
    U = <<"resta">>,
    Sub = <<"rest sub">>,
    Text = <<"\x{fc}ber & = + % ?"/utf8>>,
    ?assertEqual({200, #{<<"ok">> => true}}, Call(post, "/api/users", #{user => U})),
    ?assertEqual({400, #{<<"error">> => <<"already_registered">>}},
                 Call(post, "/api/users", #{user => U})),
    {200, _} = Call(post, "/api/subreddits/create", #{user => U, sub => Sub}),
    {200, PostId} = Call(post, "/api/posts", #{user => U, sub => Sub,
                                               title => <<"Searchable title">>, body => Text}),
    ?assert(is_integer(PostId)),
    {200, #{<<"body">> := Text}} = Call(get, "/api/posts/" ++ integer_to_list(PostId), #{}),
    {200, [#{<<"id">> := PostId}]} = Call(get, "/api/search", #{q => <<"SEARCHABLE">>}),
    ?assertEqual({400, #{<<"error">> => <<"missing field: q">>}}, Call(get, "/api/search", #{})),
    {200, [#{<<"name">> := Sub, <<"members">> := 1}]} =
        Call(get, "/api/subreddits", #{q => <<"rest">>}),
    {ok, C} = reddit_ws_client:connect("ws://localhost:" ++ integer_to_list(?WS_PORT) ++ "/ws"),
    ?assertMatch({ok, [#{<<"id">> := PostId}]},
                 reddit_ws_client:request(C, search, #{q => <<"searchable">>})),
    ?assertMatch({ok, [#{<<"name">> := Sub}]},
                 reddit_ws_client:request(C, list_subs, #{q => <<"rest s">>})),
    ?assertMatch({error, _}, reddit_ws_client:request(C, search, #{})),
    reddit_ws_client:close(C).

log_format_test() ->
    Flat = fun(IoData) -> unicode:characters_to_list(IoData) end,
    ?assertEqual(" user=carol title=\"Hello world\" +signature +body",
                 Flat(reddit_log:params(#{<<"user">> => <<"carol">>,
                                          <<"title">> => <<"Hello world">>,
                                          <<"signature">> => <<"x">>,
                                          <<"body">> => <<"secret">>}))),
    {200, IdSummary} = reddit_log:http_result({200, 5}),
    ?assertEqual(" id=5", Flat(IdSummary)),
    {400, Error} = reddit_log:http_result({400, #{error => <<"not_member">>}}),
    ?assertEqual(" not_member", Flat(Error)),
    ?assertEqual(" ok (2 items)", Flat(reddit_log:engine_result({ok, [a, b]}))).
