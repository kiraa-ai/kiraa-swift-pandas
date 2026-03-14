#!/bin/bash
# ============================================================================
# SwiftPandas CLI Validation Script
# ============================================================================
# Tests every DSL operation, chained pipelines, edge cases, and output modes
# using the swiftpandas CLI tool directly. No Xcode or XCTest required.
#
# Usage: ./validate_cli.sh
# ============================================================================

set -euo pipefail

PASS=0
FAIL=0
ERRORS=()

CLI=".build/debug/swiftpandas"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

pass() {
    PASS=$((PASS + 1))
    printf "  \033[32m✔\033[0m  %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    ERRORS+=("$1: $2")
    printf "  \033[31m✘\033[0m  %s — %s\n" "$1" "$2"
}

# Run CLI, check exit code is 0, capture stdout only
run_ok() {
    local desc="$1"; shift
    local out
    if out=$($CLI "$@" 2>/dev/null); then
        echo "$out"
        return 0
    else
        fail "$desc" "exit code $?"
        echo "$out"
        return 1
    fi
}

# Assert output contains a string
assert_contains() {
    local desc="$1" output="$2" expected="$3"
    if echo "$output" | grep -qF "$expected"; then
        return 0
    else
        fail "$desc" "expected output to contain '$expected'"
        return 1
    fi
}

# Assert output does NOT contain a string
assert_not_contains() {
    local desc="$1" output="$2" unexpected="$3"
    if echo "$output" | grep -qF "$unexpected"; then
        fail "$desc" "output should not contain '$unexpected'"
        return 1
    else
        return 0
    fi
}

# Assert exact row count (excluding header)
assert_row_count() {
    local desc="$1" output="$2" expected="$3"
    local actual
    actual=$(echo "$output" | tail -n +2 | grep -c '.' || true)
    if [ "$actual" -eq "$expected" ]; then
        return 0
    else
        fail "$desc" "expected $expected rows, got $actual"
        return 1
    fi
}

# Assert header matches
assert_header() {
    local desc="$1" output="$2" expected="$3"
    local actual
    actual=$(echo "$output" | head -1)
    if [ "$actual" = "$expected" ]; then
        return 0
    else
        fail "$desc" "expected header '$expected', got '$actual'"
        return 1
    fi
}

# ── Test Data ────────────────────────────────────────────────────────────────

cat > "$TMPDIR/sales.csv" << 'CSV'
region,quarter,sku,revenue,cost,margin,transactions,status
APAC,Q1,SKU-001,15000,9000,0.4,120,active
APAC,Q1,SKU-002,8500,5950,0.3,80,active
APAC,Q2,SKU-001,18000,10800,0.4,145,active
EMEA,Q1,SKU-003,22000,15400,0.3,200,active
EMEA,Q2,SKU-003,9000,6300,0.3,90,inactive
US,Q1,SKU-004,35000,21000,0.4,310,active
US,Q2,SKU-004,41000,28700,0.3,380,active
US,Q1,SKU-005,7200,5760,0.2,65,inactive
CSV

cat > "$TMPDIR/small.csv" << 'CSV'
name,age,score
Alice,30,85.5
Bob,25,92.0
Charlie,35,78.3
Diana,28,95.1
Eve,32,88.7
CSV

cat > "$TMPDIR/transforms.json" << 'JSON'
{
  "description": "Test transform",
  "operations": [
    { "op": "filter", "args": { "column": "revenue", "operator": ">", "value": 10000 } },
    { "op": "sort", "args": { "columns": [{ "column": "revenue", "direction": "desc" }] } },
    { "op": "select", "args": { "columns": ["region", "sku", "revenue"] } }
  ]
}
JSON

# ── Build ────────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════════════════════════════════════"
echo "  SwiftPandas CLI — Validation Suite"
echo "════════════════════════════════════════════════════════════════════════"
echo ""
echo "Building..."
swift build 2>&1 | tail -1
echo ""

