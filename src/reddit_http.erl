%% Dependency-free REST server for the Project 4.1 engine.
-module(reddit_http).
-export([start/0, start/1, stop/0]).

-define(NAME, reddit_http_listener).

start() -> start(8080).

start(Port) ->
    stop(),
    Pid = spawn(fun() -> listen(Port) end),
    register(?NAME, Pid),
    {ok, Pid}.

stop() ->
    case whereis(?NAME) of
        undefined -> ok;
        Pid -> exit(Pid, shutdown), unregister(?NAME), ok
    end.

listen(Port) ->
    {ok, Socket} = gen_tcp:listen(Port, [binary, {packet, 0}, {active, false},
                                         {reuseaddr, true}]),
    accept(Socket).

accept(Socket) ->
    case gen_tcp:accept(Socket) of
        {ok, Client} ->
            spawn(fun() -> handle(Client) end),
            accept(Socket);
        {error, closed} -> ok;
        {error, _} -> accept(Socket)
    end.

handle(Socket) ->
    Result = try
                 case read_request(Socket) of
                     {ok, Method, Path, Query, Body} ->
                         route(Method, Path, Query, Body);
                     _ ->
                         {400, #{error => bad_request}}
                 end
             catch
                 throw:{bad_request, Reason} -> {bad_request, Reason};
                 error:Reason -> {500, #{error => iolist_to_binary(
                                                   io_lib:format("~p", [Reason]))}}
             end,
    send_response(Socket, Result),
    gen_tcp:close(Socket).

read_request(Socket) ->
    case recv_headers(Socket, <<>>) of
        {ok, HeaderBin, Rest} ->
            [RequestLine | HeaderLines] =
                binary:split(HeaderBin, <<"\r\n">>, [global]),
            [Method0, Target0 | _] =
                string:lexemes(binary_to_list(RequestLine), " "),
            Headers = headers(HeaderLines, #{}),
            Length = binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)),
            {ok, Body} = recv_body(Socket, Rest, Length),
            {Path, Query} = split_target(list_to_binary(Target0)),
            {ok, list_to_atom(string:lowercase(Method0)), Path, Query, Body};
        Error -> Error
    end.

recv_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            <<Head:Pos/binary, _Sep:4/binary, Rest/binary>> = Acc,
            {ok, Head, Rest};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 10000) of
                {ok, Chunk} -> recv_headers(Socket, <<Acc/binary, Chunk/binary>>);
                Error -> Error
            end
    end.

recv_body(_Socket, Rest, Length) when byte_size(Rest) >= Length ->
    <<Body:Length/binary, _/binary>> = Rest,
    {ok, Body};
recv_body(Socket, Rest, Length) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Chunk} -> recv_body(Socket, <<Rest/binary, Chunk/binary>>, Length);
        Error -> Error
    end.

