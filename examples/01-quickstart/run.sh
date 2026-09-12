#!/usr/bin/env bash
# ============================================================================
# 01-quickstart — the fastest possible SwiftPandas job
#
# One command: read a CSV, run a multi-stage pipeline, write a CSV. The whole
# process boots, does the work, and exits — no server, no interpreter warm-up.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/common.sh

SP="$(find_swiftpandas)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

hr; say "Generate a 2,000-row sample sales dataset"; hr
gen_sales_csv "$WORK/sales.csv" 2000
note "wrote $(wc -l < "$WORK/sales.csv" | tr -d ' ') lines to sales.csv"
echo

hr; say "One-shot pipeline: profit per region, best first"; hr
# Read the pipeline left to right as a data flow:
#   derive   add a computed profit column (revenue - cost)
#   groupby  collapse to one row per region ...
#   agg      ... summing profit and averaging units
#   sort     rank regions by total profit, descending
#   round    tidy the averaged column for presentation
# Aggregated columns keep their source name — agg(sum:profit) yields a column
# still called "profit" — so later stages reference "profit" and "units".
timeit "$SP" run \
    -i "$WORK/sales.csv" \
    -o "$WORK/by_region.csv" \
    -c "derive(profit = revenue - cost) | groupby(region) | agg(sum:profit, mean:units) | sort(profit, desc) | round(units, 1)"
echo
note "output:"
column -s, -t < "$WORK/by_region.csv" | sed 's/^/    /'
echo

hr; say "Why this matters"; hr
note "That entire job — process start, CSV parse, 5-stage pipeline, CSV write,"
note "process exit — is what you just timed above. There is no daemon to keep"
note "running and nothing to import. Drop it in a Makefile or a cron job and it"
note "costs milliseconds each time."
echo
say "Done."
