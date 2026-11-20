#!/usr/bin/env bash
# Build, test and run the Reddit engine simulator.
#
#   ./run.sh build                      compile into ebin/
#   ./run.sh test                       run the engine unit tests
#   ./run.sh sim [key value ...]        engine + client processes on this machine
#   ./run.sh engine clients N [...]     engine only; waits for N external clients
#   ./run.sh client ENGINE_NODE         one client process (e.g. engine@myhost)
#   ./run.sh api [PORT] [log false]     engine + REST API + WebSocket server
#   ./run.sh demo [BASE_URL]            REST API client demonstration
#   ./run.sh rest [BASE_URL] [USER]     interactive client over the REST API
#   ./run.sh ws [WS_URL] [USER]         interactive client over WebSocket
#   ./run.sh wsdemo [WS_URL]            scripted multi-client WebSocket demo
#
# Example: ./run.sh sim users 20000 clients 4 duration 60
set -e
cd "$(dirname "$0")"
COOKIE=${COOKIE:-reddit}
ERL_FLAGS_COMMON=(-setcookie "$COOKIE" -pa ebin -noshell +zdbbl 32768)

build() {
    mkdir -p ebin
    erl -noshell -eval 'case make:all() of up_to_date -> halt(0); _ -> halt(1) end.'
}

cmd=${1:-sim}
shift || true
case "$cmd" in
    build) build ;;
    test)
        build
        erl -noshell -pa ebin -eval 'halt(case eunit:test(reddit_tests, [verbose]) of ok -> 0; _ -> 1 end).'
        ;;
    sim)
        build
        erl -sname engine "${ERL_FLAGS_COMMON[@]}" -run reddit_main main "$@"
        ;;
    engine)
        build
        erl -sname engine "${ERL_FLAGS_COMMON[@]}" -run reddit_main main mode engine "$@"
        ;;
    client)
        build
        erl -sname "client$$" "${ERL_FLAGS_COMMON[@]}" -run reddit_sim main "$1"
        ;;
    api)
        build
        erl -sname api "${ERL_FLAGS_COMMON[@]}" -run reddit_api_main main "$@"
        ;;
    demo)
        build
        erl -noshell -pa ebin -run reddit_rest_demo main "$@"
        ;;
    rest)
        build
        erl -noshell -pa ebin -run reddit_ws_cli main_rest "$@"
        ;;
    ws)
        build
        erl -noshell -pa ebin -run reddit_ws_cli main "$@"
        ;;
    wsdemo)
        build
        erl -noshell -pa ebin -run reddit_ws_demo main "$@"
        ;;
    *)
        echo "unknown command: $cmd" >&2
        exit 1
        ;;
esac
