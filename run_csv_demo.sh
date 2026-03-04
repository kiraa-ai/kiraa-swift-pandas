#!/bin/bash
# SwiftPandas — comprehensive API documentation & test runner
# Usage: ./run_csv_demo.sh

set -e

echo "Building SwiftPandas..."
swift build 2>&1 | tail -1
echo ""

# Run documentation tests (pretty output)
OUTPUT=$(swift test --filter CSVDataFrameTests 2>&1)
echo "$OUTPUT" | sed 's/Test Case.*//g' | grep -vE "(^Building|^Build complete|^\[|^Test Suite|^	|^◇|^↳|^✔|^$)"

# Run all tests and show summary
ALL=$(swift test 2>&1)
echo ""
echo "$ALL" | grep "Executed" | tail -1
echo ""
echo "Done."
