#!/bin/bash
# 03 — GroupBy + Agg: summarize revenue and margins by region
# Usage: ./03_groupby_agg.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Regional summary: sum revenue, mean margin, count transactions ==="
swift run swiftpandas -i "$CSV" \
  -c 'groupby(region) | agg(sum:revenue, mean:margin, count:transactions)'