headers([], Acc) -> Acc;
headers([Line | Rest], Acc) ->
    case binary:split(Line, <<":">>) of
        [Key, Value] -> headers(Rest, Acc#{lower(Key) => trim(Value)});
        _ -> headers(Rest, Acc)
    end.

split_target(Target) ->
    case binary:split(Target, <<"?">>) of
        [Path, Query] -> {Path, parse_params(Query)};
        [Path] -> {Path, #{}}
    end.

route(get, <<"/api/health">>, _Query, _Body) ->
    {200, #{status => <<"ok">>}};
route(get, <<"/api/feed">>, Query, _Body) ->
    with_user(Query, fun(User) ->
        call(User, {get_feed, User, int(maps:get(<<"limit">>, Query, <<"25">>)),
                    sort(maps:get(<<"sort">>, Query, <<"hot">>))})
    end);
route(get, <<"/api/karma">>, Query, _Body) ->
    with_user(Query, fun(User) -> call(User, {get_karma, User}) end);
route(get, <<"/api/messages">>, Query, _Body) ->
    with_user(Query, fun(User) ->
        call(User, {get_dms, User, int(maps:get(<<"limit">>, Query, <<"20">>))})
    end);
route(get, Path, _Query, _Body) ->
    case path_id(Path, <<"/api/posts/">>) of
        {ok, Id} -> call(<<>>, {get_post, <<>>, Id});
        error -> {404, #{error => not_found}}
    end;
route(post, <<"/api/users">>, _Query, Body) ->
    Params = parse_params(Body),
    call(<<>>, {register, required(Params, <<"user">>)});
route(post, <<"/api/subreddits/create">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {create_sub, U, required(P, <<"sub">>)}
    end);
route(post, <<"/api/subreddits/join">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {join_sub, U, required(P, <<"sub">>)}
    end);
route(post, <<"/api/subreddits/leave">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {leave_sub, U, required(P, <<"sub">>)}
    end);
route(post, <<"/api/posts">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {post, U, required(P, <<"sub">>), required(P, <<"title">>),
         required(P, <<"body">>)}
    end);
route(post, <<"/api/reposts">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {repost, U, required(P, <<"sub">>), int(required(P, <<"post_id">>))}
    end);
route(post, <<"/api/comments">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {comment, U, int(required(P, <<"parent_id">>)), required(P, <<"body">>)}
    end);
route(post, <<"/api/votes">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {vote, U, int(required(P, <<"item_id">>)), direction(required(P, <<"direction">>))}
    end);
route(post, <<"/api/messages">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {send_dm, U, required(P, <<"to">>), required(P, <<"body">>)}
    end);
route(post, <<"/api/messages/reply">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        {reply_dm, U, int(required(P, <<"dm_id">>)), required(P, <<"body">>)}
    end);
route(_, _, _, _) ->
    {404, #{error => not_found}}.

with_user(Params, Fun) ->
    Fun(required(Params, <<"user">>)).

user_call(Params, Fun) ->
    User = required(Params, <<"user">>),
    call(User, Fun(User, Params)).

call(User, Request) ->
    Workers = reddit_engine:num_workers(),
    Name = reddit_engine:worker_name(erlang:phash2(User, Workers) + 1),
    normalize(gen_server:call(Name, Request, 30000)).

normalize(ok) -> {200, #{ok => true}};
normalize({ok, Value}) -> {200, Value};
normalize({error, Reason}) -> {400, #{error => atom_to_binary(Reason, utf8)}};
normalize(Value) -> {200, Value}.

send_response(Socket, {error, Reason}) ->
    send_response(Socket, {400, #{error => iolist_to_binary(io_lib:format("~p", [Reason]))}});
send_response(Socket, {bad_request, Reason}) ->
    send_response(Socket, {400, #{error => iolist_to_binary(io_lib:format("~p", [Reason]))}});
send_response(Socket, {Status, Value}) ->
    Body = reddit_json:encode(Value),
    Header = io_lib:format(
               "HTTP/1.1 ~p ~s\r\nContent-Type: application/json\r\n"
               "Content-Length: ~p\r\nConnection: close\r\n\r\n",
               [Status, reason(Status), byte_size(Body)]),
    gen_tcp:send(Socket, [Header, Body]).

reason(200) -> "OK";
reason(400) -> "Bad Request";
reason(404) -> "Not Found";
reason(_) -> "Error".

path_id(Path, Prefix) ->
    case binary:match(Path, Prefix) of
        {0, _} ->
            try
                Start = byte_size(Prefix),
                {ok, binary_to_integer(binary:part(Path, Start, byte_size(Path) - Start))}
            catch error:badarg -> error
            end;
        nomatch -> error
    end.

parse_params(Bin) ->
    maps:from_list([param(Pair) || Pair <- binary:split(Bin, <<"&">>, [global]),
                                    Pair =/= <<>>]).

param(Pair) ->
    case binary:split(Pair, <<"=">>) of
        [Key, Value] -> {url_decode(Key), url_decode(Value)};
        [Key] -> {url_decode(Key), <<>>}
    end.

required(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        undefined -> throw({bad_request, {missing, Key}});
        <<>> -> throw({bad_request, {missing, Key}});
        Value -> Value
    end.

int(Bin) -> binary_to_integer(Bin).
sort(<<"new">>) -> new;
sort(<<"top">>) -> top;
sort(_) -> hot.
direction(<<"up">>) -> up;
direction(<<"down">>) -> down;
direction(<<"none">>) -> none;
direction(_) -> throw({bad_request, bad_direction}).

url_decode(Bin) -> url_decode(binary_to_list(Bin), []).
url_decode([], Acc) -> list_to_binary(lists:reverse(Acc));
url_decode([$+ | Rest], Acc) -> url_decode(Rest, [$\s | Acc]);
url_decode([$%, H1, H2 | Rest], Acc) ->
    url_decode(Rest, [hex(H1) * 16 + hex(H2) | Acc]);
url_decode([C | Rest], Acc) -> url_decode(Rest, [C | Acc]).

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $A, C =< $F -> C - $A + 10;
hex(C) when C >= $a, C =< $f -> C - $a + 10.

trim(Bin) -> list_to_binary(string:trim(binary_to_list(Bin))).
lower(Bin) -> list_to_binary(string:lowercase(binary_to_list(Bin))).
