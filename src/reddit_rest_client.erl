%% Simple client used by the Project 4.2 REST demo.
-module(reddit_rest_client).
-export([start/1, register/2, register/3, public_key/2,
         create_sub/3, join_sub/3, leave_sub/3,
         post/5, post/6, repost/4, repost/5, comment/4, vote/4, feed/3, post_view/2,
         karma/2, send_dm/4, reply_dm/4, dms/2]).

start(Base) ->
    application:ensure_all_started(inets),
    Base.

register(Base, User) -> request(post, Base ++ "/api/users", #{user => User}).
register(Base, User, PublicKey) ->
    request(post, Base ++ "/api/users", #{user => User, public_key => PublicKey}).
public_key(Base, User) ->
    request(get, Base ++ "/api/users/" ++ enc(User) ++ "/public_key").
create_sub(Base, User, Sub) ->
    request(post, Base ++ "/api/subreddits/create", #{user => User, sub => Sub}).
join_sub(Base, User, Sub) ->
    request(post, Base ++ "/api/subreddits/join", #{user => User, sub => Sub}).
leave_sub(Base, User, Sub) ->
    request(post, Base ++ "/api/subreddits/leave", #{user => User, sub => Sub}).
post(Base, User, Sub, Title, Body) ->
    request(post, Base ++ "/api/posts",
            #{user => User, sub => Sub, title => Title, body => Body}).
post(Base, User, Sub, Title, Body, Signature) ->
    request(post, Base ++ "/api/posts",
            #{user => User, sub => Sub, title => Title, body => Body,
              signature => Signature}).
repost(Base, User, Sub, Id) ->
    request(post, Base ++ "/api/reposts",
            #{user => User, sub => Sub, post_id => integer_to_binary(Id)}).
repost(Base, User, Sub, Id, Signature) ->
    request(post, Base ++ "/api/reposts",
            #{user => User, sub => Sub, post_id => integer_to_binary(Id),
              signature => Signature}).
comment(Base, User, ParentId, Body) ->
    request(post, Base ++ "/api/comments",
            #{user => User, parent_id => integer_to_binary(ParentId), body => Body}).
vote(Base, User, ItemId, Direction) ->
    request(post, Base ++ "/api/votes",
            #{user => User, item_id => integer_to_binary(ItemId),
              direction => atom_to_binary(Direction, utf8)}).
feed(Base, User, Limit) ->
    request(get, Base ++ "/api/feed?user=" ++ enc(User) ++
            "&limit=" ++ integer_to_list(Limit)).
post_view(Base, Id) ->
    request(get, Base ++ "/api/posts/" ++ integer_to_list(Id)).
karma(Base, User) ->
    request(get, Base ++ "/api/karma?user=" ++ enc(User)).
send_dm(Base, User, To, Body) ->
    request(post, Base ++ "/api/messages", #{user => User, to => To, body => Body}).
reply_dm(Base, User, DmId, Body) ->
    request(post, Base ++ "/api/messages/reply",
            #{user => User, dm_id => integer_to_binary(DmId), body => Body}).
dms(Base, User) ->
    request(get, Base ++ "/api/messages?user=" ++ enc(User)).

request(get, Url) ->
    {ok, {{_, Status, _}, _Headers, Body}} = httpc:request(get, {Url, []}, [], []),
    {Status, Body}.
request(post, Url, Params) ->
    Body = form(Params),
    {ok, {{_, Status, _}, _Headers, Response}} =
        httpc:request(post, {Url, [], "application/x-www-form-urlencoded", Body},
                      [], []),
    {Status, Response}.

form(Params) ->
    string:join([enc(key(K)) ++ "=" ++ enc(value(V)) || {K, V} <- maps:to_list(Params)], "&").

key(K) when is_atom(K) -> atom_to_list(K);
key(K) when is_binary(K) -> binary_to_list(K).
value(V) when is_binary(V) -> binary_to_list(V);
value(V) when is_list(V) -> V.

enc(Value) ->
    enc_chars(case Value of
                  V when is_binary(V) -> binary_to_list(V);
                  V -> V
              end).

enc_chars(Value) ->
    lists:flatten([case C of
                       $% -> "%25";
                       $& -> "%26";
                       $= -> "%3D";
                       $+ -> "%2B";
                       $\s -> "+";
                       $\n -> "%0A";
                       $\r -> "%0D";
                       _ -> [C]
                   end || C <- Value]).
