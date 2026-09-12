#!/usr/bin/env bash
# ============================================================================
# run_validation.sh — one entry point for the engine-quick-wins validation
#
# Runs the checks that back the shipped proposals (B6a dead targets, B2a heap
# top-K parity, B4 zero-copy SPB) and prints a single PASS/FAIL summary that CI
# can gate on. The heavy determinism/scaling harnesses for B1 (multicore) and
# the GEMM backend (B2b) are not built yet — see README.md in this directory.
# ============================================================================
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail=0
step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "B6a — no dead C targets"
if bash scripts/validate/no_dead_targets.sh; then :; else fail=1; fi

step "B2a + B4 — in-suite parity & fuzz tests"
# TopKSelectionTests: top-K result is the K-prefix of the full ranking.
# SPBZeroCopyTests: unaligned round-trip, exhaustive truncation, byte-flip fuzz.
if swift test --filter "TopKSelectionTests|SPBZeroCopyTests|SPBTests|BitVectorTests" 2>&1 \
    | grep -E "Executed .* tests"; then :; else fail=1; fi
# swift test's own exit code is authoritative:
swift test --filter "TopKSelectionTests|SPBZeroCopyTests|SPBTests|BitVectorTests" >/dev/null 2>&1 \
    || fail=1

echo "==================================================================="
if [ "$fail" -ne 0 ]; then
    echo "VALIDATION: FAIL"
    exit 1
fi
echo "VALIDATION: PASS"
