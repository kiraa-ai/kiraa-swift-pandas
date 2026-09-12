#!/usr/bin/env bash
# ============================================================================
# 02-resident-session — load once, analyze many times, then shut down
#
# Demonstrates the daemon workflow: a background process holds the DataFrame in
# memory, so every subsequent pipeline is a sub-15ms round trip instead of a
# fresh CSV parse. This is the "interactive session" pattern — the moral
# equivalent of a warm notebook kernel, but as plain shell commands.
#
# The whole session runs on a private socket in a temp dir and is torn down on
# exit, so it never touches any other swiftpandas daemon you may have running.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/common.sh

SP="$(find_swiftpandas)"
WORK="$(mktemp -d)"
SOCK="$WORK/session.sock"
# Always stop the daemon and clean up, even on error.
cleanup() { "$SP" server stop --socket "$SOCK" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

# Convenience wrapper so every client call targets our private socket.
sp() { "$SP" "$@" --socket "$SOCK"; }

hr; say "Prepare data (25,000 rows)"; hr
gen_sales_csv "$WORK/sales.csv" 25000
note "wrote $(wc -l < "$WORK/sales.csv" | tr -d ' ') lines"
echo

hr; say "1. Start the resident daemon"; hr
timeit "$SP" server start --socket "$SOCK" >/dev/null
note "the daemon now owns an isolated, in-memory dataframe registry"
echo

hr; say "2. Load the CSV once — this is the only parse that happens"; hr
timeit sp load "$WORK/sales.csv" --name sales
echo

hr; say "3. Run several pipelines against the hot data"; hr
note "each of these reuses the already-parsed 'sales' frame in memory"
timeit sp pipe --from sales --name profitable \
    -c "derive(profit = revenue - cost) | filter(profit > 20000) | sort(profit, desc)"
timeit sp pipe --from sales --name by_channel \
    -c "groupby(channel) | agg(sum:revenue, mean:units) | round(units, 1)"
timeit sp pipe --from sales --name west_widgets \
    -c "filter(region == West) | filter(product == Widget) | groupby(product) | agg(count:units, sum:revenue)"
echo

hr; say "4. Inspect what's resident"; hr
sp list
echo

hr; say "5. Peek at a derived frame (top 5 rows)"; hr
sp show profitable --head 5 | column -s, -t | sed 's/^/    /'
echo

hr; say "6. Save a deliverable to disk"; hr
timeit sp save by_channel "$WORK/by_channel.csv"
column -s, -t < "$WORK/by_channel.csv" | sed 's/^/    /'
echo

hr; say "7. Shut the session down"; hr
timeit "$SP" server stop --socket "$SOCK"
echo

hr; say "Why this matters"; hr
note "Step 2 (the parse) happened once. Steps 3–6 each paid only the cost of a"
note "round trip to a process that already had the data in memory — no re-read,"
note "no re-parse. That's the difference between 'run a script' and 'hold a"
note "session': you keep the data hot and iterate at conversational speed."
echo
say "Done."
