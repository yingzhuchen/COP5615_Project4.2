%% Owns the ETS tables that hold all engine state.
%%
%% Tables are public so every engine worker can read and write them
%% concurrently; correctness relies on atomic ETS operations
%% (insert_new, take, update_counter) rather than on a single serialising
%% process.
-module(reddit_store).
-behaviour(gen_server).

-export([start/0, stop/0, tables/0, memory_bytes/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% {Name, Type} for every table.
%%  reddit_users        {User, CreatedMs}
%%  reddit_karma        {User, PostKarma, CommentKarma}
%%  reddit_subs         {Sub, Creator, CreatedMs}
%%  reddit_sub_count    {Sub, MemberCount}
%%  reddit_sub_members  {{Sub, User}}            (ordered: members of a sub)
%%  reddit_user_subs    {{User, Sub}}            (ordered: subs of a user)
%%  reddit_posts        {PostId, #post{}}
%%  reddit_sub_posts    {{Sub, PostId}}          (ordered: newest = largest id)
%%  reddit_comments     {CommentId, #comment{}}
%%  reddit_children     {{ParentItemId, ChildCommentId}}
%%  reddit_scores       {ItemId, Up, Down, Author, post | comment, NumComments}
%%  reddit_votes        {{ItemId, User}, 1 | -1}
%%  reddit_dms          {DmId, #dm{}}
%%  reddit_inbox        {{ToUser, DmId}}
%%  reddit_online       {User, ClientPid}
%%  reddit_ids          {CounterName, Value}     (id counters, push counters)
%%  reddit_public_keys  {User, PemPublicKey}
tables() ->
    [{reddit_users, set},
     {reddit_karma, set},
     {reddit_subs, set},
     {reddit_sub_count, set},
     {reddit_sub_members, ordered_set},
     {reddit_user_subs, ordered_set},
     {reddit_posts, set},
     {reddit_sub_posts, ordered_set},
     {reddit_comments, set},
     {reddit_children, ordered_set},
     {reddit_scores, set},
     {reddit_votes, set},
     {reddit_dms, set},
     {reddit_inbox, ordered_set},
     {reddit_online, set},
     {reddit_public_keys, set},
     {reddit_ids, set}].

start() ->
    case whereis(?MODULE) of
        undefined -> gen_server:start({local, ?MODULE}, ?MODULE, [], []);
        Pid -> {ok, Pid}
    end.

stop() ->
    gen_server:stop(?MODULE).

memory_bytes() ->
    W = erlang:system_info(wordsize),
    lists:sum([ets:info(T, memory) * W || {T, _} <- tables()]).

init([]) ->
    [ets:new(T, [Type, named_table, public,
                 {read_concurrency, true}, {write_concurrency, true}])
     || {T, Type} <- tables()],
    {ok, #{}}.

handle_call(_Req, _From, S) -> {reply, ok, S}.
handle_cast(_Msg, S) -> {noreply, S}.
handle_info(_Msg, S) -> {noreply, S}.
