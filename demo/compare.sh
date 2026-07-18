#!/usr/bin/env bash
# =============================================================================
#  SwiftPandas  ⇄  pandas  —  correctness comparison demo
# =============================================================================
#
#  What this script shows, on camera, end to end:
#
#    • We take one dataset (examples/data/sales.csv).
#    • For each of several dataframe operations (filter, groupby, derive,
#      sort, aggregate) we compute the answer TWICE:
#          1.  Python + pandas          — the reference implementation
#          2.  swiftpandas (Swift CLI)  — the native port under test
#    • We normalise both answers (so float formatting differences don't
#      matter) and DIFF them. Matching numbers = ✅ PASS.
#
#  The tests themselves live in `dataframe_tests.py` (one source of truth for
#  both the pandas code and the swiftpandas DSL). This script is just the
#  narrator + comparator.
#
#  Usage:
#      ./demo/compare.sh            # run straight through
#      PAUSE=1 ./demo/compare.sh    # pause for <Enter> between tests (recording)
#
#  Requirements: python3 + pandas, and the swiftpandas binary (this script
#  finds it on PATH or in .build/; it builds it as a last resort).
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# 0. Locate everything and set up an isolated daemon runtime.
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_PY="$SCRIPT_DIR/dataframe_tests.py"
DATA_CSV="$ROOT_DIR/examples/data/sales.csv"

# Keep this demo's daemon completely separate from any real one.
export SWIFTPANDAS_RUNTIME_DIR="${SWIFTPANDAS_RUNTIME_DIR:-/tmp/swiftpandas-compare-demo}"

PY="python3 -W ignore"

# Colours (only when writing to a real terminal).
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    MAGENTA=$'\033[35m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""
    MAGENTA=""; RED=""; BLUE=""
fi

