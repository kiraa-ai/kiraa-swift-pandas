#!/bin/bash
# 01 — Basic filter: keep rows where revenue > 10000
# Usage: ./01_basic_filter.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Filter: revenue > 10000 ==="
swift run swiftpandas -i "$CSV" -c "filter(revenue > 10000)"
