%% Request log for the REST + WebSocket server: one timestamped line per
%% REST request, WebSocket message and live push, printed in the server's
%% window. reddit_api_main turns it on (`log false` turns it off); it is off
%% by default, e.g. in the tests.
-module(reddit_log).
-export([set_enabled/1, enabled/0, line/2, params/1, http_result/1, engine_result/1]).

-define(KEY, reddit_request_log).
%% Fields shown in a log line, in this order. Bodies, signatures and keys
%% are left out (only their presence is shown).
-define(FIELDS, [<<"user">>, <<"to">>, <<"sub">>, <<"title">>, <<"post_id">>,
                 <<"parent_id">>, <<"item_id">>, <<"direction">>, <<"dm_id">>,
                 <<"q">>, <<"sort">>, <<"limit">>]).
-define(MAX_VALUE, 32).

set_enabled(OnOff) -> persistent_term:put(?KEY, OnOff =:= true).

enabled() -> persistent_term:get(?KEY, false).

line(Fmt, Args) ->
    case enabled() of
        true ->
            Ms = erlang:system_time(millisecond),
            {_, {H, M, S}} = calendar:system_time_to_local_time(Ms div 1000, second),
            io:format("[~2..0b:~2..0b:~2..0b.~3..0b] " ++ Fmt ++ "~n",
                      [H, M, S, Ms rem 1000 | Args]);
        false ->
            ok
    end.

%% " user=carol sub=erlang title=\"Hello world\" +signature" for a map with
%% binary keys (REST parameters or a decoded WebSocket command).
params(Map) ->
    Shown = [[" ", K, "=", value(V)] || K <- ?FIELDS, V <- [maps:get(K, Map, null)],
                                        V =/= null, V =/= <<>>],
    Extra = [[" +", Name] || {K, Name} <- [{<<"public_key">>, "public_key"},
                                           {<<"signature">>, "signature"},
                                           {<<"body">>, "body"}],
                             maps:is_key(K, Map)],
    [Shown, Extra].

value(V) when is_integer(V) -> integer_to_list(V);
value(V) when is_binary(V) ->
    Chars = case unicode:characters_to_list(V) of
                L when is_list(L) -> L;
                _ -> binary_to_list(V)
            end,
    Short = case length(Chars) > ?MAX_VALUE of
                true -> lists:sublist(Chars, ?MAX_VALUE) ++ "...";
                false -> Chars
            end,
    case lists:member($\s, Short) of
        true -> [$", Short, $"];
        false -> Short
    end;
value(V) -> io_lib:format("~p", [V]).

%% {Status, Summary} for a reply built by reddit_http.
http_result({bad_request, Why}) -> {400, [" ", reason(Why)]};
http_result({error, Why}) -> {400, [" ", reason(Why)]};
http_result({Status, #{error := Why}}) -> {Status, [" ", reason(Why)]};
http_result({Status, Value}) -> {Status, summary(Value)}.

%% Summary of an engine reply (WebSocket side).
engine_result(ok) -> " ok";
engine_result({ok, Value}) -> [" ok", summary(Value)];
engine_result({error, Why}) -> [" error ", reason(Why)].

summary(Id) when is_integer(Id) -> [" id=", integer_to_list(Id)];
summary([_]) -> " (1 item)";
summary(List) when is_list(List) -> io_lib:format(" (~b items)", [length(List)]);
summary(_) -> "".

reason(A) when is_atom(A) -> atom_to_list(A);
reason(B) when is_binary(B) -> value(B);
reason(Other) -> io_lib:format("~p", [Other]).
