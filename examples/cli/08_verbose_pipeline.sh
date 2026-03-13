#!/bin/bash
# 08 — Verbose mode: show row counts after each transform stage
# Usage: ./08_verbose_pipeline.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"
OUT="/tmp/swiftpandas_verbose_out.csv"

echo "=== Verbose pipeline (stage-by-stage row counts on stderr) ==="
swift run swiftpandas -i "$CSV" -o "$OUT" --verbose \
  -c 'filter(status == "active") | filter(revenue > 10000) | sort(revenue, desc) | head(3)'

echo ""
echo "=== Output CSV ==="
cat "$OUT"
rm -f "$OUT"
