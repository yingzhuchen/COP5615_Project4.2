%% The engine process: a pool of worker gen_servers in front of reddit_ops.
%%
%% Clients (on other nodes) pick a worker by hashing their user name, so all
%% requests of one user are handled in order by one worker while different
%% users are served in parallel. Shared state lives in ETS (reddit_store).
%%
%% The engine also delivers live notifications to connected clients:
%%   {reddit_push, {dm, DmView}}         a direct message arrived
%%   {reddit_push, {reply, Info}}        someone replied to your post/comment
%%   {reddit_push, {new_post, PostView}} new post in a joined sub (optional,
%%                                       enabled with push_posts = true)
%% Post fan-out is batched per client node through the reddit_relay process
%% that every client node runs.
-module(reddit_engine).
-behaviour(gen_server).
-include("reddit.hrl").

-export([start/1, start/2, stop/0, num_workers/0, worker_name/1, call/2,
         collect_stats/0, reset_stats/0, request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start(NumWorkers) ->
    start(NumWorkers, #{}).

start(NumWorkers, Opts) ->
    {ok, _} = reddit_store:start(),
    persistent_term:put(reddit_workers, NumWorkers),
    persistent_term:put(reddit_push_posts, maps:get(push_posts, Opts, false)),
    [{ok, _} = gen_server:start({local, worker_name(I)}, ?MODULE, I, [])
     || I <- lists:seq(1, NumWorkers)],
    ok.

stop() ->
    [try gen_server:stop(worker_name(I)) catch exit:_ -> ok end
     || I <- lists:seq(1, num_workers())],
    reddit_store:stop().

num_workers() -> persistent_term:get(reddit_workers).

worker_name(I) -> list_to_atom("reddit_w" ++ integer_to_list(I)).

%% A request from a front end running on the engine node (REST, WebSocket),
%% sent to the worker that owns User, like reddit_client does remotely.
call(User, Request) ->
    gen_server:call(worker_name(erlang:phash2(User, num_workers()) + 1), Request, 30000).

%% Per-operation server-side stats: #{Op => {Count, TotalServiceMicros}}.
collect_stats() ->
    lists:foldl(
      fun(I, Acc) ->
              S = gen_server:call(worker_name(I), get_stats, infinity),
              maps:fold(fun(Op, {C, T}, A) ->
                                {C0, T0} = maps:get(Op, A, {0, 0}),
                                A#{Op => {C0 + C, T0 + T}}
                        end, Acc, S)
      end, #{}, lists:seq(1, num_workers())).

reset_stats() ->
    [ok = gen_server:call(worker_name(I), reset_stats) || I <- lists:seq(1, num_workers())],
    ets:insert(reddit_ids, [{push_dm, 0}, {push_reply, 0}, {push_post, 0}]),
    ok.

%% ------------------------------------------------------------- gen_server

init(_Index) ->
    {ok, #{}}.

handle_call(get_stats, _From, S) ->
    {reply, S, S};
handle_call(reset_stats, _From, _S) ->
    {reply, ok, #{}};
handle_call(Req, _From, S) when is_tuple(Req), tuple_size(Req) > 0 ->
    T0 = erlang:monotonic_time(microsecond),
    Reply = try request(Req)
            catch Class:Reason -> {error, {internal, Class, Reason}}
            end,
    Dt = erlang:monotonic_time(microsecond) - T0,
    Op = element(1, Req),
    {C, T} = maps:get(Op, S, {0, 0}),
    {reply, Reply, S#{Op => {C + 1, T + Dt}}};
handle_call(_Req, _From, S) ->
    {reply, {error, bad_request}, S}.

handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.

%% --------------------------------------------------------------- requests

request({register, U}) -> reddit_ops:register_user(U);
request({register_signed, U, Pem}) -> reddit_ops:register_user(U, Pem);
request({set_public_key, U, Pem}) -> reddit_ops:set_public_key(U, Pem);
request({get_public_key, U}) -> reddit_ops:get_public_key(U);
request({connect, U, Pid}) -> reddit_ops:connect(U, Pid);
request({disconnect, U}) -> reddit_ops:disconnect(U);
request({create_sub, U, Sub}) -> reddit_ops:create_sub(U, Sub);
request({join_sub, U, Sub}) -> reddit_ops:join_sub(U, Sub);
request({leave_sub, U, Sub}) -> reddit_ops:leave_sub(U, Sub);
request({post, U, Sub, Title, Body}) ->
    after_post(reddit_ops:create_post(U, Sub, Title, Body), U, Sub);
request({post_signed, U, Sub, Title, Body, Signature}) ->
    after_post(reddit_ops:create_signed_post(U, Sub, Title, Body, Signature), U, Sub);
request({repost, U, Sub, OrigId}) ->
    after_post(reddit_ops:repost(U, Sub, OrigId), U, Sub);
request({repost_signed, U, Sub, OrigId, Signature}) ->
    after_post(reddit_ops:repost_signed(U, Sub, OrigId, Signature), U, Sub);
request({comment, U, Parent, Body}) ->
    R = reddit_ops:comment(U, Parent, Body),
    case R of
        {ok, Id} -> notify_reply(U, Parent, Id);
        _ -> ok
    end,
    R;
request({vote, U, Item, Dir}) -> reddit_ops:vote(U, Item, Dir);
request({get_karma, U}) -> reddit_ops:get_karma(U);
request({get_feed, U, Limit, Sort}) -> reddit_ops:get_feed(U, Limit, Sort);
request({get_post, _U, PostId}) -> reddit_ops:get_post(PostId);
request({send_dm, U, To, Body}) ->
    after_dm(reddit_ops:send_dm(U, To, Body), To);
request({reply_dm, U, DmId, Body}) ->
    R = reddit_ops:reply_dm(U, DmId, Body),
    case R of
        {ok, NewId} ->
            [{_, Dm}] = ets:lookup(reddit_dms, NewId),
            after_dm(R, Dm#dm.to);
        _ -> R
    end;
request({get_dms, U, Limit}) -> reddit_ops:get_dms(U, Limit);
request(_) -> {error, bad_request}.

%% ------------------------------------------------------- live notifications

after_dm({ok, Id} = R, To) ->
    case ets:lookup(reddit_dms, Id) of
        [{_, Dm}] ->
            push(To, push_dm, {dm, #{id => Id, from => Dm#dm.from}});
        [] -> ok
    end,
    R;
after_dm(R, _To) ->
    R.

notify_reply(From, Parent, Id) ->
    case reddit_ops:item_author(Parent) of
        {ok, From} -> ok;
        {ok, Author} ->
            push(Author, push_reply,
                 {reply, #{comment_id => Id, parent => Parent, from => From}});
        _ -> ok
    end.

push(User, CounterKey, Msg) ->
    case reddit_ops:online_pid(User) of
        {ok, Pid} ->
            Pid ! {reddit_push, Msg},
            reddit_ops:count(CounterKey, 1);
        offline ->
            ok
    end.

after_post({ok, Id} = R, Author, Sub) ->
    case persistent_term:get(reddit_push_posts, false) of
        true -> spawn(fun() -> fanout_post(Id, Author, Sub) end);
        false -> ok
    end,
    R;
after_post(R, _, _) ->
    R.

fanout_post(Id, Author, Sub) ->
    View = reddit_ops:post_view(Id),
    Pids = [Pid || M <- reddit_ops:sub_members(Sub), M =/= Author,
                   [{_, Pid}] <- [ets:lookup(reddit_online, M)]],
    deliver(Pids, {reddit_push, {new_post, View}}),
    reddit_ops:count(push_post, length(Pids)).

%% One message per remote node; the node's reddit_relay forwards locally.
deliver([], _Msg) ->
    ok;
deliver(Pids, Msg) ->
    ByNode = lists:foldl(fun(P, Acc) ->
                                 maps:update_with(node(P), fun(L) -> [P | L] end, [P], Acc)
                         end, #{}, Pids),
    Here = node(),
    maps:foreach(fun(N, Ps) when N =:= Here -> [P ! Msg || P <- Ps];
                    (N, Ps) -> {reddit_relay, N} ! {relay, Ps, Msg}
                 end, ByNode).
