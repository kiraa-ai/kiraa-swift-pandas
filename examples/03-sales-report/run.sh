#!/usr/bin/env bash
# ============================================================================
# 03-sales-report — a realistic batch analytics deliverable
#
# Produces three CSV report sections from one raw sales extract, each a single
# narrated pipeline. This is what a nightly "build the numbers" job looks like:
# no session, no notebook — just deterministic commands that emit artifacts.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"
. ../lib/common.sh

SP="$(find_swiftpandas)"
WORK="$(mktemp -d)"
OUT="./out"
mkdir -p "$OUT"
trap 'rm -rf "$WORK"' EXIT

hr; say "Generate a 50,000-row raw sales extract"; hr
gen_sales_csv "$WORK/raw.csv" 50000
note "wrote $(wc -l < "$WORK/raw.csv" | tr -d ' ') lines"
echo

hr; say "Section A — margin leaderboard by region + product"; hr
# derive two columns, aggregate, and rank. margin_pct is profit as a share of
# revenue, averaged within each region/product bucket.
timeit "$SP" run -i "$WORK/raw.csv" -o "$OUT/a_margin_leaderboard.csv" -c "\
derive(profit = revenue - cost) | \
derive(margin_pct = profit / revenue) | \
groupby(region, product) | \
agg(sum:profit, mean:margin_pct, sum:units) | \
sort(profit, desc) | \
round(margin_pct, 3)"
column -s, -t < "$OUT/a_margin_leaderboard.csv" | head -6 | sed 's/^/    /'
echo

hr; say "Section B — channel performance summary"; hr
# One aggregation per source column: aggregating the same column twice would
# collide on the output name (aggregates keep their source column's name).
timeit "$SP" run -i "$WORK/raw.csv" -o "$OUT/b_channel_summary.csv" -c "\
derive(profit = revenue - cost) | \
groupby(channel) | \
agg(sum:revenue, sum:profit, mean:units) | \
sort(profit, desc) | \
round(units, 1)"
column -s, -t < "$OUT/b_channel_summary.csv" | sed 's/^/    /'
echo

hr; say "Section C — top 10 single transactions"; hr
timeit "$SP" run -i "$WORK/raw.csv" -o "$OUT/c_top_transactions.csv" -c "\
derive(profit = revenue - cost) | \
select(date, region, product, channel, revenue, profit) | \
sort(profit, desc) | \
head(10)"
column -s, -t < "$OUT/c_top_transactions.csv" | sed 's/^/    /'
echo

hr; say "Report written"; hr
note "artifacts in $(cd "$OUT" && pwd):"
for f in "$OUT"/*.csv; do note "  $(basename "$f")  ($(wc -l < "$f" | tr -d ' ') rows)"; done
echo
note "Three multi-stage reports over 50,000 rows, each a self-contained process."
note "A scheduler can run this file directly; there is no state to manage."
echo
say "Done."
