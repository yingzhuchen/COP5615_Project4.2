# COP5615_Project4.2
Team members:
- Qing Li (16912349)
- Yingzhu Chen (83945095)

A Reddit clone engine, simulator, REST server, and REST client written in
Erlang/OTP. Performance results from the engine simulator are in
[REPORT.md](REPORT.md).

## What is implemented

**Engine** (one Erlang VM / OS process):

| Feature | Request |
|---|---|
| Register account | `{register, User}` |
| Create, join, leave subreddit | `{create_sub, U, Sub}`, `{join_sub, U, Sub}`, `{leave_sub, U, Sub}` |
| Text posts and reposts | `{post, U, Sub, Title, Body}`, `{repost, U, Sub, PostId}` |
| Hierarchical comments (comment on a post or on a comment, any depth) | `{comment, U, ParentId, Body}` |
| Upvote / downvote / withdraw, karma | `{vote, U, ItemId, up \| down \| none}`, `{get_karma, U}` |
| Feed of posts from joined subreddits (`hot`, `new`, `top`) | `{get_feed, U, Limit, Sort}` |
| A post with its full comment tree | `{get_post, U, PostId}` |
| Direct messages: list, send, reply | `{get_dms, U, Limit}`, `{send_dm, U, To, Body}`, `{reply_dm, U, DmId, Body}` |
| Live connection | `{connect, U, Pid}`, `{disconnect, U}` |

Connected users get live pushes: a new direct message, a reply to one of their
posts or comments, and (with `push_posts true`) every new post in their
subreddits. Offline users catch up through their feed and inbox when they
reconnect.

**Simulator**: several independent client OS processes (Erlang nodes). Each
one runs thousands of simulated users, one Erlang process per user.

- Users alternate between online and offline periods of exponentially
  distributed length. While online they act about once per `think_ms`. The
  mix of actions is feed, vote, comment, post, view post, DM, inbox, karma,
  and join/leave.
- Subreddit membership follows a Zipf distribution. Each user joins 1–5 subs
  drawn with P(rank k) ∝ 1/k^s.
- Popular subreddits get more posts. A user posts to one of their subs
  chosen with weight 1/k^s, so post counts grow faster than member counts
  (see the Zipf table in the report).
- A share of posts (`repost`, default 10%) are reposts of posts the user has
  seen. Reposts keep a link to the original.
- Every request is timed on the client. The engine also records its own
  service time. One report combines both.

## Layout

```
src/reddit_store.erl    ETS tables holding all engine state
src/reddit_ops.erl      engine logic (pure request -> reply over ETS)
src/reddit_engine.erl   engine worker pool, routing, live pushes
src/reddit_client.erl   client-side API to a remote engine
src/reddit_user.erl     one simulated user
src/reddit_sim.erl      client process driver (one per client OS process)
src/reddit_main.erl     entry point: starts engine, spawns/coordinates clients
src/reddit_report.erl   performance report
src/reddit_zipf.erl     Zipf sampler
src/reddit_stats.erl    mergeable latency histograms
test/reddit_tests.erl   engine unit tests
src/reddit_http.erl     dependency-free REST server
src/reddit_json.erl     JSON response encoder
src/reddit_rest_client.erl REST client
src/reddit_rest_demo.erl REST demo client
src/reddit_ws.erl        WebSocket server (handshake, framing, JSON commands, live pushes)
src/reddit_ws_client.erl WebSocket client library
src/reddit_ws_cli.erl    interactive command-line WebSocket client
src/reddit_ws_demo.erl   scripted multi-client WebSocket demo
```

### Design

- **Engine state** lives in public ETS tables. Integrity comes from atomic
  ETS operations (`insert_new`, `take`, `update_counter`), not from a single
  process. So the engine has no global lock and no single mailbox bottleneck.
- **Engine workers**: a pool of gen_servers (2 × schedulers). A client sends
  each request to the worker chosen by `phash2(UserName)`. One user's
  requests stay in order, and different users run in parallel.
- **Separate processes**: the engine and each client are separate Erlang VMs
  talking over Erlang distribution. `sim` mode starts the client VMs with
  OTP's `peer` module. `engine` + `client` mode lets you start them by hand,
  on other machines too.
- **Push fan-out** for new posts is batched: one message per client node,
  forwarded locally by that node's `reddit_relay` process.
- `reddit_ops` knows nothing about processes or transport. The REST layer
  calls the same engine workers without changing the engine logic.

## How to run

Requires Erlang/OTP 25 or newer (developed on OTP 29). No other dependencies.

Windows (PowerShell):

```powershell
.\run.ps1 test                                   # engine unit tests
.\run.ps1 sim                                    # default: 5000 users, 4 clients, 30 s
.\run.ps1 sim users 20000 clients 4 duration 60  # any options, key value pairs
```

