#!/bin/bash
# 10 — Error handling: demonstrate descriptive error messages
# Usage: ./10_error_handling.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Error Test 1: Unknown column ==="
swift run swiftpandas -i "$CSV" -c "filter(nonexistent > 0)" 2>&1 || true
echo ""

echo "=== Error Test 2: Unknown operation ==="
swift run swiftpandas -i "$CSV" -c "explode(col)" 2>&1 || true
echo ""

echo "=== Error Test 3: agg without groupby ==="
swift run swiftpandas -i "$CSV" -c "agg(sum:revenue)" 2>&1 || true
echo ""

echo "=== Error Test 4: File not found ==="
swift run swiftpandas -i "nonexistent.csv" -c "head(1)" 2>&1 || true
echo ""

echo "=== Error Test 5: Invalid JSON transform file ==="
echo "not json" > /tmp/bad_transform.json
swift run swiftpandas -i "$CSV" -f /tmp/bad_transform.json 2>&1 || true
rm -f /tmp/bad_transform.json
echo ""

echo "=== Help: --help-ops ==="
swift run swiftpandas --help-ops -i "$CSV" 2>&1 | head -20
