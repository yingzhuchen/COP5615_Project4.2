%% WebSocket interface to the engine (RFC 6455, dependency-free).
%%
%% reddit_http hands a connection here when a client sends
%% `GET /ws` with `Upgrade: websocket`. Every WebSocket text frame carries
%% one JSON command; the server answers each command with one JSON frame:
%%
%%   -> {"ref": 7, "action": "post", "sub": "erlang", "title": "Hi", "body": "..."}
%%   <- {"ref": 7, "ok": true, "data": {"id": 12}}
%%   <- {"ref": 8, "ok": false, "error": "not_member"}
%%
%% `ref` is any value the client picks to match replies to requests.
%%
%% A connection acts for one user after `login`. The engine then treats the
%% connection as that user's live session and pushes events to it at any
%% time, without a request:
%%
%%   <- {"push": "dm",       "data": {"id": 3, "from": "bob"}}
%%   <- {"push": "reply",    "data": {"comment_id": 9, "parent": 5, "from": "bob"}}
%%   <- {"push": "new_post", "data": {...post...}}
%%
%% This module also holds the framing helpers used by reddit_ws_client.
-module(reddit_ws).
-export([serve/3, accept_key/1, encode_frame/3, decode_frame/1]).

-define(GUID, <<"258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>).
-define(MAX_PAYLOAD, 1048576).   % 1 MB per message

-define(OP_CONT, 0).
-define(OP_TEXT, 1).
-define(OP_BINARY, 2).
-define(OP_CLOSE, 8).
-define(OP_PING, 9).
-define(OP_PONG, 10).

%% ---------------------------------------------------------------- framing

accept_key(Key) ->
    base64:encode(crypto:hash(sha, <<Key/binary, ?GUID/binary>>)).

%% Servers send unmasked frames; clients must mask theirs.
encode_frame(Op, Payload, Masked) ->
    Len = byte_size(Payload),
    LenBits = if
                  Len < 126 -> <<Len:7>>;
                  Len < 65536 -> <<126:7, Len:16>>;
                  true -> <<127:7, Len:64>>
              end,
    case Masked of
        false ->
            <<1:1, 0:3, Op:4, 0:1, LenBits/bitstring, Payload/binary>>;
        true ->
            Key = crypto:strong_rand_bytes(4),
            <<1:1, 0:3, Op:4, 1:1, LenBits/bitstring, Key/binary,
              (mask(Payload, Key))/binary>>
    end.

%% -> {frame, Fin, Opcode, Payload, Rest} | more | {error, too_big}
decode_frame(<<Fin:1, _Rsv:3, Op:4, Masked:1, Len0:7, Rest/binary>>) ->
    case {Len0, Rest} of
        {126, <<Len:16, R/binary>>} -> payload(Fin, Op, Masked, Len, R);
        {127, <<Len:64, R/binary>>} -> payload(Fin, Op, Masked, Len, R);
        {126, _} -> more;
        {127, _} -> more;
        {Len, R} -> payload(Fin, Op, Masked, Len, R)
    end;
decode_frame(_) ->
    more.

payload(_, _, _, Len, _) when Len > ?MAX_PAYLOAD ->
    {error, too_big};
payload(Fin, Op, Masked, Len, Bin) ->
    case {Masked, Bin} of
        {1, <<Key:4/binary, Data:Len/binary, Rest/binary>>} ->
            {frame, Fin, Op, mask(Data, Key), Rest};
        {0, <<Data:Len/binary, Rest/binary>>} ->
            {frame, Fin, Op, Data, Rest};
        _ ->
            more
    end.

%% XOR with the 4-byte key (masking and unmasking are the same operation).
mask(Data, <<K:32>>) -> mask(Data, K, <<>>).

mask(<<D:32, Rest/binary>>, K, Acc) -> mask(Rest, K, <<Acc/binary, (D bxor K):32>>);
mask(<<D:24>>, K, Acc) -> <<Acc/binary, (D bxor (K bsr 8)):24>>;
mask(<<D:16>>, K, Acc) -> <<Acc/binary, (D bxor (K bsr 16)):16>>;
mask(<<D:8>>, K, Acc) -> <<Acc/binary, (D bxor (K bsr 24)):8>>;
mask(<<>>, _, Acc) -> Acc.

%% ------------------------------------------------------- server handshake

%% Called by reddit_http in the connection's process, which owns Socket.
%% Rest holds any bytes that arrived after the HTTP headers.
serve(Socket, Headers, Rest) ->
    Key = maps:get(<<"sec-websocket-key">>, Headers, undefined),
    Version = maps:get(<<"sec-websocket-version">>, Headers, undefined),
    case {Key, Version} of
        {undefined, _} -> reject(Socket, <<"missing Sec-WebSocket-Key">>);
        {_, <<"13">>} ->
            ok = gen_tcp:send(Socket,
                              ["HTTP/1.1 101 Switching Protocols\r\n"
                               "Upgrade: websocket\r\n"
                               "Connection: Upgrade\r\n"
                               "Sec-WebSocket-Accept: ", accept_key(Key), "\r\n\r\n"]),
            S = #{socket => Socket, buf => <<>>, frag => undefined, user => undefined},
            Peer = peer(Socket),
            reddit_log:line("WS   connection opened from ~s", [Peer]),
            try
                case frames(Rest, S) of
                    {ok, S1} -> loop(S1);
                    {close, _} -> ok
                end
            after
                reddit_log:line("WS   connection closed from ~s~ts",
                                [Peer, case get(reddit_ws_user) of
                                           undefined -> "";
                                           U -> [" (", U, ")"]
                                       end]),
                logout_current(),
                gen_tcp:close(Socket)
            end;
        _ -> reject(Socket, <<"unsupported Sec-WebSocket-Version (need 13)">>)
    end.

reject(Socket, Why) ->
    gen_tcp:send(Socket, ["HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\n"
                          "Content-Length: ", integer_to_list(byte_size(Why)),
                          "\r\nConnection: close\r\n\r\n", Why]),
    gen_tcp:close(Socket).

%% ----------------------------------------------------------- session loop

loop(S = #{socket := Sock}) ->
    ok = inet:setopts(Sock, [{active, once}]),
    receive
        {tcp, Sock, Data} ->
            case frames(Data, S) of
                {ok, S1} -> loop(S1);
                {close, _} -> ok
            end;
        {tcp_closed, Sock} -> ok;
        {tcp_error, Sock, _} -> ok;
        {reddit_push, Event} ->
            send_json(Sock, push_message(Event)),
            log_push(S, Event),
            loop(S)
    end.

peer(Socket) ->
    case inet:peername(Socket) of
        {ok, {Ip, Port}} -> [inet:ntoa(Ip), ":", integer_to_list(Port)];
        _ -> "unknown"
    end.

log_push(#{user := User}, Event) ->
    {Type, Detail} = case Event of
                         {dm, #{id := Id, from := From}} ->
                             {"dm", [" #", integer_to_list(Id), " from ", From]};
                         {reply, #{comment_id := C, from := From}} ->
                             {"reply", [" comment #", integer_to_list(C), " from ", From]};
                         {new_post, #{id := Id, author := A, sub := Sub}} ->
                             {"new_post", [" #", integer_to_list(Id), " by ", A, " in r/", Sub]};
                         _ ->
                             {"other", ""}
                     end,
    reddit_log:line("WS   push ~s -> ~ts~ts", [Type, who(User), Detail]).

who(undefined) -> "guest";
who(User) -> User.

frames(Data, S = #{buf := Buf}) ->
    parse(<<Buf/binary, Data/binary>>, S).

parse(Bin, S = #{socket := Sock}) ->
    case decode_frame(Bin) of
        more -> {ok, S#{buf => Bin}};
        {error, too_big} ->
            send_close(Sock, 1009),
            {close, S};
        {frame, Fin, Op, Payload, Rest} ->
            case frame(Fin, Op, Payload, S) of
                {ok, S1} -> parse(Rest, S1#{buf => <<>>});
                {close, S1} -> {close, S1}
            end
    end.

frame(1, Op, Payload, S) when Op =:= ?OP_TEXT; Op =:= ?OP_BINARY ->
    {ok, message(Payload, S)};
frame(0, Op, Payload, S) when Op =:= ?OP_TEXT; Op =:= ?OP_BINARY ->
    {ok, S#{frag => Payload}};
frame(Fin, ?OP_CONT, Payload, S = #{frag := Frag}) when is_binary(Frag) ->
    Whole = <<Frag/binary, Payload/binary>>,
    case Fin of
        1 -> {ok, message(Whole, S#{frag => undefined})};
        0 -> {ok, S#{frag => Whole}}
    end;
frame(_, ?OP_CLOSE, _Payload, S = #{socket := Sock}) ->
    send_close(Sock, 1000),
    {close, S};
frame(_, ?OP_PING, Payload, S = #{socket := Sock}) ->
    gen_tcp:send(Sock, encode_frame(?OP_PONG, Payload, false)),
    {ok, S};
frame(_, ?OP_PONG, _Payload, S) ->
    {ok, S};
frame(_, _Op, _Payload, S = #{socket := Sock}) ->
    send_close(Sock, 1002),   % protocol error
    {close, S}.

send_close(Sock, Code) ->
    gen_tcp:send(Sock, encode_frame(?OP_CLOSE, <<Code:16>>, false)).

send_json(Sock, Term) ->
    gen_tcp:send(Sock, encode_frame(?OP_TEXT, reddit_json:encode(Term), false)).

%% One JSON command -> one JSON reply.
message(Payload, S = #{socket := Sock}) ->
    case reddit_json:decode(Payload) of
        {ok, Msg = #{<<"action">> := Action}} when is_binary(Action) ->
            T0 = erlang:monotonic_time(microsecond),
            Ref = maps:get(<<"ref">>, Msg, null),
            {Reply, S1} = try action(Action, Msg, S)
                          catch
                              throw:{bad_request, Why} -> {{error, Why}, S};
                              exit:{timeout, _} -> {{error, timeout}, S}
                          end,
            send_json(Sock, reply(Ref, Reply)),
            %% e.g. [12:03:41.512] WS   carol: post sub=erlang title=Hi -> ok id=5 (0.9 ms)
            reddit_log:line("WS   ~ts: ~ts~ts ->~ts (~.1f ms)",
                            [who(maps:get(user, S)), Action,
                             reddit_log:params(Msg),
                             reddit_log:engine_result(log_reply(Reply)),
                             (erlang:monotonic_time(microsecond) - T0) / 1000]),
            S1;
        {ok, _} ->
            send_json(Sock, reply(null, {error, missing_action})),
            S;
        {error, _} ->
            send_json(Sock, reply(null, {error, invalid_json})),
            S
    end.

log_reply({error, Why}) -> {error, reason(Why)};
log_reply(Reply) -> Reply.

reply(Ref, ok) -> #{ref => Ref, ok => true};
reply(Ref, {ok, Id}) when is_integer(Id) -> #{ref => Ref, ok => true, data => #{id => Id}};
reply(Ref, {ok, Data}) -> #{ref => Ref, ok => true, data => Data};
reply(Ref, {error, Why}) -> #{ref => Ref, ok => false, error => reason(Why)}.

reason(A) when is_atom(A) -> atom_to_binary(A, utf8);
reason(B) when is_binary(B) -> B;
reason({missing, Field}) -> <<"missing field: ", Field/binary>>;
reason({bad_field, Field}) -> <<"bad field: ", Field/binary>>;
reason(Other) -> iolist_to_binary(io_lib:format("~p", [Other])).

push_message({dm, Info}) -> #{push => dm, data => Info};
push_message({reply, Info}) -> #{push => reply, data => Info};
push_message({new_post, View}) -> #{push => new_post, data => View};
push_message(Other) -> #{push => other, data => reason(Other)}.

%% ---------------------------------------------------------------- actions

%% Actions that need no logged-in user.
action(<<"register">>, M, S) ->
    U = text(M, <<"user">>),
    Req = case maps:get(<<"public_key">>, M, null) of
              Pem when is_binary(Pem), Pem =/= <<>> -> {register_signed, U, Pem};
              _ -> {register, U}
          end,
    {reddit_engine:call(U, Req), S};
action(<<"login">>, M, S) ->
    U = text(M, <<"user">>),
    S1 = logout(S),
    case reddit_engine:call(U, {connect, U, self()}) of
        ok ->
            put(reddit_ws_user, U),
            {{ok, #{user => U}}, S1#{user => U}};
        Error ->
            {Error, S1}
    end;
action(<<"logout">>, _M, S) ->
    {ok, logout(S)};
action(<<"get_public_key">>, M, S) ->
    U = text(M, <<"user">>),
    {reddit_engine:call(U, {get_public_key, U}), S};
action(<<"get_post">>, M, S) ->
    {reddit_engine:call(<<>>, {get_post, <<>>, int(M, <<"post_id">>)}), S};
action(<<"search">>, M, S) ->
    Q = text(M, <<"q">>),
    {reddit_engine:call(Q, {search, Q, int(M, <<"limit">>, 25)}), S};
action(<<"list_subs">>, M, S) ->
    Q = case maps:get(<<"q">>, M, null) of
            B when is_binary(B) -> B;
            _ -> <<>>
        end,
    {reddit_engine:call(Q, {list_subs, Q}), S};
%% Everything else acts as the logged-in user.
action(Action, M, S = #{user := User}) ->
    Req = user_request(Action, User, M),
    User =:= undefined andalso throw({bad_request, not_logged_in}),
    {reddit_engine:call(User, Req), S}.

user_request(<<"create_sub">>, U, M) -> {create_sub, U, text(M, <<"sub">>)};
user_request(<<"join_sub">>, U, M) -> {join_sub, U, text(M, <<"sub">>)};
user_request(<<"leave_sub">>, U, M) -> {leave_sub, U, text(M, <<"sub">>)};
user_request(<<"post">>, U, M) ->
    Sub = text(M, <<"sub">>),
    Title = text(M, <<"title">>),
    Body = text(M, <<"body">>),
    case signature(M) of
        none -> {post, U, Sub, Title, Body};
        Sig -> {post_signed, U, Sub, Title, Body, Sig}
    end;
user_request(<<"repost">>, U, M) ->
    Sub = text(M, <<"sub">>),
    Id = int(M, <<"post_id">>),
    case signature(M) of
        none -> {repost, U, Sub, Id};
        Sig -> {repost_signed, U, Sub, Id, Sig}
    end;
user_request(<<"comment">>, U, M) ->
    {comment, U, int(M, <<"parent_id">>), text(M, <<"body">>)};
user_request(<<"vote">>, U, M) ->
    Dir = case text(M, <<"direction">>) of
              <<"up">> -> up;
              <<"down">> -> down;
              <<"none">> -> none;
              _ -> throw({bad_request, bad_direction})
          end,
    {vote, U, int(M, <<"item_id">>), Dir};
user_request(<<"get_feed">>, U, M) ->
    Sort = case maps:get(<<"sort">>, M, <<"hot">>) of
               <<"new">> -> new;
               <<"top">> -> top;
               _ -> hot
           end,
    {get_feed, U, int(M, <<"limit">>, 25), Sort};
user_request(<<"get_karma">>, U, M) ->
    {get_karma, case maps:get(<<"user">>, M, null) of
                    Other when is_binary(Other), Other =/= <<>> -> Other;
                    _ -> U
                end};
user_request(<<"send_dm">>, U, M) -> {send_dm, U, text(M, <<"to">>), text(M, <<"body">>)};
user_request(<<"reply_dm">>, U, M) -> {reply_dm, U, int(M, <<"dm_id">>), text(M, <<"body">>)};
user_request(<<"get_dms">>, U, M) -> {get_dms, U, int(M, <<"limit">>, 20)};
user_request(_, _, _) -> throw({bad_request, unknown_action}).

logout(S = #{user := undefined}) -> S;
logout(S) -> logout_current(), S#{user => undefined}.

%% Go offline, unless a newer connection has already logged in as this user.
logout_current() ->
    case erase(reddit_ws_user) of
        undefined -> ok;
        U ->
            Self = self(),
            case reddit_ops:online_pid(U) of
                {ok, Self} ->
                    try reddit_engine:call(U, {disconnect, U}) catch _:_ -> ok end,
                    ok;
                _ -> ok
            end
    end.

%% ----------------------------------------------------------------- fields

text(M, Key) ->
    case maps:get(Key, M, null) of
        V when is_binary(V), V =/= <<>> -> V;
        V when is_integer(V) -> integer_to_binary(V);
        null -> throw({bad_request, {missing, Key}});
        <<>> -> throw({bad_request, {missing, Key}});
        _ -> throw({bad_request, {bad_field, Key}})
    end.

int(M, Key) ->
    case maps:get(Key, M, null) of
        null -> throw({bad_request, {missing, Key}});
        V -> to_int(V, Key)
    end.

int(M, Key, Default) ->
    case maps:get(Key, M, null) of
        null -> Default;
        V -> to_int(V, Key)
    end.

to_int(V, _) when is_integer(V) -> V;
to_int(V, Key) when is_binary(V) ->
    try binary_to_integer(V)
    catch error:badarg -> throw({bad_request, {bad_field, Key}})
    end;
to_int(_, Key) -> throw({bad_request, {bad_field, Key}}).

signature(M) ->
    case maps:get(<<"signature">>, M, null) of
        Sig when is_binary(Sig), Sig =/= <<>> -> Sig;
        _ -> none
    end.
