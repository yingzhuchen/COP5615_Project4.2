%% Interactive command-line Reddit client over WebSocket.
%%
%%   ./run.sh ws [ws://localhost:8080/ws] [USER]
%%
%% Run it in several terminals (one OS process each) to act as different
%% users at the same time. Live notifications (new DMs, replies to your
%% posts and comments, new posts in your subreddits) are printed as they
%% arrive. Type `help` for the commands.
%%
%% `register` creates an RSA-2048 key pair, uploads the public key and keeps
%% the private key in keys/<user>.pem; posts and reposts are then signed.
-module(reddit_ws_cli).
-export([main/1, print_post_line/1, print_post/1, print_dms/1, print_push/3]).

-define(KEY_DIR, "keys").

main([]) -> main(["ws://localhost:8080/ws"]);
main([Url | Rest]) ->
    io:setopts([{encoding, unicode}]),
    application:ensure_all_started(public_key),
    Printer = spawn_link(fun printer/0),
    case reddit_ws_client:connect(Url, Printer) of
        {ok, Conn} ->
            io:format("Connected to ~s. Type 'help' for commands.~n", [Url]),
            S0 = #{conn => Conn, printer => Printer, user => undefined,
                   key => undefined, trace => false},
            S = case Rest of
                    [User | _] -> start_as(b(User), S0);
                    [] -> S0
                end,
            repl(S);
        {error, Reason} ->
            io:format("Cannot connect to ~s: ~p~n", [Url, Reason]),
            halt(1)
    end.