# ── 1. Basic Operations ─────────────────────────────────────────────────────

echo "── 1. Individual DSL Operations ──────────────────────────────────────"

# filter: numeric >
OUT=$(run_ok "filter >" -i "$TMPDIR/sales.csv" -c "filter(revenue > 20000)")
if [ $? -eq 0 ]; then
    assert_row_count "filter >" "$OUT" 3 && pass "filter(revenue > 20000) → 3 rows"
fi

# filter: numeric <
OUT=$(run_ok "filter <" -i "$TMPDIR/sales.csv" -c "filter(revenue < 10000)")
if [ $? -eq 0 ]; then
    assert_row_count "filter <" "$OUT" 3 && pass "filter(revenue < 10000) → 3 rows"
fi

# filter: numeric >=
OUT=$(run_ok "filter >=" -i "$TMPDIR/sales.csv" -c "filter(revenue >= 22000)")
if [ $? -eq 0 ]; then
    assert_row_count "filter >=" "$OUT" 3 && pass "filter(revenue >= 22000) → 3 rows"
fi

# filter: numeric <=
OUT=$(run_ok "filter <=" -i "$TMPDIR/sales.csv" -c "filter(revenue <= 9000)")
if [ $? -eq 0 ]; then
    assert_row_count "filter <=" "$OUT" 3 && pass "filter(revenue <= 9000) → 3 rows"
fi

# filter: string ==
OUT=$(run_ok "filter ==" -i "$TMPDIR/sales.csv" -c "filter(region == EMEA)")
if [ $? -eq 0 ]; then
    assert_row_count "filter ==" "$OUT" 2 && \
    assert_not_contains "filter ==" "$OUT" "APAC" && \
    assert_not_contains "filter ==" "$OUT" "US" && \
    pass "filter(region == EMEA) → 2 rows, only EMEA"
fi

# filter: string !=
OUT=$(run_ok "filter !=" -i "$TMPDIR/sales.csv" -c "filter(status != active)")
if [ $? -eq 0 ]; then
    assert_row_count "filter !=" "$OUT" 2 && pass "filter(status != active) → 2 inactive rows"
fi

# filter: contains (string value)
OUT=$(run_ok "filter contains" -i "$TMPDIR/sales.csv" -c "filter(sku contains SKU-00)")
if [ $? -eq 0 ]; then
    assert_row_count "filter contains" "$OUT" 8 && pass "filter(sku contains SKU-00) → 8 rows"
fi

# sort: ascending (default)
OUT=$(run_ok "sort asc" -i "$TMPDIR/small.csv" -c "sort(age)")
if [ $? -eq 0 ]; then
    FIRST_NAME=$(echo "$OUT" | sed -n '2p' | cut -d, -f1)
    if [ "$FIRST_NAME" = "Bob" ]; then
        pass "sort(age) ascending → Bob (25) first"
    else
        fail "sort asc" "expected Bob first, got $FIRST_NAME"
    fi
fi

# sort: descending
OUT=$(run_ok "sort desc" -i "$TMPDIR/small.csv" -c "sort(score, desc)")
if [ $? -eq 0 ]; then
    FIRST_NAME=$(echo "$OUT" | sed -n '2p' | cut -d, -f1)
    if [ "$FIRST_NAME" = "Diana" ]; then
        pass "sort(score, desc) → Diana (95.1) first"
    else
        fail "sort desc" "expected Diana first, got $FIRST_NAME"
    fi
fi

# head
OUT=$(run_ok "head" -i "$TMPDIR/sales.csv" -c "head(3)")
if [ $? -eq 0 ]; then
    assert_row_count "head" "$OUT" 3 && pass "head(3) → 3 rows"
fi

# tail
OUT=$(run_ok "tail" -i "$TMPDIR/sales.csv" -c "tail(2)")
if [ $? -eq 0 ]; then
    assert_row_count "tail" "$OUT" 2 && pass "tail(2) → 2 rows"
