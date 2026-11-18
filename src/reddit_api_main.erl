%% Starts the 4.1 engine together with the 4.2 REST server.
-module(reddit_api_main).
-export([main/1]).

main([]) -> main(["8080"]);
main([Port0 | _]) ->
    Port = list_to_integer(Port0),
    Workers = erlang:system_info(schedulers_online) * 2,
    ok = reddit_engine:start(Workers),
    {ok, _} = reddit_http:start(Port),
    io:format("REST server listening on http://localhost:~p~n", [Port]),
    receive
        stop -> reddit_http:stop(), reddit_engine:stop(), ok
    end.
