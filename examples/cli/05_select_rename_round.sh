#!/bin/bash
# 05 — Select + rename + round: clean up column names and formatting
# Usage: ./05_select_rename_round.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Select, rename, and round margin to 1 decimal ==="
swift run swiftpandas -i "$CSV" \
  -c 'select(region, quarter, revenue, margin) | rename(revenue -> sales) | round(margin, 1)'
