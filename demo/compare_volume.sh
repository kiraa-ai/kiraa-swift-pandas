#!/usr/bin/env bash
# =============================================================================
#  SwiftPandas  ⇄  pandas   —   MILLIONS of rows: same answer, how fast?
# =============================================================================
#
#  This is the "volume" companion to compare.sh. Instead of 8 rows, it runs
#  the same kind of correctness comparison over a generated multi-million-row
#  transactions dataset — and this time it also TIMES both engines, because
#  at this scale the difference is the whole point.
#
#  For each aggregation it shows, side by side:
#
#      Python + pandas    : read_csv(...) + groupby/agg      (paid EVERY run)
#      swiftpandas        : the same groupby/agg on a DataFrame that was
#                           parsed ONCE and now lives resident in the daemon
#
#  Then it diffs the two answers (✅ MATCH / ❌ MISMATCH) and prints the
#  per-query timings with a speed-up multiplier.
#
#  Usage:
#      ./demo/compare_volume.sh                 # 5,000,000 rows (default)
#      ROWS=10000000 ./demo/compare_volume.sh   # 10M — engages the Metal GPU
#      PAUSE=1 ./demo/compare_volume.sh         # pause between steps (recording)
#      KEEP_DATA=1 ./demo/compare_volume.sh     # keep the generated CSV afterwards
#
#  The dataset is generated into demo/data/ (~8s for 5M rows) and, by default,
#  DELETED again when the script exits so nothing large is left behind. Pass
#  KEEP_DATA=1 to keep it between takes (much faster re-runs).
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# 0. Setup.
# --------------------------------------------------------------------------- #
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TESTS_PY="$SCRIPT_DIR/dataframe_tests.py"
GEN_PY="$SCRIPT_DIR/gen_data.py"

# Default 5M keeps swiftpandas on its exact Float64 path (results match pandas
# to ~6 sig figs). At >= 10M the Metal GPU groupby engages and sums in Float32,
# which trades a little precision for speed — try ROWS=10000000 to see that.
ROWS="${ROWS:-5000000}"                        # how many rows to generate
DATA_CSV="$SCRIPT_DIR/data/transactions_${ROWS}.csv"

export SWIFTPANDAS_RUNTIME_DIR="${SWIFTPANDAS_RUNTIME_DIR:-/tmp/swiftpandas-volume-demo}"
export SP_SUITE=volume                        # tell dataframe_tests.py which suite

PY="python3 -W ignore"

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    MAGENTA=$'\033[35m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
    BOLD=""; DIM=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""
    MAGENTA=""; RED=""; BLUE=""
fi

rule()   { printf '%*s\n' "${1:-74}" '' | tr ' ' "${2:-─}"; }
banner() { printf "\n${BOLD}${CYAN}"; rule 74 "═"; printf "  %s\n" "$1"; rule 74 "═"; printf "${RESET}"; }
step()   { printf "\n${BOLD}${BLUE}▸ %s${RESET}\n" "$1"; }
maybe_pause() {
    if [ "${PAUSE:-0}" = "1" ]; then
        printf "\n${DIM}   … press <Enter> to continue …${RESET}"
        read -r _ </dev/tty || true
        printf "\n"
    fi
}

# High-resolution wall-clock (macOS ships perl). Returns seconds as a float.
_now() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }
# Elapsed milliseconds between two _now readings, formatted for humans.
_elapsed_ms() { perl -e 'printf "%.0f", ($ARGV[0]-$ARGV[1])*1000' "$2" "$1"; }
# Pretty-print a millisecond figure as "123 ms" or "1.66 s".
_fmt_ms() {
    perl -e '$m=$ARGV[0]; if($m>=1000){printf "%.2f s",$m/1000}else{printf "%d ms",$m}' "$1"
}

# Resolve the binary. Prefer an explicit override or this repo's own build so
# the demo exercises the current source (the installed/Homebrew binary on PATH
# may be older); fall back to PATH, then build from source.
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

if ! $PY -c 'import pandas' >/dev/null 2>&1; then
    echo "${RED}pandas is not installed for python3 — 'pip install pandas' and retry.${RESET}" >&2
    exit 1
fi

