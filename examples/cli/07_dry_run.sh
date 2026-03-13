#!/bin/bash
# 07 — Dry run: validate pipeline without writing output
# Usage: ./07_dry_run.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CSV="$SCRIPT_DIR/../data/sales.csv"

echo "=== Dry run: show schema + parsed transform chain ==="
swift run swiftpandas -i "$CSV" --dry-run \
  -c 'filter(status == "active") | filter(revenue > 10000) | groupby(region) | agg(sum:revenue)'