Linux / macOS / Git Bash:

```bash
./run.sh test
./run.sh sim users 20000 clients 4 duration 60
./bench.sh            # the full experiment sweep used in REPORT.md
```

The report is printed and also saved to `results/run_<users>u_<clients>c_<secs>s_<time>.txt`.

## Project 4.2 REST API

Project 4.2 adds a dependency-free HTTP/REST layer on top of the same engine.
The API uses `application/x-www-form-urlencoded` request bodies and returns
JSON responses. Start it with:

```bash
./run.sh api 8080
```

In another terminal, run the REST client demonstration:

```bash
./run.sh demo http://localhost:8080
```

Supported endpoints:

| Method | Endpoint | Purpose |
|---|---|---|
| POST | `/api/users` | Register a user (`user`) |
| POST | `/api/subreddits/create` | Create a subreddit (`user`, `sub`) |
| POST | `/api/subreddits/join` | Join a subreddit |
| POST | `/api/subreddits/leave` | Leave a subreddit |
| POST | `/api/posts` | Create a text post |
| POST | `/api/reposts` | Repost a post |
| POST | `/api/comments` | Add a comment or reply |
| POST | `/api/votes` | Upvote, downvote, or withdraw |
| GET | `/api/feed?user=...&limit=...&sort=...` | Get a feed |
| GET | `/api/posts/<id>` | Get a post and comment tree |
| GET | `/api/karma?user=...` | Get Karma |
| POST | `/api/messages` | Send a direct message |
| POST | `/api/messages/reply` | Reply to a direct message |
| GET | `/api/messages?user=...` | List direct messages |
| GET | `/api/users/<user>/public_key` | Get a user's PEM RSA public key |
| GET | `/api/search?q=...&limit=...` | Search all posts: every word must appear in the title or body (case-insensitive), newest first |
| GET | `/api/subreddits?q=...` | List subreddits (all, or those whose name contains every word), largest first |

**Server log.** The server prints one line per REST request, WebSocket
message and live push, so the communication can be followed as it happens
(`./run.sh api 8080 log false` turns this off):

```
[12:03:41.512] REST POST /api/posts user=carol sub=cop5615 title=Hello +signature +body -> 200 id=5 (1.2 ms)
[12:03:41.530] REST GET  /api/search q=hello limit=10 -> 200 (2 items) (0.8 ms)
[12:03:42.101] WS   dave: comment parent_id=5 +body -> ok id=6 (0.4 ms)
[12:03:42.102] WS   push reply -> carol comment #6 from dave
```

Bonus registration and posting parameters:

- `POST /api/users`: optional `public_key` PEM parameter
- `POST /api/posts`: optional base64 `signature` parameter
- `POST /api/reposts`: optional base64 `signature` parameter

The REST server calls the existing engine workers, so the engine remains
separate from the client and transport layer. `src/reddit_rest_client.erl`
is the simple client used by the demo and logs each REST operation.

**Interactive REST client.** The interactive client (below) also runs over
REST: every command becomes one or more HTTP requests, each printed as it
is sent. REST has no live notifications, so use `feed` and `inbox` to see
new items.

```bash
./run.sh rest http://localhost:8080             # then: register carol
./run.sh rest http://localhost:8080 dave        # log in, or register if new
```

```
carol> search hello
  [REST] GET /api/search?limit=10&q=hello -> 200 [{"id":1,"up":0,"down":0,"sub":"cop5615","signature":"Uq7qhp... (1.5 ms)
1 post(s) match 'hello', newest first:
  #1 r/cop5615  "Hello" by carol  score 0 (+0/-0)  0 comments  [signature valid]
```

## Project 4.2 WebSocket interface

The same server also speaks WebSocket (RFC 6455) at `ws://HOST:PORT/ws`,
implemented without dependencies on `gen_tcp`. A client sends one JSON
command per text frame and gets one JSON reply with the same `ref`:

```
-> {"ref": 4, "action": "post", "sub": "erlang", "title": "Hi", "body": "...", "signature": "..."}
<- {"ref": 4, "ok": true, "data": {"id": 12}}
-> {"ref": 5, "action": "join_sub", "sub": "nope"}
<- {"ref": 5, "ok": false, "error": "no_such_sub"}
```

After `login`, the connection is that user's live session: the engine pushes
events to it at any time, with no request needed. Offline users catch up
through `get_feed` and `get_dms` when they log in again.

```
<- {"push": "new_post", "data": {...post...}}            new post in a joined subreddit
<- {"push": "reply", "data": {"comment_id": 9, "parent": 5, "from": "bob"}}
<- {"push": "dm", "data": {"id": 3, "from": "bob"}}
```

