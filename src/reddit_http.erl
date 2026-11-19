%% Dependency-free REST server for the Project 4.1 engine. The same port
%% also accepts WebSocket connections on /ws (see reddit_ws).
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
            %% The handler must own the socket: a WebSocket session receives
            %% its TCP data as messages, next to the engine's live pushes.
            Pid = spawn(fun() -> receive {go, S} -> handle(S) end end),
            case gen_tcp:controlling_process(Client, Pid) of
                ok -> Pid ! {go, Client};
                {error, _} -> exit(Pid, kill), gen_tcp:close(Client)
            end,
            accept(Socket);
        {error, closed} -> ok;
        {error, _} -> accept(Socket)
    end.

handle(Socket) ->
    Result = try
                 case read_request(Socket) of
                     {ok, Method, Path, Query, Body} ->
                         route(Method, Path, Query, Body);
                     {upgrade, <<"/ws">>, Headers, Rest} ->
                         {websocket, Headers, Rest};
                     {upgrade, _Path, _Headers, _Rest} ->
                         {404, #{error => not_found}};
                     _ ->
                         {400, #{error => bad_request}}
                 end
             catch
                 throw:{bad_request, Reason} -> {bad_request, Reason};
                 error:Reason -> {500, #{error => iolist_to_binary(
                                                   io_lib:format("~p", [Reason]))}}
             end,
    case Result of
        {websocket, WsHeaders, WsRest} ->
            reddit_ws:serve(Socket, WsHeaders, WsRest);
        _ ->
            send_response(Socket, Result),
            gen_tcp:close(Socket)
    end.

read_request(Socket) ->
    case recv_headers(Socket, <<>>) of
        {ok, HeaderBin, Rest} ->
            [RequestLine | HeaderLines] =
                binary:split(HeaderBin, <<"\r\n">>, [global]),
            [Method0, Target0 | _] =
                string:lexemes(binary_to_list(RequestLine), " "),
            Headers = headers(HeaderLines, #{}),
            {Path, Query} = split_target(list_to_binary(Target0)),
            Method = list_to_atom(string:lowercase(Method0)),
            case Method =:= get andalso websocket_upgrade(Headers) of
                true ->
                    {upgrade, Path, Headers, Rest};
                false ->
                    Length = binary_to_integer(
                               maps:get(<<"content-length">>, Headers, <<"0">>)),
                    {ok, Body} = recv_body(Socket, Rest, Length),
                    {ok, Method, Path, Query, Body}
            end;
        Error -> Error
    end.

websocket_upgrade(Headers) ->
    string:lowercase(maps:get(<<"upgrade">>, Headers, <<>>)) =:= <<"websocket">>.

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
    case public_key_path(Path) of
        {ok, User} -> call(User, {get_public_key, User});
        error -> route_not_post(Path)
    end;
route(post, <<"/api/users">>, _Query, Body) ->
    Params = parse_params(Body),
    case maps:get(<<"public_key">>, Params, <<>>) of
        <<>> -> call(<<>>, {register, required(Params, <<"user">>)});
        Pem -> call(<<>>, {register_signed, required(Params, <<"user">>), Pem})
    end;
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
        case maps:get(<<"signature">>, P, <<>>) of
            <<>> -> {post, U, required(P, <<"sub">>), required(P, <<"title">>),
                     required(P, <<"body">>)};
            Signature -> {post_signed, U, required(P, <<"sub">>),
                          required(P, <<"title">>), required(P, <<"body">>), Signature}
        end
    end);
route(post, <<"/api/reposts">>, _Query, Body) ->
    user_call(parse_params(Body), fun(U, P) ->
        case maps:get(<<"signature">>, P, <<>>) of
            <<>> -> {repost, U, required(P, <<"sub">>),
                     int(required(P, <<"post_id">>))};
            Signature -> {repost_signed, U, required(P, <<"sub">>),
                          int(required(P, <<"post_id">>)), Signature}
        end
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
    normalize(reddit_engine:call(User, Request)).

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

route_not_post(Path) ->
    case path_id(Path, <<"/api/posts/">>) of
        {ok, Id} -> call(<<>>, {get_post, <<>>, Id});
        error -> {404, #{error => not_found}}
    end.

public_key_path(Path) ->
    Prefix = <<"/api/users/">>,
    Suffix = <<"/public_key">>,
    case binary:match(Path, Prefix) of
        {0, _} ->
            Start = byte_size(Prefix),
            case byte_size(Path) >= Start + byte_size(Suffix) of
                true ->
                    End = byte_size(Path) - byte_size(Suffix),
                    case binary:part(Path, End, byte_size(Suffix)) of
                        Suffix ->
                            User = url_decode(binary:part(Path, Start, End - Start)),
                            case User of <<>> -> error; _ -> {ok, User} end;
                        _ -> error
                    end;
                false -> error
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