fi

# select
OUT=$(run_ok "select" -i "$TMPDIR/sales.csv" -c "select(region, revenue)")
if [ $? -eq 0 ]; then
    assert_header "select" "$OUT" "region,revenue" && \
    assert_row_count "select" "$OUT" 8 && \
    pass "select(region, revenue) → 2 columns, 8 rows"
fi

# drop
OUT=$(run_ok "drop" -i "$TMPDIR/sales.csv" -c "drop(sku, status, margin)")
if [ $? -eq 0 ]; then
    assert_header "drop" "$OUT" "region,quarter,revenue,cost,transactions" && \
    pass "drop(sku, status, margin) → removed 3 columns"
fi

# rename
OUT=$(run_ok "rename" -i "$TMPDIR/small.csv" -c "rename(score -> grade)")
if [ $? -eq 0 ]; then
    assert_header "rename" "$OUT" "name,age,grade" && pass "rename(score -> grade)"
fi

# derive
OUT=$(run_ok "derive" -i "$TMPDIR/sales.csv" -c "derive(profit = revenue - cost)")
if [ $? -eq 0 ]; then
    assert_contains "derive" "$OUT" "profit" && \
    # First data row: APAC SKU-001, revenue=15000, cost=9000, profit should be 6000
    PROFIT=$(echo "$OUT" | sed -n '2p' | rev | cut -d, -f1 | rev)
    if [ "$PROFIT" = "6000" ]; then
        pass "derive(profit = revenue - cost) → profit=6000 for first row"
    else
        fail "derive" "expected profit=6000, got $PROFIT"
    fi
fi

# derive: multiplication
OUT=$(run_ok "derive *" -i "$TMPDIR/sales.csv" -c "derive(double_rev = revenue * 2)")
if [ $? -eq 0 ]; then
    VAL=$(echo "$OUT" | sed -n '2p' | rev | cut -d, -f1 | rev)
    if [ "$VAL" = "30000" ]; then
        pass "derive(double_rev = revenue * 2) → 30000"
    else
        fail "derive *" "expected 30000, got $VAL"
    fi
fi

# round
OUT=$(run_ok "round" -i "$TMPDIR/sales.csv" -c "select(margin) | round(margin, 0)")
if [ $? -eq 0 ]; then
    pass "round(margin, 0) runs without error"
fi

# cast
OUT=$(run_ok "cast" -i "$TMPDIR/sales.csv" -c "cast(transactions, Int)")
if [ $? -eq 0 ]; then
    pass "cast(transactions, Int) runs without error"
fi

echo ""

# ── 2. GroupBy & Aggregation ─────────────────────────────────────────────────

echo "── 2. GroupBy & Aggregation ──────────────────────────────────────────"

# groupby + agg: sum
OUT=$(run_ok "groupby sum" -i "$TMPDIR/sales.csv" -c "groupby(region) | agg(sum:revenue)")
if [ $? -eq 0 ]; then
    assert_row_count "groupby sum" "$OUT" 3 && pass "groupby(region) | agg(sum:revenue) → 3 groups"
fi

# groupby + agg: mean
OUT=$(run_ok "groupby mean" -i "$TMPDIR/sales.csv" -c "groupby(region) | agg(mean:margin)")
if [ $? -eq 0 ]; then
    assert_row_count "groupby mean" "$OUT" 3 && pass "groupby(region) | agg(mean:margin) → 3 groups"
fi

# groupby + agg: count
OUT=$(run_ok "groupby count" -i "$TMPDIR/sales.csv" -c "groupby(status) | agg(count:revenue)")
if [ $? -eq 0 ]; then
    assert_row_count "groupby count" "$OUT" 2 && pass "groupby(status) | agg(count:revenue) → 2 groups"
fi