rule()   { printf '%*s\n' "${1:-74}" '' | tr ' ' "${2:-─}"; }
banner() {
    printf "\n${BOLD}${CYAN}"; rule 74 "═"
    printf "  %s\n" "$1"
    rule 74 "═"; printf "${RESET}"
}
step()   { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
maybe_pause() {
    if [ "${PAUSE:-0}" = "1" ]; then
        printf "\n${DIM}   … press <Enter> to continue …${RESET}"
        read -r _ </dev/tty || true
        printf "\n"
    fi
}

# Resolve the swiftpandas binary. Prefer an explicit override or this repo's
# own build so the demo exercises the current source; fall back to PATH, then
# build from source. Order: SWIFTPANDAS_BIN → release → debug → PATH → build.
if [ -n "${SWIFTPANDAS_BIN:-}" ]; then
    SP="$SWIFTPANDAS_BIN"
elif [ -x "$ROOT_DIR/.build/release/swiftpandas" ]; then
    SP="$ROOT_DIR/.build/release/swiftpandas"
elif [ -x "$ROOT_DIR/.build/debug/swiftpandas" ]; then
    SP="$ROOT_DIR/.build/debug/swiftpandas"
elif command -v swiftpandas >/dev/null 2>&1; then
    SP="$(command -v swiftpandas)"
else
    echo "Building swiftpandas (one-time)…"
    ( cd "$ROOT_DIR" && swift build -c release >/dev/null )
    SP="$ROOT_DIR/.build/release/swiftpandas"
fi

# Sanity checks before the cameras roll.
if ! $PY -c 'import pandas' >/dev/null 2>&1; then
    echo "${RED}pandas is not installed for python3 — 'pip install pandas' and retry.${RESET}" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# Teardown: always stop the daemon we started, even on Ctrl-C / error.
# --------------------------------------------------------------------------- #
cleanup() { "$SP" server stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# 1. Intro + environment
# --------------------------------------------------------------------------- #
banner "SwiftPandas  ⇄  pandas   —   do the numbers match?"
printf "  ${DIM}Dataset  :${RESET} %s\n" "$DATA_CSV"
printf "  ${DIM}pandas   :${RESET} %s\n" "$($PY -c 'import pandas; print("pandas", pandas.__version__)')"
printf "  ${DIM}swiftpan :${RESET} %s\n" "$SP"
printf "  ${DIM}Idea     :${RESET} compute each result twice, normalise, and diff.\n"
maybe_pause

# --------------------------------------------------------------------------- #
# 2. Start the resident daemon and load the dataset ONCE.
# --------------------------------------------------------------------------- #
step "Starting the swiftpandas resident daemon and loading the dataset once"
"$SP" server stop  >/dev/null 2>&1 || true
"$SP" server start >/dev/null 2>&1
sleep 1
printf "  ${MAGENTA}\$ swiftpandas load sales.csv --name sales${RESET}\n  "
"$SP" load "$DATA_CSV" --name sales
maybe_pause

# --------------------------------------------------------------------------- #
# 3. Run every test: pandas answer  vs  swiftpandas answer.
# --------------------------------------------------------------------------- #
PASS=0
FAIL=0
FAILED_TESTS=""

for id in $($PY "$TESTS_PY" list); do
    desc="$($PY  "$TESTS_PY" desc  "$id")"
    code="$($PY  "$TESTS_PY" code  "$id")"
    chain="$($PY "$TESTS_PY" chain "$id")"

    banner "Test: $id"
    printf "  ${BOLD}%s${RESET}\n" "$desc"

    # --- Show the two implementations side by side (as source) -------------- #
    step "Python + pandas"
    printf "%s\n" "$code" | sed 's/^/    /'
    step "swiftpandas DSL"
    printf "    ${MAGENTA}pipe --from sales --name out --chain '%s'${RESET}\n" "$chain"
    maybe_pause

    # --- Compute the pandas reference answer (raw CSV) ---------------------- #
    pandas_raw="$($PY "$TESTS_PY" pandas "$id" "$DATA_CSV")"

    # --- Compute the swiftpandas answer ------------------------------------- #
    # (stderr is a harmless "overwrote existing df 'out'" notice on reruns.)
    "$SP" pipe --from sales --name out --chain "$chain" >/dev/null 2>&1
    swift_raw="$("$SP" show out --head 100)"

    # --- Show each engine's output (rounded only for readability) ----------- #
    step "Result — pandas"
    printf "%s" "$pandas_raw" | $PY "$TESTS_PY" pretty | sed 's/^/    /'
    step "Result — swiftpandas"
    printf "%s" "$swift_raw"  | $PY "$TESTS_PY" pretty | sed 's/^/    /'

    # --- Compare the raw numbers with a relative tolerance ------------------ #
    pf="$(mktemp)"; sf="$(mktemp)"
    printf "%s" "$pandas_raw" > "$pf"; printf "%s" "$swift_raw" > "$sf"
    cmp_out="$($PY "$TESTS_PY" compare "$pf" "$sf" || true)"
    verdict="$(printf "%s\n" "$cmp_out" | head -1)"
    if [ "$verdict" = "match" ] || [ "$verdict" = "close" ]; then
        printf "\n  ${BOLD}${GREEN}✅  MATCH${RESET} — swiftpandas agrees with pandas.\n"
        PASS=$((PASS + 1))
    else
        printf "\n  ${BOLD}${RED}❌  MISMATCH${RESET} — outputs differ:\n"
        printf "%s\n" "$cmp_out" | tail -n +2 | sed 's/^/      /'
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $id"
    fi
    rm -f "$pf" "$sf"
    maybe_pause
done

# --------------------------------------------------------------------------- #
# 4. Scoreboard.
# --------------------------------------------------------------------------- #
banner "Summary"
TOTAL=$((PASS + FAIL))
printf "  ${GREEN}✅ passed:${RESET} %d / %d\n" "$PASS" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
    printf "  ${RED}❌ failed:${RESET} %d  (%s )\n" "$FAIL" "$FAILED_TESTS"
    echo ""
    exit 1
fi
printf "\n  ${BOLD}${GREEN}All %d results matched pandas (numbers within float tolerance).${RESET}\n\n" "$TOTAL"
