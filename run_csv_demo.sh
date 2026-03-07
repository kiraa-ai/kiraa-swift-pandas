#!/bin/bash
# SwiftPandas — full test suite runner with results for all stages
# Usage: ./run_csv_demo.sh
# Exports all test results grouped by stage: Core, Features, Metal GPU, API Docs, Benchmarks

set -e

DIVIDER="════════════════════════════════════════════════════════════════════════════════"
THIN="────────────────────────────────────────────────────────────────────────────────"

echo "$DIVIDER"
echo "  SwiftPandas — Complete Test Suite"
echo "$DIVIDER"
echo ""

echo "Building SwiftPandas..."
swift build 2>&1 | tail -1
echo ""

# Helper: run a filter, show pass/fail per test, return pass/fail counts
run_stage() {
    local stage_name="$1"
    local filter="$2"

    echo "$DIVIDER"
    echo "  Stage: $stage_name"
    echo "$THIN"

    local output
    output=$(swift test --filter "$filter" 2>&1) || true

    # Show individual test results (strip any interleaved print output before "Test Case")
    echo "$output" | grep -E "Test Case.*passed|Test Case.*failed" | \
        sed "s/.*Test Case/Test Case/" | \
        sed "s/Test Case '-\[SwiftPandasTests\.\([^]]*\)\]' passed.*/  ✅  \1/" | \
        sed "s/Test Case '-\[SwiftPandasTests\.\([^]]*\)\]' failed.*/  ❌  \1/"

    # Show summary line
    local summary
    summary=$(echo "$output" | grep "Executed" | tail -1 | sed 's/^[[:space:]]*//')
    echo "$THIN"
    echo "  $summary"
    echo ""
}

# ── Stage 1: Core Types ──
run_stage "Core Types (DType, NativeArray, BitVector, NullableArray, StringArray, Column, Index)" \
    "DTypeTests|NativeArrayTests|BitVectorTests|NullableArrayTests|StringArrayTests|ColumnTests|IndexTests"

# ── Stage 2: Series ──
run_stage "Series (creation, aggregation, comparison, apply/map, arithmetic, statistics)" \
    "SeriesTests|SeriesComparisonTests|SeriesApplyMapTests|SeriesScalarArithmeticTests|SeriesStatisticsTests"

# ── Stage 3: DataFrame Core ──
run_stage "DataFrame Core (construction, filtering, sorting, loc, mask, duplicated)" \
    "SwiftPandasTests\.DataFrameTests|DataFrameLocTests|DataFrameMaskSubscriptTests|DuplicatedTests|MultiColumnSortTests"

# ── Stage 4: GroupBy & Merge (CPU) ──
run_stage "GroupBy & Merge — CPU (groupby, merge, concat, multi-column groupby)" \
    "SwiftPandasTests\.GroupByTests|SwiftPandasTests\.MergeTests|SwiftPandasTests\.ConcatTests|MultiColumnGroupByTests"

# ── Stage 5: Metal GPU Acceleration ──
run_stage "Metal GPU Acceleration (dispatch, GPU GroupBy, GPU Merge)" \
    "MetalDispatchTests|MetalGroupByTests|MetalMergeTests"

# ── Stage 6: CSV I/O & API Documentation ──
run_stage "CSV I/O & API Documentation" \
    "CSVDataFrameTests"

# Show pretty API documentation output
echo "$DIVIDER"
echo "  API Documentation Output"
echo "$THIN"
OUTPUT=$(swift test --filter CSVDataFrameTests 2>&1)
echo "$OUTPUT" | sed 's/Test Case.*//g' | grep -vE "(^Building|^Build complete|^\[|^Test Suite|^	|^◇|^↳|^✔|^$)"
echo ""

# ── Stage 7: Pandas-Style Workflow ──
run_stage "Pandas-Style Workflow (end-to-end integration)" \
    "PandasStyleWorkflowTests"

# ── Stage 8: Performance Benchmarks ──
echo "$DIVIDER"
echo "  Stage: Performance Benchmarks"
echo "$THIN"
BENCH=$(swift test --filter BenchmarkTests 2>&1)
# Show benchmark output (formatted tables)
echo "$BENCH" | sed 's/Test Case.*//g' | grep -vE "(^Building|^Build complete|^\[|^Test Suite|^	|^◇|^↳|^✔|^$)"
# Show test summary
BENCH_SUMMARY=$(echo "$BENCH" | grep "Executed" | tail -1 | sed 's/^[[:space:]]*//')
echo "$THIN"
echo "  $BENCH_SUMMARY"
echo ""

# ── Final Summary ──
echo "$DIVIDER"
echo "  Full Suite Summary"
echo "$THIN"
ALL=$(swift test 2>&1) || true
TOTAL=$(echo "$ALL" | grep "Executed" | tail -1 | sed 's/^[[:space:]]*//')
echo "  $TOTAL"

# Count passes and failures from individual lines
PASS_COUNT=$(echo "$ALL" | grep -c "passed" || true)
FAIL_COUNT=$(echo "$ALL" | grep -c "failed" || true)

echo ""
echo "  Stages:"
echo "    1. Core Types          — DType, NativeArray, BitVector, NullableArray, StringArray, Column, Index"
echo "    2. Series              — Creation, aggregation, comparison, apply/map, arithmetic, statistics"
echo "    3. DataFrame Core      — Construction, filtering, sorting, loc, mask, duplicated"
echo "    4. GroupBy & Merge     — CPU path: groupby, merge, concat, multi-column"
echo "    5. Metal GPU           — Dispatch, GPU GroupBy (sum/mean/count/min/max), GPU Merge (inner join)"
echo "    6. CSV I/O & Docs      — CSV parsing, API documentation examples"
echo "    7. Workflow            — End-to-end pandas-style integration"
echo "    8. Benchmarks          — Performance comparison: SwiftPandas vs Python pandas"
echo ""
echo "$DIVIDER"
echo "  Done."
echo "$DIVIDER"