# groupby + agg: min
OUT=$(run_ok "groupby min" -i "$TMPDIR/sales.csv" -c "groupby(region) | agg(min:revenue)")
if [ $? -eq 0 ]; then
    assert_row_count "groupby min" "$OUT" 3 && pass "groupby(region) | agg(min:revenue) → 3 groups"
fi

# groupby + agg: max
OUT=$(run_ok "groupby max" -i "$TMPDIR/sales.csv" -c "groupby(region) | agg(max:revenue)")
if [ $? -eq 0 ]; then
    assert_row_count "groupby max" "$OUT" 3 && pass "groupby(region) | agg(max:revenue) → 3 groups"
fi

# groupby + agg: multiple aggregations
OUT=$(run_ok "groupby multi-agg" -i "$TMPDIR/sales.csv" -c "groupby(region) | agg(sum:revenue, mean:margin, count:transactions)")
if [ $? -eq 0 ]; then
    assert_row_count "groupby multi-agg" "$OUT" 3 && \
    assert_header "groupby multi-agg" "$OUT" "region,revenue,margin,transactions" && \
    pass "groupby(region) | agg(sum, mean, count) → 3 groups, 4 cols"
fi

# multi-column groupby
OUT=$(run_ok "multi-col groupby" -i "$TMPDIR/sales.csv" -c "groupby(region, quarter) | agg(sum:revenue)")
if [ $? -eq 0 ]; then
    assert_row_count "multi-col groupby" "$OUT" 6 && \
    pass "groupby(region, quarter) | agg(sum:revenue) → 6 groups"
fi

echo ""

# ── 3. Chained Pipelines ────────────────────────────────────────────────────

echo "── 3. Chained Pipelines ──────────────────────────────────────────────"

# filter + sort + head
OUT=$(run_ok "chain: filter+sort+head" -i "$TMPDIR/sales.csv" -c "filter(status == active) | sort(revenue, desc) | head(3)")
if [ $? -eq 0 ]; then
    assert_row_count "chain: filter+sort+head" "$OUT" 3 && \
    FIRST_REV=$(echo "$OUT" | sed -n '2p' | cut -d, -f4)
    if [ "$FIRST_REV" = "41000" ]; then
        pass "filter → sort desc → head(3): top revenue is 41000"
    else
        fail "chain: filter+sort+head" "expected top revenue 41000, got $FIRST_REV"
    fi
fi

# filter + derive + groupby + agg + sort
OUT=$(run_ok "chain: full pipeline" -i "$TMPDIR/sales.csv" -c "filter(status == active) | derive(profit = revenue - cost) | groupby(region) | agg(sum:profit) | sort(profit, desc)")
if [ $? -eq 0 ]; then
    assert_row_count "chain: full pipeline" "$OUT" 3 && \
    FIRST_REGION=$(echo "$OUT" | sed -n '2p' | cut -d, -f1)
    if [ "$FIRST_REGION" = "US" ]; then
        pass "filter → derive → groupby → agg → sort: US has highest profit"
    else
        fail "chain: full pipeline" "expected US first, got $FIRST_REGION"
    fi
fi

# select + rename + sort
OUT=$(run_ok "chain: select+rename+sort" -i "$TMPDIR/small.csv" -c "select(name, score) | rename(score -> grade) | sort(grade, desc)")
if [ $? -eq 0 ]; then
    assert_header "chain: select+rename+sort" "$OUT" "name,grade" && \
    FIRST=$(echo "$OUT" | sed -n '2p' | cut -d, -f1)
    if [ "$FIRST" = "Diana" ]; then
        pass "select → rename → sort: Diana (95.1) first"
    else
        fail "chain: select+rename+sort" "expected Diana first, got $FIRST"
    fi
fi

# derive + select (keep only derived column)
OUT=$(run_ok "chain: derive+select" -i "$TMPDIR/sales.csv" -c "derive(profit = revenue - cost) | select(region, sku, profit)")
if [ $? -eq 0 ]; then
    assert_header "chain: derive+select" "$OUT" "region,sku,profit" && \
    pass "derive → select: kept only region, sku, profit"