| Action | Fields | Needs login |
|---|---|---|
| `register` | `user`, optional `public_key` (PEM) | no |
| `login` / `logout` | `user` / – | no |
| `get_post` | `post_id` (post with its comment tree and `signature_status`) | no |
| `get_public_key` | `user` | no |
| `search` | `q`, optional `limit` (posts matching every word) | no |
| `list_subs` | optional `q` (subreddits whose name matches) | no |
| `create_sub`, `join_sub`, `leave_sub` | `sub` | yes |
| `post` | `sub`, `title`, `body`, optional `signature` | yes |
| `repost` | `sub`, `post_id`, optional `signature` | yes |
| `comment` | `parent_id` (post or comment), `body` | yes |
| `vote` | `item_id`, `direction` (`up`, `down`, `none`) | yes |
| `get_feed` | optional `sort` (`hot`, `new`, `top`), `limit` | yes |
| `get_karma` | optional `user` (default: yourself) | yes |
| `send_dm`, `reply_dm`, `get_dms` | `to`, `body` / `dm_id`, `body` / optional `limit` | yes |

Start the server (REST and WebSocket on one port; new-post pushes are on
by default, `push_posts false` turns them off):

```bash
./run.sh api 8080
```

**Interactive client.** Run it in several terminals; each one is a separate
client OS process. Create an account with `register <user>`, or pass a user
name on the command line to log in (registering first if the user is new).
Registering creates an RSA-2048 key pair, uploads the public key and saves
the private key in `keys/<user>.pem`, so later posts are signed. `subs`
lists subreddits and `search <words>` searches all posts. Type `help` for
the commands and `trace on` to see the raw JSON frames.

```bash
./run.sh ws ws://localhost:8080/ws alice     # terminal 2
./run.sh ws ws://localhost:8080/ws bob       # terminal 3
```

```
alice> create erlang
bob> join erlang
alice> post erlang "Hello" first post over WebSocket
bob>                                     <- arrives in bob's terminal at once:
*** new post in r/erlang by alice: #1 "Hello" [signature valid]
bob> comment 1 nice post
bob> dm alice hi there
bob> feed new
bob> show 1
```

**Scripted demo.** Three users on three connections use every action. Each
live push is checked, error cases are shown, and the JSON frames are
printed. It exits with status 0 when everything worked.

```bash
./run.sh wsdemo ws://localhost:8080/ws
```

On Windows PowerShell use `.\run.ps1 api 8080`, `.\run.ps1 ws ...`,
`.\run.ps1 rest ...` and `.\run.ps1 wsdemo ...`. If PowerShell reports that running scripts is
disabled, use Git Bash with `./run.sh`, or start the script with
`powershell -ExecutionPolicy Bypass -File .\run.ps1 ...`.

## Bonus: signed posts

Status: implemented.

Implemented functionality:

- Users provide an RSA-2048 or 256-bit Elliptic Curve public key during
  registration.
- The server exposes an endpoint for retrieving another user's public key.
- Text posts include a signature generated by the posting user's private key.
- When a post is downloaded through the REST API, the server verifies the
  signature with a standard cryptography library before returning it.
- Each post response includes `signature_status`: `valid`, `invalid`,
  `missing_public_key`, or `unsigned`.
- RSA key generation, signing, verification, and PEM public-key handling use
  Erlang/OTP's standard `public_key` and `crypto` libraries.
- A separate `project4-bonus.zip/tgz` submission contains the bonus code.

### Clients started by hand (or on other machines)

```bash
./run.sh engine clients 2 users 10000     # terminal 1: prints engine@HOST, waits
./run.sh client engine@HOST               # terminal 2
./run.sh client engine@HOST               # terminal 3
```

Every node must use the same cookie (`COOKIE` environment variable, default
`reddit`). The scripts use short names (`-sname`). Across machines with
different domains, change them to `-name` with full host names.

### Options

| Option | Default | Meaning |
|---|---|---|
| `users` | 5000 | simulated users in total |
| `clients` | 4 | client OS processes |
| `subs` | 100 | number of subreddits (Zipf ranks) |
| `zipf_s` | 1.0 | Zipf exponent |
| `subs_per_user` | 3 | average subs joined per user (1 .. 2n-1) |
| `duration` | 30 | seconds of simulated activity |
| `think_ms` | 1000 | mean time between actions of an online user |
| `online_ms` / `offline_ms` | 20000 / 10000 | mean length of online / offline periods |
| `stagger_ms` | 3000 | users that start online log in within this window |
| `repost` | 0.1 | share of posts that are reposts |
| `push_posts` | false | push each new post to all online members of the sub |
| `workers` | 2 × schedulers | engine worker processes |
| `feed_limit` | 25 | posts per feed request |
| `seed` | 42 | random seed |
| `mode` | local | `local` spawns clients itself; `engine` waits for external clients |
| `out` | results | report directory |
