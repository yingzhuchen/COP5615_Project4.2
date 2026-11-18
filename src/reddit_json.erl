%% Minimal JSON encoder for REST responses.
-module(reddit_json).
-export([encode/1]).

encode(Term) -> iolist_to_binary(value(Term)).

value(undefined) -> <<"null">>;
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
escape([C | Rest], Acc) -> escape(Rest, [C | Acc]).

join([]) -> [];
join([One]) -> One;
join([H | T]) -> [H, <<",">>, join(T)].
