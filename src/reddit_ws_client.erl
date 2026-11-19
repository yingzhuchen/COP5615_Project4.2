%% WebSocket client for the engine (dependency-free, RFC 6455).
%%
%%   {ok, C} = reddit_ws_client:connect("ws://localhost:8080/ws"),
%%   {ok, #{<<"id">> := Id}} =
%%       reddit_ws_client:request(C, post, #{sub => <<"erlang">>, ...}),
%%
%% Every request is one JSON frame with a fresh `ref`; request/3 waits for
%% the reply frame with the same ref. Push frames from the server are sent
%% to the owner process (the caller of connect/1, or the one given to
%% connect/2) as {reddit_ws_push, Conn, Type, Data}. When the connection
%% ends, the owner gets {reddit_ws_closed, Conn}.
%%
%% With trace on, every frame sent and received is printed (shortened).
-module(reddit_ws_client).
-export([connect/1, connect/2, request/3, close/1, set_trace/3]).

-define(TIMEOUT, 30000).
-define(TRACE_CHARS, 220).

connect(Url) -> connect(Url, self()).

connect(Url, Owner) ->
    Caller = self(),
    Pid = spawn(fun() -> init(Url, Owner, Caller) end),
    MRef = monitor(process, Pid),
    receive
        {Pid, connected} -> demonitor(MRef, [flush]), {ok, Pid};
        {Pid, {error, _} = Error} -> demonitor(MRef, [flush]), Error;
        {'DOWN', MRef, _, _, Reason} -> {error, Reason}
    after ?TIMEOUT ->
        exit(Pid, kill), {error, timeout}
    end.

%% -> ok | {ok, Data} | {error, Reason}
request(Conn, Action, Params) when is_atom(Action) ->
    request(Conn, atom_to_binary(Action, utf8), Params);
request(Conn, Action, Params) ->
    MRef = monitor(process, Conn),
    Conn ! {request, self(), MRef, Action, Params},
    receive
        {ws_reply, MRef, Reply} ->
            demonitor(MRef, [flush]),
            result(Reply);
        {'DOWN', MRef, _, _, _} ->
            {error, closed}
    after ?TIMEOUT ->
        demonitor(MRef, [flush]),
        {error, timeout}
    end.

close(Conn) -> Conn ! close, ok.

%% Label is printed in front of each traced frame, e.g. the user name.
set_trace(Conn, OnOff, Label) -> Conn ! {trace, OnOff, Label}, ok.

result(#{<<"ok">> := true, <<"data">> := Data}) -> {ok, Data};
result(#{<<"ok">> := true}) -> ok;
result(#{<<"ok">> := false, <<"error">> := Why}) -> {error, Why};
result(Other) -> {error, {bad_reply, Other}}.

%% ------------------------------------------------------------ connection

init(Url, Owner, Caller) ->
    case open(Url) of
        {ok, Sock, Rest} ->
            Caller ! {self(), connected},
            S = #{sock => Sock, buf => <<>>, owner => Owner, next => 1,
                  pending => #{}, trace => false, label => <<>>, frag => undefined},
            S1 = parse(Rest, S),
            loop(S1);
        {error, _} = Error ->
            Caller ! {self(), Error}
    end.

open(Url) ->
    try
        #{host := Host, path := Path0} = U =
            uri_string:parse(unicode:characters_to_list(Url)),
        Port = maps:get(port, U, 80),
        Path = case Path0 of "" -> "/ws"; _ -> Path0 end,
        {ok, Sock} = gen_tcp:connect(Host, Port, [binary, {active, false},
                                                  {packet, 0}, {nodelay, true}],
                                     ?TIMEOUT),
        Key = base64:encode(crypto:strong_rand_bytes(16)),
        ok = gen_tcp:send(Sock, ["GET ", Path, " HTTP/1.1\r\n"
                                 "Host: ", Host, ":", integer_to_list(Port), "\r\n"
                                 "Upgrade: websocket\r\n"
                                 "Connection: Upgrade\r\n"
                                 "Sec-WebSocket-Key: ", Key, "\r\n"
                                 "Sec-WebSocket-Version: 13\r\n\r\n"]),
        {ok, Head, Rest} = recv_head(Sock, <<>>),
        [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
        [_, <<"101">> | _] = binary:split(StatusLine, <<" ">>, [global]),
        Expected = reddit_ws:accept_key(Key),
        Accept = [string:trim(V) || L <- Lines,
                                    [K, V] <- [binary:split(L, <<":">>)],
                                    string:lowercase(K) =:= <<"sec-websocket-accept">>],
        [Expected] = Accept,
        {ok, Sock, Rest}
    catch
        _:Reason -> {error, {handshake_failed, Reason}}
    end.

recv_head(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            <<Head:Pos/binary, _:4/binary, Rest/binary>> = Acc,
            {ok, Head, Rest};
        nomatch ->
            {ok, Chunk} = gen_tcp:recv(Sock, 0, ?TIMEOUT),
            recv_head(Sock, <<Acc/binary, Chunk/binary>>)
    end.

loop(S = #{sock := Sock}) ->
    ok = inet:setopts(Sock, [{active, once}]),
    receive
        {request, From, MRef, Action, Params} ->
            Ref = maps:get(next, S),
            Msg = reddit_json:encode(Params#{action => Action, ref => Ref}),
            trace(S, ">>", Msg),
            ok = gen_tcp:send(Sock, reddit_ws:encode_frame(1, Msg, true)),
            Pending = maps:get(pending, S),
            loop(S#{next => Ref + 1, pending => Pending#{Ref => {From, MRef}}});
        {tcp, Sock, Data} ->
            loop(parse(<<(maps:get(buf, S))/binary, Data/binary>>, S));
        {tcp_closed, Sock} ->
            closed(S);
        {tcp_error, Sock, _} ->
            closed(S);
        {trace, OnOff, Label} ->
            loop(S#{trace => OnOff, label => Label});
        close ->
            gen_tcp:send(Sock, reddit_ws:encode_frame(8, <<1000:16>>, true)),
            gen_tcp:close(Sock),
            closed(S)
    end.

closed(#{owner := Owner}) ->
    Owner ! {reddit_ws_closed, self()},
    exit(normal).

parse(Bin, S = #{sock := Sock}) ->
    case reddit_ws:decode_frame(Bin) of
        more ->
            S#{buf => Bin};
        {error, _} ->
            gen_tcp:close(Sock),
            closed(S);
        {frame, 1, Op, Payload, Rest} when Op =:= 1; Op =:= 2 ->
            parse(Rest, message(Payload, S#{buf => <<>>}));
        {frame, 0, Op, Payload, Rest} when Op =:= 1; Op =:= 2 ->
            parse(Rest, S#{buf => <<>>, frag => Payload});
        {frame, Fin, 0, Payload, Rest} ->
            Whole = <<(maps:get(frag, S))/binary, Payload/binary>>,
            case Fin of
                1 -> parse(Rest, message(Whole, S#{buf => <<>>, frag => undefined}));
                0 -> parse(Rest, S#{buf => <<>>, frag => Whole})
            end;
        {frame, _, 9, Payload, Rest} ->              % ping
            gen_tcp:send(Sock, reddit_ws:encode_frame(10, Payload, true)),
            parse(Rest, S#{buf => <<>>});
        {frame, _, 8, _, _} ->                       % close
            gen_tcp:close(Sock),
            closed(S);
        {frame, _, _, _, Rest} ->                    % pong, others
            parse(Rest, S#{buf => <<>>})
    end.

message(Payload, S = #{owner := Owner, pending := Pending}) ->
    trace(S, "<<", Payload),
    case reddit_json:decode(Payload) of
        {ok, #{<<"push">> := Type} = Msg} ->
            Owner ! {reddit_ws_push, self(), Type, maps:get(<<"data">>, Msg, null)},
            S;
        {ok, #{<<"ref">> := Ref} = Msg} when is_map_key(Ref, Pending) ->
            {From, MRef} = maps:get(Ref, Pending),
            From ! {ws_reply, MRef, Msg},
            S#{pending => maps:remove(Ref, Pending)};
        _ ->
            S
    end.

trace(#{trace := false}, _, _) ->
    ok;
trace(#{label := Label}, Dir, Json) ->
    Text = case string:slice(Json, 0, ?TRACE_CHARS) of
               Json -> Json;
               Short -> [Short, "..."]
           end,
    io:format("  ~ts ~s ~ts~n", [Label, Dir, Text]).
