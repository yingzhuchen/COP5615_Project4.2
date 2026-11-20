%% REST client: one function per endpoint (used by the REST demo) and a
%% generic call/4 (used by the interactive client's REST mode).
-module(reddit_rest_client).
-export([start/1, register/2, register/3, public_key/2,
         create_sub/3, join_sub/3, leave_sub/3,
         post/5, post/6, repost/4, repost/5, comment/4, vote/4, feed/3, post_view/2,
         karma/2, send_dm/4, reply_dm/4, dms/2,
         call/4, query_string/1, form/1, url_encode/1]).

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

%% Generic request, used by the interactive client's REST mode.
%% -> {Status, BodyBinary, Microseconds} | {error, Reason}
call(Base, Method, Path, Params) ->
    application:ensure_all_started(inets),
    Url = Base ++ Path,
    Request = case Method of
                  get -> {Url ++ query_string(Params), []};
                  post -> {Url, [], "application/x-www-form-urlencoded", form(Params)}
              end,
    T0 = erlang:monotonic_time(microsecond),
    case httpc:request(Method, Request, [{timeout, 30000}], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {Status, Body, erlang:monotonic_time(microsecond) - T0};
        {error, Reason} ->
            {error, Reason}
    end.

query_string(Params) when map_size(Params) =:= 0 -> "";
query_string(Params) -> "?" ++ form(Params).

form(Params) ->
    string:join([url_encode(K) ++ "=" ++ url_encode(V)
                 || {K, V} <- lists:sort(maps:to_list(Params))], "&").

%% Percent-encode a value (as UTF-8) for a URL or a form body.
url_encode(V) when is_atom(V) -> url_encode(atom_to_binary(V, utf8));
url_encode(V) when is_integer(V) -> integer_to_list(V);
url_encode(V) when is_list(V) -> url_encode(unicode:characters_to_binary(V));
url_encode(V) when is_binary(V) -> lists:flatten([enc_byte(B) || <<B>> <= V]).

enc_byte(B) when B >= $a, B =< $z; B >= $A, B =< $Z; B >= $0, B =< $9;
                 B =:= $-; B =:= $_; B =:= $.; B =:= $~ ->
    [B];
enc_byte(B) ->
    io_lib:format("%~2.16.0B", [B]).

enc(Value) -> url_encode(Value).
