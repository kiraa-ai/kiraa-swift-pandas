#!/bin/bash
# 04 — Derive: add a computed "profit" column, then filter
# Usage: ./04_derive_computed_column.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Derive profit (revenue - cost), keep profit > 10000 ==="
swift run swiftpandas -i "$CSV" \
  -c 'derive(profit = revenue - cost) | filter(profit > 10000) | select(region, sku, revenue, cost, profit) | sort(profit, desc)'
