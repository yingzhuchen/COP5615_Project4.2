#!/usr/bin/env bash
# Runs the experiment sweep used in REPORT.md. Each run writes its full
# report to results/. Takes roughly 10 minutes.
set -e
cd "$(dirname "$0")"
./run.sh build

run() { echo "=== $*"; ./run.sh sim duration 30 "$@" | grep -E "client requests|^ALL|fitted"; }

# 1. scale the number of users (realistic load: one action per user per second)
for u in 1000 5000 10000 25000 50000; do run users $u clients 4; done

# 2. vary the number of client processes at 10k users
for c in 1 2 8; do run users 10000 clients $c; done

# 3. saturation: users act every 10 ms on average
run users 10000 clients 4 think_ms 10

# 4. push every new post to the online members of its subreddit
run users 10000 clients 4 push_posts true

# 5. steeper popularity curve
run users 10000 clients 4 zipf_s 1.5
