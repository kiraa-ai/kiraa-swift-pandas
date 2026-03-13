#!/bin/bash
# 06 — JSON file pipeline: run transforms defined in a .json file
# Usage: ./06_json_pipeline.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"
JSON="$SCRIPT_DIR/../data/transforms.json"

echo "=== Running pipeline from transforms.json ==="
swift run swiftpandas -i "$CSV" -f "$JSON"