fi

echo ""

# ── 4. Output Modes ──────────────────────────────────────────────────────────

echo "── 4. Output Modes (verbose, dry-run, quiet, file output) ────────────"

# dry-run
OUT=$(run_ok "dry-run" -i "$TMPDIR/sales.csv" -c "filter(revenue > 10000)" --dry-run)
if [ $? -eq 0 ]; then
    assert_contains "dry-run" "$OUT" "dry run" && \
    assert_contains "dry-run" "$OUT" "8 rows" && \
    pass "--dry-run shows schema without output"
fi

# verbose + quiet (verbose output goes to stderr)
ERR=$($CLI -i "$TMPDIR/sales.csv" -c "filter(revenue > 10000) | sort(revenue, desc)" --verbose --quiet 2>&1 >/dev/null)
if echo "$ERR" | grep -qiE "filter|pipeline|stage"; then
    pass "--verbose --quiet shows pipeline stats on stderr"
else
    # Maybe verbose goes to stdout mixed with quiet suppressing CSV
    OUT=$($CLI -i "$TMPDIR/sales.csv" -c "filter(revenue > 10000) | sort(revenue, desc)" --verbose --quiet 2>&1)
    if echo "$OUT" | grep -qiE "filter|pipeline|stage"; then
        pass "--verbose --quiet shows pipeline stats"
    else
        fail "verbose+quiet" "no pipeline stats in output"
    fi
fi

# file output
OUT=$(run_ok "file output" -i "$TMPDIR/sales.csv" -c "filter(revenue > 20000)" -o "$TMPDIR/output.csv")
if [ $? -eq 0 ] && [ -f "$TMPDIR/output.csv" ]; then
    LINES=$(wc -l < "$TMPDIR/output.csv" | tr -d ' ')
    if [ "$LINES" -eq 4 ]; then  # header + 3 data rows
        pass "-o output.csv writes 4 lines (header + 3 rows)"
    else
        fail "file output" "expected 4 lines, got $LINES"
    fi
else
    fail "file output" "output file not created"
fi

echo ""

# ── 5. JSON Transform File ──────────────────────────────────────────────────

echo "── 5. JSON Transform File ────────────────────────────────────────────"

OUT=$(run_ok "json transform" -i "$TMPDIR/sales.csv" -f "$TMPDIR/transforms.json")
if [ $? -eq 0 ]; then
    assert_header "json transform" "$OUT" "region,sku,revenue" && \
    assert_row_count "json transform" "$OUT" 5 && \
    FIRST_REV=$(echo "$OUT" | sed -n '2p' | cut -d, -f3)
    if [ "$FIRST_REV" = "41000" ]; then
        pass "JSON transform: filter > sort > select → 5 rows, sorted desc"
    else
        fail "json transform" "expected 41000 first, got $FIRST_REV"
    fi
fi

echo ""

# ── 6. Edge Cases ────────────────────────────────────────────────────────────

echo "── 6. Edge Cases ─────────────────────────────────────────────────────"

# filter that returns no rows
OUT=$(run_ok "empty result" -i "$TMPDIR/sales.csv" -c "filter(revenue > 999999)")
if [ $? -eq 0 ]; then
    assert_row_count "empty result" "$OUT" 0 && pass "filter returning 0 rows works"
fi

# head(1)
OUT=$(run_ok "head(1)" -i "$TMPDIR/sales.csv" -c "head(1)")
if [ $? -eq 0 ]; then
    assert_row_count "head(1)" "$OUT" 1 && pass "head(1) → exactly 1 row"
fi

# head larger than dataset
OUT=$(run_ok "head(999)" -i "$TMPDIR/small.csv" -c "head(999)")
if [ $? -eq 0 ]; then
    assert_row_count "head(999)" "$OUT" 5 && pass "head(999) on 5-row file → 5 rows"
