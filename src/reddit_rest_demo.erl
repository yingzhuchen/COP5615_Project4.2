%% Command-line demo that exercises the REST API through the REST client.
-module(reddit_rest_demo).
-export([main/1]).

main([]) -> main(["http://localhost:8080"]);
main([Base]) ->
    application:ensure_all_started(inets),
    io:format("POST /api/users~n~p~n", [reddit_rest_client:register(Base, <<"alice">>)]),
    io:format("POST /api/users~n~p~n", [reddit_rest_client:register(Base, <<"bob">>)]),
    io:format("POST /api/subreddits/create~n~p~n",
              [reddit_rest_client:create_sub(Base, <<"alice">>, <<"erlang">>)]),
    io:format("POST /api/subreddits/join~n~p~n",
              [reddit_rest_client:join_sub(Base, <<"bob">>, <<"erlang">>)]),
    {200, PostBody} = reddit_rest_client:post(
                        Base, <<"alice">>, <<"erlang">>,
                        <<"REST demo">>, <<"Posted through the HTTP API">>),
    io:format("POST /api/posts~n~p~n", [PostBody]),
    PostId = list_to_integer(PostBody),
    io:format("POST /api/comments~n~p~n",
              [reddit_rest_client:comment(Base, <<"bob">>, PostId, <<"nice post">>)]),
    io:format("POST /api/votes~n~p~n",
              [reddit_rest_client:vote(Base, <<"bob">>, PostId, up)]),
    io:format("GET /api/posts/<id>~n~p~n",
              [reddit_rest_client:post_view(Base, PostId)]),
    io:format("GET /api/karma~n~p~n",
              [reddit_rest_client:karma(Base, <<"alice">>)]),
    io:format("GET /api/feed~n~p~n", [reddit_rest_client:feed(Base, <<"bob">>, 10)]),
    io:format("POST /api/reposts~n~p~n",
              [reddit_rest_client:repost(Base, <<"bob">>, <<"erlang">>, PostId)]),
    io:format("POST /api/messages~n~p~n",
              [reddit_rest_client:send_dm(Base, <<"alice">>, <<"bob">>, <<"hello">>)]),
    io:format("GET /api/messages~n~p~n", [reddit_rest_client:dms(Base, <<"bob">>)]),
    io:format("POST /api/subreddits/leave~n~p~n",
              [reddit_rest_client:leave_sub(Base, <<"bob">>, <<"erlang">>)]),
    halt(0).
