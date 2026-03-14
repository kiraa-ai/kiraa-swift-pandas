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

    # Show individual test results (Swift Testing format: ✔ / ✘ lines)
    echo "$output" | grep -E "^✔ Test [^r]|^✘ Test " | \
        sed 's/^✔ Test \(.*\)() passed.*/  ✅  \1/' | \
        sed 's/^✘ Test \(.*\)() failed.*/  ❌  \1/'

    # Show summary line (Swift Testing format: "Test run with N test(s)...")
    local summary
    summary=$(echo "$output" | grep -E "^✔ Test run with|^✘ Test run with" | tail -1 | sed 's/^[✔✘] //')
    echo "$THIN"
    echo "  $summary"
    echo ""
}

# ── Stage 1: Core Types ──
run_stage "Core Types (DType, NativeArray, BitVector, NullableArray, StringArray, Column, Index)" \
    "SwiftPandasTests.DTypeTests|SwiftPandasTests.NativeArrayTests|SwiftPandasTests.BitVectorTests|SwiftPandasTests.NullableArrayTests|SwiftPandasTests.StringArrayTests|SwiftPandasTests.ColumnTests|SwiftPandasTests.IndexTests"

# ── Stage 2: Series ──
# SeriesTests contains all series subtests (comparison, apply, arithmetic, etc.)
run_stage "Series (creation, aggregation, comparison, apply/map, arithmetic, statistics)" \
    "SwiftPandasTests.SeriesTests"

# ── Stage 3: DataFrame Core ──
# DataFrameTests contains filtering, sorting, loc, mask, duplicated, concat subtests
run_stage "DataFrame Core (construction, filtering, sorting, loc, mask, duplicated, concat)" \
    "SwiftPandasTests.DataFrameTests"

# ── Stage 4: GroupBy & Merge (CPU) ──
# Use exact suite names to avoid matching BenchmarkTests (which has 1M-row GroupBy/Merge)
run_stage "GroupBy & Merge — CPU (groupby, merge, multi-column groupby)" \
    "SwiftPandasTests.GroupByTests|SwiftPandasTests.MergeTests"

# ── Stage 5: Metal GPU Acceleration ──
run_stage "Metal GPU Acceleration (dispatch, GPU GroupBy, GPU Merge)" \
    "SwiftPandasTests.MetalDispatchTests|SwiftPandasTests.MetalGroupByTests|SwiftPandasTests.MetalMergeTests"

# ── Stage 6: CSV I/O & API Documentation ──
run_stage "CSV I/O & API Documentation" \
    "SwiftPandasTests.CSVDataFrameTests"

# ── Stage 7: Pandas-Style Workflow ──
run_stage "Pandas-Style Workflow (end-to-end integration)" \
    "SwiftPandasTests.PandasStyleWorkflowTests"

# ── Stage 7b: New Features ──
run_stage "New Features (Equatable, Sequence, JSON I/O, throwing API)" \
    "SwiftPandasTests.NewFeaturesTests"

# ── Stage 7c: Lazy Evaluation ──
run_stage "Lazy Evaluation (predicates, chains, optimizer, edge cases)" \
    "SwiftPandasTests.PredicateTests|SwiftPandasTests.LazyDataFrameTests|SwiftPandasTests.LazyChainedTests|SwiftPandasTests.QueryOptimizerTests|SwiftPandasTests.ExplainTests|SwiftPandasTests.LazyEdgeCaseTests"

# ── Stage 8: CLI Tests ──
run_stage "CLI Tool (DSL parser, transforms, integration)" \
    "SwiftPandasCLITests.ParserTests|SwiftPandasCLITests.TransformTests|SwiftPandasCLITests.IntegrationTests"

# ── Stage 9: Performance Benchmarks (skipped — run separately) ──
echo "$DIVIDER"
echo "  Stage: Performance Benchmarks (SKIPPED)"
echo "$THIN"
echo "  Benchmarks operate on 1M+ rows and take several minutes."
echo "  Run separately: swift test --filter SwiftPandasTests.BenchmarkTests"
echo ""

# ── Final Summary ──
echo "$DIVIDER"
echo "  Full Suite Summary"
echo "$THIN"
echo ""
echo "  Stages:"
echo "    1. Core Types          — DType, NativeArray, BitVector, NullableArray, StringArray, Column, Index"
echo "    2. Series              — Creation, aggregation, comparison, apply/map, arithmetic, statistics"
echo "    3. DataFrame Core      — Construction, filtering, sorting, loc, mask, duplicated, concat"
echo "    4. GroupBy & Merge     — CPU path: groupby, merge, multi-column"
echo "    5. Metal GPU           — Dispatch, GPU GroupBy (sum/mean/count/min/max), GPU Merge (inner join)"
echo "    6. CSV I/O & Docs      — CSV parsing, API documentation examples"
echo "    7. Workflow            — End-to-end pandas-style integration"
echo "    7b. New Features       — Equatable, Sequence, JSON I/O, throwing API"
echo "    7c. Lazy Evaluation    — Predicates, chains, optimizer, edge cases"
echo ""
echo "  Note: Benchmark tests (1M rows) excluded from this runner."
echo "  Run benchmarks separately: swift test --filter BenchmarkTests"
echo ""
echo "$DIVIDER"
echo "  Done."
echo "$DIVIDER"