%% Log in, registering first if the user does not exist yet.
start_as(User, S) ->
    case request(S, login, #{user => User}) of
        ok_logged_in -> after_login(User, S);
        {error, <<"no_such_user">>} -> register_user(User, S);
        {error, Why} -> error_line(Why), S
    end.

repl(S) ->
    case io:get_line(prompt(S)) of
        eof -> quit(S);
        {error, _} -> quit(S);
        Line ->
            case tokens(unicode:characters_to_list(Line)) of
                [] -> repl(S);
                [Quit | _] when Quit =:= "quit"; Quit =:= "exit" -> quit(S);
                [Cmd | Args] ->
                    S1 = try command(Cmd, [b(A) || A <- Args], S)
                         catch throw:{usage, Usage} ->
                                 io:format("usage: ~ts~n", [Usage]),
                                 S
                         end,
                    repl(S1)
            end
    end.

prompt(#{user := undefined}) -> "> ";
prompt(#{user := U}) -> [U, "> "].

quit(#{conn := Conn, printer := Printer}) ->
    unlink(Printer),
    exit(Printer, kill),   % our own close is not "closed by the server"
    reddit_ws_client:close(Conn),
    timer:sleep(100),
    halt(0).

%% ---------------------------------------------------------------- commands

command("help", _, S) -> help(), S;
command("register", [U], S) -> register_user(U, S);
command("register", _, _) -> throw({usage, "register <user>"});
command("login", [U], S) ->
    case request(S, login, #{user => U}) of
        ok_logged_in -> after_login(U, S);
        {error, Why} -> error_line(Why), S
    end;
command("login", _, _) -> throw({usage, "login <user>"});
command("logout", _, S) ->
    show(request(S, logout, #{})),
    S#{user => undefined, key => undefined};
command("create", [Sub], S) -> show(request(S, create_sub, #{sub => Sub})), S;
command("join", [Sub], S) -> show(request(S, join_sub, #{sub => Sub})), S;
command("leave", [Sub], S) -> show(request(S, leave_sub, #{sub => Sub})), S;
command(C, _, _) when C =:= "create"; C =:= "join"; C =:= "leave" ->
    throw({usage, C ++ " <subreddit>"});
command("post", [Sub, Title | Words], S) when Words =/= [] ->
    Body = join(Words),
    Params = signed(S, #{sub => Sub, title => Title, body => Body}, Sub, Title, Body),
    case request(S, post, Params) of
        {ok, #{<<"id">> := Id}} ->
            io:format("posted #~b to r/~ts~ts~n", [Id, Sub, signed_note(Params)]);
        Other -> show(Other)
    end,
    S;
command("post", _, _) -> throw({usage, "post <subreddit> \"<title>\" <body text...>"});
command("repost", [Id0, Sub], S) ->
    Id = int(Id0, "repost <post_id> <subreddit>"),
    Params0 = #{post_id => Id, sub => Sub},
    Params = case {maps:get(key, S), request(S, get_post, #{post_id => Id})} of
                 {undefined, _} -> Params0;
                 {_, {ok, #{<<"title">> := T, <<"body">> := B}}} ->
                     signed(S, Params0, Sub, T, B);
                 _ -> Params0
             end,
    case request(S, repost, Params) of
        {ok, #{<<"id">> := New}} ->
            io:format("reposted #~b to r/~ts as #~b~ts~n", [Id, Sub, New, signed_note(Params)]);
        Other -> show(Other)
    end,
    S;
command("repost", _, _) -> throw({usage, "repost <post_id> <subreddit>"});
command("comment", [Id0 | Words], S) when Words =/= [] ->
    Id = int(Id0, "comment <post_or_comment_id> <text...>"),
    case request(S, comment, #{parent_id => Id, body => join(Words)}) of
        {ok, #{<<"id">> := New}} -> io:format("comment #~b on item #~b~n", [New, Id]);
        Other -> show(Other)
    end,
    S;
command("comment", _, _) -> throw({usage, "comment <post_or_comment_id> <text...>"});
command("vote", [Id0, Dir], S) when Dir =:= <<"up">>; Dir =:= <<"down">>; Dir =:= <<"none">> ->
    Id = int(Id0, "vote <item_id> up|down|none"),
    show(request(S, vote, #{item_id => Id, direction => Dir})),
    S;
command("vote", _, _) -> throw({usage, "vote <item_id> up|down|none"});
command("feed", Args, S) ->
    {Sort, Limit} = case Args of
                        [] -> {<<"hot">>, 10};
                        [So] -> {So, 10};
                        [So, L | _] -> {So, int(L, "feed [hot|new|top] [limit]")}
                    end,
    case request(S, get_feed, #{sort => Sort, limit => Limit}) of
        {ok, []} -> io:format("(feed is empty - join some subreddits)~n");
        {ok, Posts} ->
            io:format("feed (~ts):~n", [Sort]),
            [print_post_line(P) || P <- Posts];
        Other -> show(Other)
    end,
    S;
command("show", [Id0], S) ->
    case request(S, get_post, #{post_id => int(Id0, "show <post_id>")}) of
        {ok, Post} -> print_post(Post);
        Other -> show(Other)
    end,
    S;
command("show", _, _) -> throw({usage, "show <post_id>"});
command("karma", Args, S) ->
    Params = case Args of [U | _] -> #{user => U}; [] -> #{} end,
    case request(S, get_karma, Params) of
        {ok, #{<<"post_karma">> := P, <<"comment_karma">> := C, <<"total">> := T}} ->
            io:format("karma: ~b (post ~b, comment ~b)~n", [T, P, C]);
        Other -> show(Other)
    end,
    S;
command("dm", [To | Words], S) when Words =/= [] ->
    case request(S, send_dm, #{to => To, body => join(Words)}) of
        {ok, #{<<"id">> := Id}} -> io:format("message #~b sent to ~ts~n", [Id, To]);
        Other -> show(Other)
    end,
    S;
command("dm", _, _) -> throw({usage, "dm <user> <text...>"});
command("reply", [Id0 | Words], S) when Words =/= [] ->
    Id = int(Id0, "reply <message_id> <text...>"),
    case request(S, reply_dm, #{dm_id => Id, body => join(Words)}) of
        {ok, #{<<"id">> := New}} -> io:format("reply #~b sent~n", [New]);
        Other -> show(Other)
    end,
    S;
command("reply", _, _) -> throw({usage, "reply <message_id> <text...>"});
command("inbox", Args, S) ->
    Limit = case Args of [L | _] -> int(L, "inbox [limit]"); [] -> 20 end,
    case request(S, get_dms, #{limit => Limit}) of
        {ok, Dms} -> print_dms(Dms);
        Other -> show(Other)
    end,
    S;
command("key", [U], S) ->
    case request(S, get_public_key, #{user => U}) of
        {ok, #{<<"public_key">> := Pem}} -> io:format("public key of ~ts:~n~ts", [U, Pem]);
        Other -> show(Other)
    end,
    S;
command("key", _, _) -> throw({usage, "key <user>"});
command("trace", [OnOff], S = #{conn := Conn}) ->
    On = OnOff =:= <<"on">>,
    reddit_ws_client:set_trace(Conn, On, label(S)),
    S#{trace => On};
command("trace", _, _) -> throw({usage, "trace on|off"});
command("wait", Args, S) ->
    timer:sleep(case Args of [Ms | _] -> int(Ms, "wait [ms]"); [] -> 1000 end),
    S;
command(Cmd, _, S) ->
    io:format("unknown command '~ts' - type 'help'~n", [Cmd]),
    S.

help() ->
    io:format(
      "  register <user>                      create an account (RSA-2048 key) and log in~n"
      "  login <user> | logout                start / end your live session~n"
      "  create|join|leave <subreddit>~n"
      "  post <subreddit> \"<title>\" <text>    signed text post~n"
      "  repost <post_id> <subreddit>~n"
      "  comment <post_or_comment_id> <text>  comment, or reply to a comment~n"
      "  vote <item_id> up|down|none~n"
      "  feed [hot|new|top] [limit]           posts from your subreddits~n"
      "  show <post_id>                       post with its comment tree~n"
      "  karma [user]~n"
      "  dm <user> <text> | reply <message_id> <text> | inbox [limit]~n"
      "  key <user>                           a user's public key~n"
      "  trace on|off                         print the raw WebSocket JSON frames~n"
      "  wait [ms] | quit~n").

%% ----------------------------------------------------------------- session

register_user(User, S) ->
    {Pub, Priv} = reddit_signature:generate_key_pair(),
    case request(S, register, #{user => User, public_key => Pub}) of
        ok ->
            Saved = save_key(User, Priv),
            io:format("registered ~ts with an RSA-2048 public key~ts~n",
                      [User, case Saved of
                                 ok -> [" (private key in ", key_file(User), ")"];
                                 _ -> " (private key kept in memory only)"
                             end]),
            case request(S, login, #{user => User}) of
                ok_logged_in -> after_login(User, S#{key => Priv});
                {error, Why} -> error_line(Why), S
            end;
        {error, Why} ->
            error_line(Why),
            S
    end.

after_login(User, S = #{conn := Conn}) ->
    Key = case maps:get(key, S) of
              undefined -> load_key(User);
              K -> K
          end,
    reddit_ws_client:set_trace(Conn, maps:get(trace, S), User),
    io:format("logged in as ~ts - live notifications on, posts ~ts~n",
              [User, case Key of
                         undefined -> "unsigned (no private key on this machine)";
                         _ -> "signed"
                     end]),
    S#{user => User, key => Key}.

signed(#{key := undefined}, Params, _, _, _) -> Params;
signed(#{key := Key, user := User}, Params, Sub, Title, Body) ->
    Payload = reddit_signature:payload(User, Sub, Title, Body),
    Params#{signature => reddit_signature:sign(Key, Payload)}.

signed_note(#{signature := _}) -> " (signed)";
signed_note(_) -> "".

key_file(User) -> filename:join(?KEY_DIR, binary_to_list(User) ++ ".pem").

safe_name(User) ->
    lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
                            orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $-
              end, binary_to_list(User)).

save_key(User, Priv) ->
    case safe_name(User) of
        true ->
            ok = filelib:ensure_dir(key_file(User)),
            file:write_file(key_file(User), reddit_signature:encode_private_key(Priv));
        false -> skipped
    end.

load_key(User) ->
    case safe_name(User) andalso file:read_file(key_file(User)) of
        {ok, Pem} ->
            case reddit_signature:decode_private_key(Pem) of
                {ok, Key} -> Key;
                _ -> undefined
            end;
        _ -> undefined
    end.

label(#{user := undefined}) -> <<"ws">>;
label(#{user := U}) -> U.

%% login answers {ok, #{user => U}}; map it to one atom for the callers.
request(#{conn := Conn}, login, Params) ->
    case reddit_ws_client:request(Conn, login, Params) of
        {ok, _} -> ok_logged_in;
        Other -> Other
    end;
request(#{conn := Conn}, Action, Params) ->
    reddit_ws_client:request(Conn, Action, Params).

show(ok) -> io:format("ok~n");
show({ok, Data}) -> io:format("ok ~ts~n", [reddit_json:encode(Data)]);
show({error, Why}) -> error_line(Why).

error_line(Why) when is_binary(Why) -> io:format("error: ~ts~n", [Why]);
error_line(Why) -> io:format("error: ~p~n", [Why]).

%% ---------------------------------------------------------------- printing

print_post_line(P) ->
    io:format("  #~b r/~ts  \"~ts\" by ~ts  score ~b (+~b/-~b)  ~b comments  [~ts]~ts~n",
              [g(P, id), g(P, sub), g(P, title), g(P, author), g(P, score),
               g(P, up), g(P, down), g(P, num_comments), sig(P), repost_note(P)]).

print_post(P) ->
    io:format("#~b r/~ts by ~ts  score ~b (+~b/-~b)  [~ts]~ts~n"
              "  ~ts~n  ~ts~n",
              [g(P, id), g(P, sub), g(P, author), g(P, score), g(P, up), g(P, down),
               sig(P), repost_note(P), g(P, title), g(P, body)]),
    case maps:get(<<"comments">>, P, []) of
        [] -> io:format("  (no comments)~n");
        Comments -> print_comments(Comments)
    end.

print_comments(Comments) ->
    [begin
         Indent = lists:duplicate(2 * g(C, depth) + 2, $\s),
         io:format("~s#~b ~ts (score ~b): ~ts~n",
                   [Indent, g(C, id), g(C, author), g(C, score), g(C, body)]),
         print_comments(maps:get(<<"replies">>, C, []))
     end || C <- Comments],
    ok.

print_dms([]) -> io:format("(no messages)~n");
print_dms(Dms) ->
    [io:format("  message #~b from ~ts: ~ts~ts~n",
               [g(D, id), g(D, from), g(D, body),
                case g(D, reply_to) of
                    null -> "";
                    R -> io_lib:format("  (reply to #~b)", [R])
                end]) || D <- Dms],
    ok.

print_push(Who, <<"dm">>, D) ->
    io:format("~n*** ~tsnew message #~b from ~ts (type 'inbox')~n",
              [Who, g(D, id), g(D, from)]);
print_push(Who, <<"reply">>, D) ->
    io:format("~n*** ~ts~ts replied to your item #~b (comment #~b)~n",
              [Who, g(D, from), g(D, parent), g(D, comment_id)]);
print_push(Who, <<"new_post">>, P) ->
    io:format("~n*** ~tsnew post in r/~ts by ~ts: #~b \"~ts\" [~ts]~n",
              [Who, g(P, sub), g(P, author), g(P, id), g(P, title), sig(P)]);
print_push(Who, Type, Data) ->
    io:format("~n*** ~ts~ts: ~ts~n", [Who, Type, reddit_json:encode(Data)]).

printer() ->
    receive
        {reddit_ws_push, _Conn, Type, Data} ->
            print_push(<<>>, Type, Data),
            printer();
        {reddit_ws_closed, _Conn} ->
            io:format("~nconnection closed by the server~n"),
            halt(1)
    end.

sig(P) ->
    case g(P, signature_status) of
        <<"valid">> -> <<"signature valid">>;
        <<"unsigned">> -> <<"unsigned">>;
        Other -> <<"signature ", Other/binary>>
    end.

repost_note(P) ->
    case g(P, repost_of) of
        null -> "";
        Orig -> io_lib:format("  (repost of #~b)", [Orig])
    end.

g(Map, Key) -> maps:get(atom_to_binary(Key, utf8), Map, null).

%% ------------------------------------------------------------------- input

b(Chars) -> unicode:characters_to_binary(Chars).

join(Words) -> iolist_to_binary(lists:join(<<" ">>, Words)).

int(Bin, Usage) ->
    try binary_to_integer(Bin)
    catch error:badarg -> throw({usage, Usage})
    end.

%% Split on blanks; "double quotes" group words into one argument. A
%% leading byte-order mark (Windows PowerShell adds one to piped input) is
%% dropped.
tokens([16#FEFF | Line]) -> tokens(Line);
tokens(Line) -> tokens(Line, [], []).

tokens([], Cur, Acc) -> lists:reverse(push(Cur, Acc));
tokens([$" | Rest], Cur, Acc) ->
    {Quoted, Rest1} = quoted(Rest, []),
    tokens(Rest1, [], [Quoted | push(Cur, Acc)]);
tokens([C | Rest], Cur, Acc) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    tokens(Rest, [], push(Cur, Acc));
tokens([C | Rest], Cur, Acc) ->
    tokens(Rest, [C | Cur], Acc).

push([], Acc) -> Acc;
push(Cur, Acc) -> [lists:reverse(Cur) | Acc].

quoted([], Acc) -> {lists:reverse(Acc), []};
quoted([$" | Rest], Acc) -> {lists:reverse(Acc), Rest};
quoted([C | Rest], Acc) -> quoted(Rest, [C | Acc]).
