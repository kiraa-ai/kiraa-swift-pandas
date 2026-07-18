#!/usr/bin/env bash
# Test daemon-mode groupby: start server, load CSV, aggregate, show, stop.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve binary
if command -v swiftpandas >/dev/null 2>&1; then
    SP="$(command -v swiftpandas)"
elif [ -x "$ROOT_DIR/.build/release/swiftpandas" ]; then
    SP="$ROOT_DIR/.build/release/swiftpandas"
else
    echo "Building swiftpandas (first time only)…"
    (cd "$ROOT_DIR" && swift build -c release)
    SP="$ROOT_DIR/.build/release/swiftpandas"
fi

SALES_CSV="$ROOT_DIR/examples/data/sales.csv"
export SWIFTPANDAS_RUNTIME_DIR="${SWIFTPANDAS_RUNTIME_DIR:-/tmp/swiftpandas-test}"

trap '"$SP" server stop >/dev/null 2>&1 || true' EXIT

echo "==> server start"
"$SP" server start

echo "==> load $SALES_CSV as 'sales'"
"$SP" load "$SALES_CSV" --name sales

echo "==> pipe: groupby(region) | agg(mean:revenue, mean:cost, mean:margin, mean:transactions)"
"$SP" pipe --from sales --name result \
  -c 'groupby(region) | agg(mean:revenue, mean:cost, mean:margin, mean:transactions)'

echo "==> show result"
"$SP" show result

echo "==> server stop"
"$SP" server stop
trap - EXIT