fi

# no-op pipeline (just reads and outputs)
OUTERR=$($CLI -i "$TMPDIR/small.csv" 2>&1 || true)
if echo "$OUTERR" | grep -qiE "chain|file|error|usage|provide"; then
    pass "no -c or -f: shows error asking for --chain or --file"
else
    fail "no-op" "unexpected behavior: $OUTERR"
fi

# error: missing input file (error goes to stderr)
OUTERR=$($CLI -i "$TMPDIR/nonexistent.csv" -c "head(1)" 2>&1 || true)
if echo "$OUTERR" | grep -qiE "error|not found|no such|failed"; then
    pass "missing input file produces an error"
else
    fail "missing file" "no error for missing input: $OUTERR"
fi

# --help-ops
OUT=$($CLI --help-ops 2>/dev/null)
if echo "$OUT" | grep -qF "filter"; then
    pass "--help-ops lists operations"
else
    fail "--help-ops" "didn't list filter operation"
fi

echo ""

# ── 7. Correctness Checks ───────────────────────────────────────────────────

echo "── 7. Correctness: Verify Actual Values ──────────────────────────────"

# Verify groupby sum produces correct totals
OUT=$(run_ok "correctness: groupby sum" -i "$TMPDIR/sales.csv" -c "groupby(region) | agg(sum:revenue) | sort(revenue, desc)")
if [ $? -eq 0 ]; then
    # US: 35000 + 41000 + 7200 = 83200
    # APAC: 15000 + 8500 + 18000 = 41500
    # EMEA: 22000 + 9000 = 31000
    US_REV=$(echo "$OUT" | grep "^US," | cut -d, -f2)
    APAC_REV=$(echo "$OUT" | grep "^APAC," | cut -d, -f2)
    EMEA_REV=$(echo "$OUT" | grep "^EMEA," | cut -d, -f2)
    ALL_OK=true
    [ "$US_REV" = "83200" ] || { fail "correctness: US sum" "expected 83200, got $US_REV"; ALL_OK=false; }
    [ "$APAC_REV" = "41500" ] || { fail "correctness: APAC sum" "expected 41500, got $APAC_REV"; ALL_OK=false; }
    [ "$EMEA_REV" = "31000" ] || { fail "correctness: EMEA sum" "expected 31000, got $EMEA_REV"; ALL_OK=false; }
    $ALL_OK && pass "groupby sum values correct: US=83200, APAC=41500, EMEA=31000"
fi

# Verify derive arithmetic
OUT=$(run_ok "correctness: derive" -i "$TMPDIR/sales.csv" -c "derive(profit = revenue - cost) | select(sku, revenue, cost, profit) | head(1)")
if [ $? -eq 0 ]; then
    ROW=$(echo "$OUT" | sed -n '2p')
    # SKU-001: 15000 - 9000 = 6000
    if echo "$ROW" | grep -qF "6000"; then
        pass "derive arithmetic correct: 15000 - 9000 = 6000"
    else
        fail "correctness: derive" "expected 6000 in row: $ROW"
    fi
fi

# Verify filter + count
OUT=$(run_ok "correctness: filter count" -i "$TMPDIR/sales.csv" -c "filter(status == active) | groupby(region) | agg(count:revenue)")
if [ $? -eq 0 ]; then
    US_COUNT=$(echo "$OUT" | grep "^US," | cut -d, -f2)
    if [ "$US_COUNT" = "2" ]; then
        pass "US active count correct: 2"
    else
        fail "correctness: US active count" "expected 2, got $US_COUNT"
    fi
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo "════════════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "════════════════════════════════════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "  Failures:"
    for err in "${ERRORS[@]}"; do
        echo "    - $err"
    done
    echo ""
    exit 1
fi

echo ""
echo "  All tests passed."
echo "════════════════════════════════════════════════════════════════════════"
