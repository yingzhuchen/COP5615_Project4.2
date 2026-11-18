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
      fun direct_messages/0]}.

engine_test_() ->
    {setup,
     fun() -> ok = reddit_engine:start(2) end,
     fun(_) -> reddit_engine:stop() end,
     [fun live_notifications/0]}.

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