# On exit (including Ctrl-C / error): stop our daemon, drop the resident
# DataFrame, and delete the generated dataset unless KEEP_DATA=1 was set.
cleanup() {
    "$SP" server stop >/dev/null 2>&1 || true
    if [ "${KEEP_DATA:-0}" != "1" ]; then
        rm -f "$DATA_CSV"
        # Remove the data dir too if we left it empty.
        rmdir "$SCRIPT_DIR/data" 2>/dev/null || true
        printf "${DIM}Cleaned up: removed %s and stopped the demo daemon.${RESET}\n" \
            "$(basename "$DATA_CSV")"
    else
        printf "${DIM}Kept dataset (KEEP_DATA=1): %s${RESET}\n" "$DATA_CSV"
    fi
    # The daemon's isolated runtime dir under /tmp holds only a stale socket now.
    rm -rf "$SWIFTPANDAS_RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------- #
# 1. Intro.
# --------------------------------------------------------------------------- #
banner "SwiftPandas ⇄ pandas — $(printf "%'d" "$ROWS" 2>/dev/null || echo "$ROWS") rows: same answer, how fast?"
printf "  ${DIM}pandas   :${RESET} %s\n" "$($PY -c 'import pandas; print("pandas", pandas.__version__)')"
printf "  ${DIM}swiftpan :${RESET} %s\n" "$SP"
printf "  ${DIM}Rows     :${RESET} %s\n" "$ROWS"
printf "  ${DIM}Idea     :${RESET} pandas re-parses the CSV every run; swiftpandas parses once,\n"
printf "  ${DIM}         :${RESET} then answers each query from resident memory.\n"
printf "  ${DIM}Routing  :${RESET} groupby uses the exact Float64 CPU path unless a query is\n"
printf "  ${DIM}         :${RESET} both large (≥10M rows) AND high-cardinality (≥100k groups),\n"
printf "  ${DIM}         :${RESET} where the Metal GPU wins; these low-cardinality queries stay exact.\n"
maybe_pause

# --------------------------------------------------------------------------- #
# 2. Generate the dataset (idempotent) and load it once.
# --------------------------------------------------------------------------- #
step "Preparing the dataset (generated now; removed on exit unless KEEP_DATA=1)"
mkdir -p "$SCRIPT_DIR/data"
$PY "$GEN_PY" "$DATA_CSV" "$ROWS"
printf "  ${DIM}size on disk:${RESET} %s\n" "$(du -h "$DATA_CSV" | cut -f1)"
maybe_pause

step "swiftpandas: parse the CSV ONCE into the resident daemon"
"$SP" server stop  >/dev/null 2>&1 || true
"$SP" server start >/dev/null 2>&1
sleep 1
load_t0=$(_now)
printf "  ${MAGENTA}\$ swiftpandas load transactions_${ROWS}.csv --name tx${RESET}\n  "
"$SP" load "$DATA_CSV" --name tx
load_t1=$(_now)
LOAD_MS=$(_elapsed_ms "$load_t0" "$load_t1")
printf "  ${YELLOW}⏱  one-time load: %s${RESET}\n" "$(_fmt_ms "$LOAD_MS")"
printf "  ${DIM}Every query below reuses this resident DataFrame — no re-parsing.${RESET}\n"
maybe_pause

# --------------------------------------------------------------------------- #
# 3. Run each volume test: correctness + timing.
# --------------------------------------------------------------------------- #
PASS=0; CLOSE=0; FAIL=0; FAILED_TESTS=""
TOTAL_PANDAS_MS=0; TOTAL_SWIFT_MS=0

for id in $($PY "$TESTS_PY" list); do
    desc="$($PY  "$TESTS_PY" desc  "$id")"
    code="$($PY  "$TESTS_PY" code  "$id")"
    chain="$($PY "$TESTS_PY" chain "$id")"

    banner "Test: $id"
    printf "  ${BOLD}%s${RESET}\n" "$desc"

    step "Python + pandas   ${DIM}(read_csv + compute — paid on every run)${RESET}"
    printf "%s\n" "$code" | sed 's/^/    /'
    step "swiftpandas DSL   ${DIM}(runs on the already-resident DataFrame)${RESET}"
    printf "    ${MAGENTA}pipe --from tx --name out --chain '%s'${RESET}\n" "$chain"
    maybe_pause

    # --- pandas: timed cold path (interpreter + read_csv + compute) --------- #
    p_t0=$(_now)
    pandas_raw="$($PY "$TESTS_PY" pandas "$id" "$DATA_CSV")"
    p_t1=$(_now)
    PANDAS_MS=$(_elapsed_ms "$p_t0" "$p_t1")

    # --- swiftpandas: timed query on resident data -------------------------- #
    s_t0=$(_now)
    "$SP" pipe --from tx --name out --chain "$chain" >/dev/null 2>&1
    swift_raw="$("$SP" show out --head 100)"
    s_t1=$(_now)
    SWIFT_MS=$(_elapsed_ms "$s_t0" "$s_t1")

    TOTAL_PANDAS_MS=$((TOTAL_PANDAS_MS + PANDAS_MS))
    TOTAL_SWIFT_MS=$((TOTAL_SWIFT_MS + SWIFT_MS))

    # Show each engine's own output, rounded only for readability.
    step "Result — pandas"
    printf "%s" "$pandas_raw" | $PY "$TESTS_PY" pretty | sed 's/^/    /'
    step "Result — swiftpandas"
    printf "%s" "$swift_raw"  | $PY "$TESTS_PY" pretty | sed 's/^/    /'

    # Correctness: compare the RAW numbers. Verdict is match / close / mismatch.
    pf="$(mktemp)"; sf="$(mktemp)"
    printf "%s" "$pandas_raw" > "$pf"; printf "%s" "$swift_raw" > "$sf"
    cmp_out="$($PY "$TESTS_PY" compare "$pf" "$sf" || true)"
    verdict="$(printf "%s\n" "$cmp_out" | head -1)"
    case "$verdict" in
        match)
            printf "\n  ${BOLD}${GREEN}✅  MATCH${RESET} — same answer over %s rows.\n" "$ROWS"
            PASS=$((PASS + 1)) ;;
        close)
            printf "\n  ${BOLD}${YELLOW}≈  CLOSE${RESET} — agrees to ~4 significant figures.\n"
            printf "  ${DIM}At ≥10M rows swiftpandas runs groupby on the Metal GPU, which sums in\n"
            printf "  Float32 for speed — hence the tiny difference on billion-scale totals.${RESET}\n"
            CLOSE=$((CLOSE + 1)) ;;
        *)
            printf "\n  ${BOLD}${RED}❌  MISMATCH${RESET}:\n"
            printf "%s\n" "$cmp_out" | tail -n +2 | sed 's/^/      /'
            FAIL=$((FAIL + 1)); FAILED_TESTS="$FAILED_TESTS $id" ;;
    esac
    rm -f "$pf" "$sf"

    # --- timing line -------------------------------------------------------- #
    speed=$(perl -e 'my($p,$s)=@ARGV; if($s>0){printf "%.1f×",$p/$s}else{print "n/a"}' "$PANDAS_MS" "$SWIFT_MS")
    printf "  ${YELLOW}⏱  pandas %s   vs   swiftpandas %s   ${GREEN}(%s faster)${RESET}\n" \
        "$(_fmt_ms "$PANDAS_MS")" "$(_fmt_ms "$SWIFT_MS")" "$speed"
    maybe_pause
