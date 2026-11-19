# Build, test and run the Reddit engine simulator (Windows PowerShell).
#
#   .\run.ps1 build                      compile into ebin\
#   .\run.ps1 test                       run the engine unit tests
#   .\run.ps1 sim [key value ...]        engine + client processes on this machine
#   .\run.ps1 engine clients N [...]     engine only; waits for N external clients
#   .\run.ps1 client ENGINE_NODE         one client process (e.g. engine@myhost)
#   .\run.ps1 api [PORT]                 engine + REST API + WebSocket server
#   .\run.ps1 demo [BASE_URL]            REST API client demonstration
#   .\run.ps1 ws [WS_URL] [USER]         interactive WebSocket client
#   .\run.ps1 wsdemo [WS_URL]            scripted multi-client WebSocket demo
#
# Example: .\run.ps1 sim users 20000 clients 4 duration 60
param(
    [string]$Cmd = "sim",
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$Cookie = if ($env:COOKIE) { $env:COOKIE } else { "reddit" }
$Common = @("-setcookie", $Cookie, "-pa", "ebin", "-noshell", "+zdbbl", "32768")

function Build {
    New-Item -ItemType Directory -Force ebin | Out-Null
    erl -noshell -eval "case make:all() of up_to_date -> halt(0); _ -> halt(1) end."
    if ($LASTEXITCODE -ne 0) { throw "build failed" }
}

switch ($Cmd) {
    "build" { Build }
    "test" {
        Build
        erl -noshell -pa ebin -eval "halt(case eunit:test(reddit_tests, [verbose]) of ok -> 0; _ -> 1 end)."
    }
    "sim" {
        Build
        erl -sname engine @Common -run reddit_main main @Rest
    }
    "engine" {
        Build
        erl -sname engine @Common -run reddit_main main mode engine @Rest
    }
    "client" {
        Build
        erl -sname "client$PID" @Common -run reddit_sim main $Rest[0]
    }
    "api" {
        Build
        erl -sname api @Common -run reddit_api_main main @Rest
    }
    "demo" {
        Build
        erl -noshell -pa ebin -run reddit_rest_demo main @Rest
    }
    "ws" {
        Build
        erl -noshell -pa ebin -run reddit_ws_cli main @Rest
    }
    "wsdemo" {
        Build
        erl -noshell -pa ebin -run reddit_ws_demo main @Rest
    }
    default { throw "unknown command: $Cmd" }
}
