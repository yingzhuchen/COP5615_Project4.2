%% Minimal dependency-free JSON encoder and decoder, used by the REST
%% responses and by both ends of the WebSocket interface.
%%
%% Decoding maps objects to maps with binary keys, arrays to lists, strings
%% to UTF-8 binaries, and true / false / null to the atoms true, false, null.
-module(reddit_json).
-export([encode/1, decode/1]).

%% ------------------------------------------------------------------ encode

encode(Term) -> iolist_to_binary(value(Term)).

value(undefined) -> <<"null">>;
value(null) -> <<"null">>;
value(true) -> <<"true">>;
value(false) -> <<"false">>;
value(N) when is_integer(N) -> integer_to_binary(N);
value(N) when is_float(N) -> float_to_binary(N, [compact]);
value(B) when is_binary(B) -> string(B);
value(A) when is_atom(A) -> string(atom_to_binary(A, utf8));
value(M) when is_map(M) ->
    Parts = [[string(key(K)), <<":">>, value(V)] || {K, V} <- maps:to_list(M)],
    [<<"{">>, join(Parts), <<"}">>];
value(L) when is_list(L) ->
    [<<"[">>, join([value(V) || V <- L]), <<"]">>].

key(K) when is_binary(K) -> K;
key(K) when is_atom(K) -> atom_to_binary(K, utf8);
key(K) when is_integer(K) -> integer_to_binary(K);
key(K) -> iolist_to_binary(io_lib:format("~p", [K])).

string(B) -> [<<"\"">>, escape(binary_to_list(B), []), <<"\"">>].

escape([], Acc) -> lists:reverse(Acc);
escape([$" | Rest], Acc) -> escape(Rest, [$", $\\ | Acc]);
escape([$\\ | Rest], Acc) -> escape(Rest, [$\\, $\\ | Acc]);
escape([$\n | Rest], Acc) -> escape(Rest, [$n, $\\ | Acc]);
escape([$\r | Rest], Acc) -> escape(Rest, [$r, $\\ | Acc]);
escape([$\t | Rest], Acc) -> escape(Rest, [$t, $\\ | Acc]);
escape([C | Rest], Acc) when C < 16#20 ->
    %% Other control characters are not allowed raw inside a JSON string.
    escape(Rest, lists:reverse(io_lib:format("\\u~4.16.0b", [C])) ++ Acc);
escape([C | Rest], Acc) -> escape(Rest, [C | Acc]).

join([]) -> [];
join([One]) -> One;
join([H | T]) -> [H, <<",">>, join(T)].

%% ------------------------------------------------------------------ decode

decode(Bin) when is_binary(Bin) ->
    try
        {Value, Rest} = dvalue(ws(Bin)),
        case ws(Rest) of
            <<>> -> {ok, Value};
            _ -> {error, invalid_json}
        end
    catch
        _:_ -> {error, invalid_json}
    end;
decode(_) ->
    {error, invalid_json}.

ws(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> ws(Rest);
ws(Bin) -> Bin.

dvalue(<<${, Rest/binary>>) -> object(ws(Rest), #{});
dvalue(<<$[, Rest/binary>>) -> array(ws(Rest), []);
dvalue(<<$", Rest/binary>>) -> dstring(Rest, []);
dvalue(<<"true", Rest/binary>>) -> {true, Rest};
dvalue(<<"false", Rest/binary>>) -> {false, Rest};
dvalue(<<"null", Rest/binary>>) -> {null, Rest};
dvalue(Bin) -> number(Bin).

object(<<$}, Rest/binary>>, Acc) when map_size(Acc) =:= 0 -> {Acc, Rest};
object(<<$", Rest/binary>>, Acc) ->
    {Key, R1} = dstring(Rest, []),
    <<$:, R2/binary>> = ws(R1),
    {Value, R3} = dvalue(ws(R2)),
    Acc1 = Acc#{Key => Value},
    case ws(R3) of
        <<$,, R4/binary>> -> object(ws(R4), Acc1);
        <<$}, R4/binary>> -> {Acc1, R4}
    end.

array(<<$], Rest/binary>>, []) -> {[], Rest};
array(Bin, Acc) ->
    {Value, R1} = dvalue(Bin),
    case ws(R1) of
        <<$,, R2/binary>> -> array(ws(R2), [Value | Acc]);
        <<$], R2/binary>> -> {lists:reverse([Value | Acc]), R2}
    end.

%% Acc holds raw bytes and UTF-8 binaries, newest first.
dstring(<<$", Rest/binary>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Rest};
dstring(<<$\\, $u, Hex:4/binary, Rest/binary>>, Acc) ->
    case binary_to_integer(Hex, 16) of
        High when High >= 16#D800, High =< 16#DBFF ->
            <<$\\, $u, Hex2:4/binary, R2/binary>> = Rest,
            Low = binary_to_integer(Hex2, 16),
            true = Low >= 16#DC00 andalso Low =< 16#DFFF,
            Cp = 16#10000 + ((High - 16#D800) bsl 10) + (Low - 16#DC00),
            dstring(R2, [<<Cp/utf8>> | Acc]);
        Cp ->
            dstring(Rest, [<<Cp/utf8>> | Acc])
    end;
dstring(<<$\\, C, Rest/binary>>, Acc) ->
    Char = case C of
               $" -> $";
               $\\ -> $\\;
               $/ -> $/;
               $b -> $\b;
               $f -> $\f;
               $n -> $\n;
               $r -> $\r;
               $t -> $\t
           end,
    dstring(Rest, [Char | Acc]);
dstring(<<C, Rest/binary>>, Acc) when C >= 16#20 ->
    dstring(Rest, [C | Acc]).

number(Bin) ->
    {Num, Rest} = take_number(Bin, []),
    Num =/= [] orelse error(badarg),
    case lists:any(fun(C) -> lists:member(C, ".eE") end, Num) of
        false -> {list_to_integer(Num), Rest};
        true -> {list_to_float(float_text(Num)), Rest}
    end.

take_number(<<C, Rest/binary>>, Acc)
  when C >= $0, C =< $9; C =:= $-; C =:= $+; C =:= $.; C =:= $e; C =:= $E ->
    take_number(Rest, [C | Acc]);
take_number(Rest, Acc) ->
    {lists:reverse(Acc), Rest}.

%% list_to_float needs a fraction: "1e5" -> "1.0e5".
float_text(Num) ->
    case lists:member($., Num) of
        true -> Num;
        false ->
            {Mantissa, Exp} = lists:splitwith(fun(C) -> C =/= $e andalso C =/= $E end, Num),
            Mantissa ++ ".0" ++ Exp
    end.
