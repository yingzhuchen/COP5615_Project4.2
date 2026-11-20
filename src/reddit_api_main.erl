%% Starts the 4.1 engine together with the 4.2 REST + WebSocket server.
%%
%%   erl ... -run reddit_api_main main [PORT] [push_posts true|false] [log true|false]
%%
%% push_posts (default true) pushes every new post to the WebSocket
%% connections of the subreddit's online members. log (default true) prints
%% one line per REST request, WebSocket message and push.
-module(reddit_api_main).
-export([main/1]).

main([]) -> main(["8080"]);
main([Port0 | Args]) ->
    Port = list_to_integer(Port0),
    Opts = options(Args, #{push_posts => true, log => true}),
    #{push_posts := PushPosts, log := Log} = Opts,
    Workers = erlang:system_info(schedulers_online) * 2,
    ok = reddit_engine:start(Workers, #{push_posts => PushPosts}),
    reddit_log:set_enabled(Log),
    {ok, _} = reddit_http:start(Port),
    io:format("REST server listening on http://localhost:~p/api~n"
              "WebSocket endpoint at   ws://localhost:~p/ws~n"
              "push_posts ~p, request log ~s~n",
              [Port, Port, PushPosts,
               case Log of true -> "on (one line per request below)"; false -> "off" end]),
    receive
        stop -> reddit_http:stop(), reddit_engine:stop(), ok
    end.

options([Key, Value | Rest], Opts) when Key =:= "push_posts"; Key =:= "log" ->
    options(Rest, Opts#{list_to_atom(Key) => Value =/= "false"});
options([Other | Rest], Opts) ->
    io:format("ignoring unknown option ~s~n", [Other]),
    options(Rest, Opts);
options([], Opts) ->
    Opts.
