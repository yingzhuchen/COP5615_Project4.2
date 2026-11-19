%% Starts the 4.1 engine together with the 4.2 REST + WebSocket server.
%%
%%   erl ... -run reddit_api_main main [PORT] [push_posts true|false]
%%
%% push_posts (default true) pushes every new post to the WebSocket
%% connections of the subreddit's online members.
-module(reddit_api_main).
-export([main/1]).

main([]) -> main(["8080"]);
main([Port0 | Opts]) ->
    Port = list_to_integer(Port0),
    PushPosts = case Opts of
                    ["push_posts", "false" | _] -> false;
                    _ -> true
                end,
    Workers = erlang:system_info(schedulers_online) * 2,
    ok = reddit_engine:start(Workers, #{push_posts => PushPosts}),
    {ok, _} = reddit_http:start(Port),
    io:format("REST server listening on http://localhost:~p/api~n"
              "WebSocket endpoint at   ws://localhost:~p/ws (push_posts ~p)~n",
              [Port, Port, PushPosts]),
    receive
        stop -> reddit_http:stop(), reddit_engine:stop(), ok
    end.
