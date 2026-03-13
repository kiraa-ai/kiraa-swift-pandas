#!/bin/bash
# 02 — Filter + sort + head: top 3 active rows by revenue
# Usage: ./02_filter_sort_head.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Top 3 active rows by revenue (descending) ==="
swift run swiftpandas -i "$CSV" \
  -c 'filter(status == "active") | sort(revenue, desc) | head(3)'
