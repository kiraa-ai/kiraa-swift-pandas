#!/bin/bash
# 09 — Write to file: full pipeline with CSV output
# Usage: ./09_write_output.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"
OUT="/tmp/swiftpandas_output.csv"

echo "=== Full pipeline → output CSV ==="
swift run swiftpandas -i "$CSV" -o "$OUT" \
  -c 'filter(status == "active") | groupby(region, quarter) | agg(sum:revenue, mean:margin) | sort(revenue, desc) | rename(revenue -> total_revenue) | round(margin, 2)'

echo "Wrote: $OUT"
echo ""
echo "=== Contents ==="
cat "$OUT"
rm -f "$OUT"
