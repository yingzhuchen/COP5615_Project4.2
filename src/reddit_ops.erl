%% Engine business logic: every Reddit operation, implemented over the ETS
%% tables created by reddit_store. Functions are pure request -> reply and
%% know nothing about processes or networking, so they can be unit tested
%% directly and reused unchanged behind a REST/WebSocket layer in part II.
%%
%% All functions return ok | {ok, Value} | {error, Reason}.
-module(reddit_ops).
-include("reddit.hrl").

-export([register_user/1, register_user/2, set_public_key/2, get_public_key/1, user_exists/1,
         create_sub/2, join_sub/2, leave_sub/2,
         user_subs/1, sub_members/1, sub_member_count/1,
         create_post/4, create_signed_post/5, repost/3, repost_signed/4,
         comment/3, vote/3, get_karma/1,
         get_feed/3, get_post/1, post_view/1, item_author/1,
         search_posts/2, list_subs/1,
         send_dm/3, reply_dm/3, get_dms/2,
         connect/2, disconnect/1, online_pid/1,
         count/2, counter/1]).

%% ---------------------------------------------------------------- accounts

register_user(User) when is_binary(User), User =/= <<>> ->
    case ets:insert_new(reddit_users, {User, now_ms()}) of
        true -> ets:insert(reddit_karma, {User, 0, 0}), ok;
        false -> {error, already_registered}
    end;
register_user(_) ->
    {error, invalid_name}.

register_user(User, <<>>) ->
    register_user(User);
register_user(User, Pem) ->
    case ets:insert_new(reddit_users, {User, now_ms()}) of
        true ->
            case set_public_key(User, Pem) of
                ok -> ets:insert(reddit_karma, {User, 0, 0}), ok;
                {error, _} = Error ->
                    ets:delete(reddit_users, User),
                    Error
            end;
        false -> {error, already_registered}
    end.

set_public_key(User, Pem) ->
    case user_exists(User) of
        true ->
            case reddit_signature:decode_public_key(Pem) of
                {ok, _} ->
                    ets:insert(reddit_public_keys, {User, Pem}),
                    ok;
                {error, _} = Error -> Error
            end;
        false -> {error, no_such_user}
    end.