done

# --------------------------------------------------------------------------- #
# 4. Scoreboard.
# --------------------------------------------------------------------------- #
banner "Summary — $ROWS rows"
TOTAL=$((PASS + CLOSE + FAIL))
printf "  ${GREEN}✅ exact match:${RESET} %d / %d\n" "$PASS" "$TOTAL"
if [ "$CLOSE" -gt 0 ]; then
    printf "  ${YELLOW}≈  close (GPU Float32):${RESET} %d / %d  ${DIM}(agree to ~4 sig figs)${RESET}\n" "$CLOSE" "$TOTAL"
fi
if [ "$FAIL" -gt 0 ]; then
    printf "  ${RED}❌ failed :${RESET} %d  (%s )\n" "$FAIL" "$FAILED_TESTS"
fi
overall=$(perl -e 'my($p,$s)=@ARGV; if($s>0){printf "%.1f×",$p/$s}else{print "n/a"}' "$TOTAL_PANDAS_MS" "$TOTAL_SWIFT_MS")
printf "\n  ${DIM}Across all queries:${RESET}\n"
printf "    Python + pandas (re-parse each time) : %s\n" "$(_fmt_ms "$TOTAL_PANDAS_MS")"
printf "    swiftpandas (resident queries)       : %s   ${GREEN}${BOLD}%s faster${RESET}\n" "$(_fmt_ms "$TOTAL_SWIFT_MS")" "$overall"
printf "    ${DIM}(swiftpandas also paid a one-time %s parse to load the data.)${RESET}\n" "$(_fmt_ms "$LOAD_MS")"
echo ""
[ "$FAIL" -gt 0 ] && exit 1 || true