get_public_key(User) ->
    case ets:lookup(reddit_public_keys, User) of
        [{_, Pem}] -> {ok, #{user => User, public_key => Pem}};
        [] -> {error, no_public_key}
    end.

user_exists(User) -> ets:member(reddit_users, User).

get_karma(User) ->
    case ets:lookup(reddit_karma, User) of
        [{_, P, C}] -> {ok, #{post_karma => P, comment_karma => C, total => P + C}};
        [] -> {error, no_such_user}
    end.

%% -------------------------------------------------------------- subreddits

create_sub(User, Sub) ->
    guard(fun() ->
        need_user(User),
        need_text(Sub),
        case ets:insert_new(reddit_subs, {Sub, User, now_ms()}) of
            true -> ok = join_sub(User, Sub);   % the creator is the first member
            false -> {error, sub_exists}
        end
    end).

join_sub(User, Sub) ->
    guard(fun() ->
        need_user(User),
        need_sub(Sub),
        case ets:insert_new(reddit_user_subs, {{User, Sub}}) of
            true ->
                ets:insert(reddit_sub_members, {{Sub, User}}),
                ets:update_counter(reddit_sub_count, Sub, {2, 1}, {Sub, 0}),
                ok;
            false ->
                {error, already_member}
        end
    end).

leave_sub(User, Sub) ->
    case ets:take(reddit_user_subs, {User, Sub}) of
        [_] ->
            ets:delete(reddit_sub_members, {Sub, User}),
            ets:update_counter(reddit_sub_count, Sub, {2, -1}, {Sub, 0}),
            ok;
        [] ->
            {error, not_member}
    end.

user_subs(User) ->
    ets:select(reddit_user_subs, [{{{User, '$1'}}, [], ['$1']}]).

sub_members(Sub) ->
    ets:select(reddit_sub_members, [{{{Sub, '$1'}}, [], ['$1']}]).

sub_member_count(Sub) ->
    case ets:lookup(reddit_sub_count, Sub) of
        [{_, N}] -> N;
        [] -> 0
    end.

%% ------------------------------------------------------------------- posts

create_post(User, Sub, Title, Body) ->
    do_post(User, Sub, Title, Body, undefined, undefined).

create_signed_post(User, Sub, Title, Body, Signature) ->
    case ets:lookup(reddit_public_keys, User) of
        [{_, Pem}] ->
            Payload = reddit_signature:payload(User, Sub, Title, Body),
            case is_binary(Signature) andalso
                 reddit_signature:verify(Pem, Payload, Signature) of
                true -> do_post(User, Sub, Title, Body, undefined, Signature);
                false -> {error, invalid_signature}
            end;
        [] -> {error, no_public_key}
    end.

%% A repost copies the original's title and body into another (or the same)
%% subreddit and keeps a link to the root original.
repost(User, Sub, OrigId) ->
    case ets:lookup(reddit_posts, OrigId) of
        [{_, #post{title = T, body = B, repost_of = R}}] ->
            Root = case R of undefined -> OrigId; _ -> R end,
            do_post(User, Sub, T, B, Root, undefined);
        [] ->
            {error, no_such_post}
    end.

repost_signed(User, Sub, OrigId, Signature) ->
    case ets:lookup(reddit_posts, OrigId) of
        [{_, #post{title = T, body = B, repost_of = R}}] ->
            Root = case R of undefined -> OrigId; _ -> R end,
            case ets:lookup(reddit_public_keys, User) of
                [{_, Pem}] ->
                    Payload = reddit_signature:payload(User, Sub, T, B),
                    case is_binary(Signature) andalso
                         reddit_signature:verify(Pem, Payload, Signature) of
                        true -> do_post(User, Sub, T, B, Root, Signature);
                        false -> {error, invalid_signature}
                    end;
                [] -> {error, no_public_key}
            end;
        [] -> {error, no_such_post}
    end.

do_post(User, Sub, Title, Body, RepostOf, Signature) ->
    guard(fun() ->
        need_user(User),
        need_sub(Sub),
        need_text(Title),
        is_binary(Body) orelse throw({error, bad_body}),
        ets:member(reddit_user_subs, {User, Sub}) orelse throw({error, not_member}),
        Id = next_id(item),
        P = #post{id = Id, sub = Sub, author = User, title = Title, body = Body,
                  created = now_ms(), repost_of = RepostOf, signature = Signature},
        ets:insert(reddit_posts, {Id, P}),
        ets:insert(reddit_scores, {Id, 0, 0, User, post, 0}),
        ets:insert(reddit_sub_posts, {{Sub, Id}}),   % last: makes it visible in feeds
        {ok, Id}
    end).

post_view(Id) ->
    case {ets:lookup(reddit_posts, Id), ets:lookup(reddit_scores, Id)} of
        {[{_, P}], [{_, Up, Down, _, _, NC}]} ->
            #{id => Id, sub => P#post.sub, author => P#post.author,
              title => P#post.title, body => P#post.body,
              created => P#post.created, repost_of => P#post.repost_of,
              up => Up, down => Down, score => Up - Down, num_comments => NC,
              signature => P#post.signature,
              signature_status => signature_status(P)};
        _ ->
            undefined
    end.

signature_status(#post{signature = undefined}) ->
    unsigned;
signature_status(#post{author = Author, sub = Sub, title = Title,
                       body = Body, signature = Signature}) ->
    case ets:lookup(reddit_public_keys, Author) of
        [{_, Pem}] ->
            Payload = reddit_signature:payload(Author, Sub, Title, Body),
            case reddit_signature:verify(Pem, Payload, Signature) of
                true -> valid;
                false -> invalid
            end;
        [] -> missing_public_key
    end.

%% A post together with its full comment tree.
get_post(Id) ->
    case post_view(Id) of
        undefined -> {error, no_such_post};
        View -> {ok, View#{comments => comment_tree(Id)}}
    end.

%% ---------------------------------------------------------------- comments

%% ParentId may be a post id (top-level comment) or a comment id (reply),
%% so comments nest to any depth.
comment(User, ParentId, Body) ->
    guard(fun() ->
        need_user(User),
        need_text(Body),
        {PostId, Depth} =
            case ets:member(reddit_posts, ParentId) of
                true -> {ParentId, 1};
                false ->
                    case ets:lookup(reddit_comments, ParentId) of
                        [{_, #comment{post = P, depth = D}}] -> {P, D + 1};
                        [] -> throw({error, no_such_parent})
                    end
            end,
        Id = next_id(item),
        C = #comment{id = Id, post = PostId, parent = ParentId, author = User,
                     body = Body, created = now_ms(), depth = Depth},
        ets:insert(reddit_comments, {Id, C}),
        ets:insert(reddit_scores, {Id, 0, 0, User, comment, 0}),
        ets:insert(reddit_children, {{ParentId, Id}}),
        ets:update_counter(reddit_scores, PostId, {6, 1}),
        {ok, Id}
    end).

comment_tree(ParentId) ->
    Kids = ets:select(reddit_children, [{{{ParentId, '$1'}}, [], ['$1']}]),
    Views = [comment_view(C) || C <- Kids],
    lists:sort(fun(#{score := A}, #{score := B}) -> A >= B end,
               [V || V <- Views, V =/= undefined]).

comment_view(Id) ->
    case {ets:lookup(reddit_comments, Id), ets:lookup(reddit_scores, Id)} of
        {[{_, C}], [{_, Up, Down, _, _, _}]} ->
            #{id => Id, author => C#comment.author, body => C#comment.body,
              created => C#comment.created, depth => C#comment.depth,
              parent => C#comment.parent,
              up => Up, down => Down, score => Up - Down,
              replies => comment_tree(Id)};
        _ ->
            undefined
    end.

item_author(Id) ->
    case ets:lookup(reddit_scores, Id) of
        [{_, _, _, Author, _, _}] -> {ok, Author};
        [] -> {error, no_such_item}
    end.

%% ------------------------------------------------------------ votes, karma

%% Dir is up | down | none (none withdraws an earlier vote). Changing a vote
%% applies only the difference. The author's karma moves with the item's
%% score, except for votes on one's own items.
vote(User, ItemId, Dir) ->
    guard(fun() ->
        need_user(User),
        New = case Dir of
                  up -> 1;
                  down -> -1;
                  none -> 0;
                  _ -> throw({error, bad_direction})
              end,
        {Author, Kind} =
            case ets:lookup(reddit_scores, ItemId) of
                [{_, _, _, A, K, _}] -> {A, K};
                [] -> throw({error, no_such_item})
            end,
        Key = {ItemId, User},
        Old = case ets:lookup(reddit_votes, Key) of
                  [{_, V}] -> V;
                  [] -> 0
              end,
        case New - Old of
            0 -> ok;
            Delta ->
                UpD = b2i(New =:= 1) - b2i(Old =:= 1),
                DownD = b2i(New =:= -1) - b2i(Old =:= -1),
                ets:update_counter(reddit_scores, ItemId, [{2, UpD}, {3, DownD}]),
                case New of
                    0 -> ets:delete(reddit_votes, Key);
                    _ -> ets:insert(reddit_votes, {Key, New})
                end,
                case Author =:= User of
                    true -> ok;
                    false ->
                        Pos = case Kind of post -> 2; comment -> 3 end,
                        ets:update_counter(reddit_karma, Author, {Pos, Delta},
                                           {Author, 0, 0}),
                        ok
                end
        end
    end).

%% -------------------------------------------------------------------- feed

%% Posts from every subreddit the user has joined. Sort is hot | new | top.
get_feed(User, Limit, Sort) ->
    guard(fun() ->
        need_user(User),
        Ids = lists:append([latest_ids(reddit_sub_posts, S, Limit)
                            || S <- user_subs(User)]),
        Views = [V || Id <- Ids, V <- [post_view(Id)], V =/= undefined],
        {ok, lists:sublist(sort_posts(Sort, Views), Limit)}
    end).

sort_posts(new, Vs) ->
    lists:sort(fun(#{id := A}, #{id := B}) -> A >= B end, Vs);
sort_posts(top, Vs) ->
    lists:sort(fun(#{score := A}, #{score := B}) -> A >= B end, Vs);
sort_posts(_Hot, Vs) ->
    Keyed = [{hot(V), V} || V <- Vs],
    [V || {_, V} <- lists:sort(fun({A, _}, {B, _}) -> A >= B end, Keyed)].

%% Reddit's classic "hot" ranking: log of the score plus a time bonus.
hot(#{score := S, created := C}) ->
    Order = math:log10(max(abs(S), 1)),
    Sign = if S > 0 -> 1; S < 0 -> -1; true -> 0 end,
    Sign * Order + (C / 1000 - 1134028003) / 45000.

%% The N largest ids stored under {Prefix, Id} in an ordered_set, newest first.
latest_ids(Table, Prefix, N) ->
    latest_ids(Table, Prefix, ets:prev(Table, {Prefix, infinity}), N, []).

latest_ids(_, _, _, 0, Acc) ->
    lists:reverse(Acc);
latest_ids(Table, Prefix, {Prefix, Id} = Key, N, Acc) ->
    latest_ids(Table, Prefix, ets:prev(Table, Key), N - 1, [Id | Acc]);
latest_ids(_, _, _, _, Acc) ->
    lists:reverse(Acc).

%% ------------------------------------------------------------------ search

%% Posts in any subreddit whose title or body contains every word of Query
%% (case-insensitive), newest first.
search_posts(Query, Limit) ->
    case words(Query) of
        [] ->
            {error, empty_query};
        Words ->
            Ids = ets:foldl(fun({Id, #post{title = T, body = B}}, Acc) ->
                                    case matches(<<T/binary, " ", B/binary>>, Words) of
                                        true -> [Id | Acc];
                                        false -> Acc
                                    end
                            end, [], reddit_posts),
            Newest = lists:sublist(lists:reverse(lists:sort(Ids)), Limit),
            {ok, [V || Id <- Newest, V <- [post_view(Id)], V =/= undefined]}
    end.

%% Subreddits whose name contains every word of Query (all of them for an
%% empty query), largest first.
list_subs(Query) ->
    Words = words(Query),
    Subs = [#{name => Sub, creator => Creator, members => sub_member_count(Sub)}
            || {Sub, Creator, _Created} <- ets:tab2list(reddit_subs),
               matches(Sub, Words)],
    {ok, lists:sort(fun(#{members := A, name := NA}, #{members := B, name := NB}) ->
                            {A, NB} >= {B, NA}
                    end, Subs)}.

words(Query) when is_binary(Query) ->
    [W || W <- string:lexemes(fold(Query), " \t"), W =/= <<>>];
words(_) ->
    [].

matches(Text, Words) ->
    Folded = fold(Text),
    lists:all(fun(W) -> binary:match(Folded, W) =/= nomatch end, Words).

%% Case-folded copy of a UTF-8 binary (unchanged if it is not valid UTF-8).
fold(Bin) ->
    try unicode:characters_to_binary(string:casefold(Bin)) of
        Folded when is_binary(Folded) -> Folded;
        _ -> Bin
    catch
        _:_ -> Bin
    end.

%% ---------------------------------------------------------- direct messages

send_dm(From, To, Body) ->
    send_dm(From, To, Body, undefined).

send_dm(From, To, Body, ReplyTo) ->
    guard(fun() ->
        need_user(From),
        need_user(To),
        need_text(Body),
        Id = next_id(dm),
        D = #dm{id = Id, from = From, to = To, body = Body,
                created = now_ms(), reply_to = ReplyTo},
        ets:insert(reddit_dms, {Id, D}),
        ets:insert(reddit_inbox, {{To, Id}}),
        {ok, Id}
    end).

%% Only the recipient of a message can reply to it; the reply goes to the
%% original sender.
reply_dm(User, DmId, Body) ->
    case ets:lookup(reddit_dms, DmId) of
        [{_, #dm{to = User, from = From}}] -> send_dm(User, From, Body, DmId);
        [{_, _}] -> {error, not_recipient};
        [] -> {error, no_such_dm}
    end.

%% The user's most recent messages, newest first.
get_dms(User, Limit) ->
    guard(fun() ->
        need_user(User),
        Ids = latest_ids(reddit_inbox, User, Limit),
        {ok, [dm_view(D) || Id <- Ids, [{_, D}] <- [ets:lookup(reddit_dms, Id)]]}
    end).

dm_view(#dm{id = Id, from = F, to = T, body = B, created = C, reply_to = R}) ->
    #{id => Id, from => F, to => T, body => B, created => C, reply_to => R}.

%% -------------------------------------------------------- live connections

connect(User, Pid) when is_pid(Pid) ->
    guard(fun() ->
        need_user(User),
        ets:insert(reddit_online, {User, Pid}),
        ok
    end).

disconnect(User) ->
    ets:delete(reddit_online, User),
    ok.

online_pid(User) ->
    case ets:lookup(reddit_online, User) of
        [{_, Pid}] -> {ok, Pid};
        [] -> offline
    end.

%% ----------------------------------------------------------------- helpers

count(Key, N) -> ets:update_counter(reddit_ids, Key, {2, N}, {Key, 0}).

counter(Key) ->
    case ets:lookup(reddit_ids, Key) of
        [{_, V}] -> V;
        [] -> 0
    end.

next_id(Key) -> count(Key, 1).

now_ms() -> erlang:system_time(millisecond).

b2i(true) -> 1;
b2i(false) -> 0.

guard(F) ->
    try F()
    catch throw:{error, _} = E -> E
    end.

need_user(U) -> user_exists(U) orelse throw({error, no_such_user}).
need_sub(S) -> ets:member(reddit_subs, S) orelse throw({error, no_such_sub}).
need_text(T) -> (is_binary(T) andalso T =/= <<>>) orelse throw({error, empty_text}).
