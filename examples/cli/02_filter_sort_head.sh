#!/bin/bash
# 02 — Filter + sort + head: top 3 active rows by revenue
set -euo pipefail
# ── Inlined helpers (was: source _lib.sh) ──────────────────────────────
# Each demo is self-contained for copy-paste reproducibility. The block
# below is identical across all demos; skip it on first read and jump
# to the 'demo_intro' a screen down to see what this specific script
# is comparing.
# ============================================================================
# _lib.sh — shared helpers for the resident-memory demo scripts
# ============================================================================
#
# Each demo script in this directory does **two** things side by side:
#
#   1. Runs the Python + pandas equivalent of the pipeline (if python3 and
#      pandas are available), timing the whole process from interpreter
#      cold-start through CSV write.
#
#   2. Runs the swiftpandas equivalent against the resident daemon, timing
#      just the wire round trip.
#
# It then prints a side-by-side comparison with a speedup multiplier. The
# goal is to show users the difference between paying the import-and-parse
# cost on every run (pandas) vs. paying it once and reusing the in-memory
# DataFrame (swiftpandas daemon).
#
# Shared concerns covered here:
#   - Locate the swiftpandas binary
#   - Ensure the daemon is running and `sales` is loaded
#   - Hi-resolution timing via `perl -MTime::HiRes` (every macOS ships perl)
#   - Detect availability of `python3` and `pandas`
#   - Pretty boxes / banners / section dividers
#   - Clean up the daemon on exit if we started it
#
# Isolation: the demos use `SWIFTPANDAS_RUNTIME_DIR=/tmp/swiftpandas-demo`
# (overridable via env) so they don't collide with a real daemon the user
# might have running under `~/.swiftpandas/`.
# ============================================================================

# Resolve the directory containing _lib.sh (this file).
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$_LIB_DIR/../.." && pwd)"

# Demo CSV that every script loads as `sales`.
DEMO_CSV="$ROOT_DIR/examples/data/sales.csv"

# Isolated runtime dir so demo daemons don't collide with the user's real one.
export SWIFTPANDAS_RUNTIME_DIR="${SWIFTPANDAS_RUNTIME_DIR:-/tmp/swiftpandas-demo}"

# Python invocations through this wrapper:
#   - `-W ignore` suppresses noisy warnings (bottleneck version, pyarrow,
#     etc.) so the demo output stays focused on the comparison itself.
#   - `-u` makes stdout/stderr unbuffered so a Ctrl-C doesn't lose lines.
PY="python3 -W ignore -u"

# Resolve the binary in this order: env override → PATH → release build →
# debug build → build from source (last resort).
if [ -n "${SWIFTPANDAS_BIN:-}" ]; then
    SWIFTPANDAS="$SWIFTPANDAS_BIN"
elif command -v swiftpandas >/dev/null 2>&1; then
    SWIFTPANDAS="$(command -v swiftpandas)"
elif [ -x "$ROOT_DIR/.build/release/swiftpandas" ]; then
    SWIFTPANDAS="$ROOT_DIR/.build/release/swiftpandas"
elif [ -x "$ROOT_DIR/.build/debug/swiftpandas" ]; then
    SWIFTPANDAS="$ROOT_DIR/.build/debug/swiftpandas"
else
    echo "Building swiftpandas (this happens once)…" >&2
    (cd "$ROOT_DIR" && swift build -c release) >/dev/null
    SWIFTPANDAS="$ROOT_DIR/.build/release/swiftpandas"
fi

# ──────────────────────────────────────────────────────────────────────────
# Output styling
# ──────────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
    MAGENTA=$'\033[35m'; RED=$'\033[31m'; BLUE=$'\033[34m'
else
    BOLD=""; DIM=""; RESET=""
    CYAN=""; GREEN=""; YELLOW=""; MAGENTA=""; RED=""; BLUE=""
fi

# Internal: print a rule made of $1 repeated $2 times.
# Uses single-quoted perl so bash doesn't try to expand $ARGV (which would
# fail under `set -u`); both args are passed via @ARGV instead.
_rule() {
    local ch="$1" w="$2"
    perl -e 'print $ARGV[0] x $ARGV[1]' "$ch" "$w"
}

# Banner at the top of each demo: title + one-line description.
# Usage: script_banner "01 — Basic Filter" "Keep rows where revenue > 10000"
script_banner() {
    local title="$1" desc="${2:-}"
    local w=72
    printf "\n${BOLD}${CYAN}╔$(_rule '═' $((w-2)))╗${RESET}\n"
    printf "${BOLD}${CYAN}║${RESET}  ${BOLD}%-$((w-4))s${RESET}  ${BOLD}${CYAN}║${RESET}\n" "$title"
    if [ -n "$desc" ]; then
        printf "${BOLD}${CYAN}║${RESET}  ${DIM}%-$((w-4))s${RESET}  ${BOLD}${CYAN}║${RESET}\n" "$desc"
    fi
    printf "${BOLD}${CYAN}╚$(_rule '═' $((w-2)))╝${RESET}\n"
}

# Label/value metadata row (aligned columns).
# Usage: script_meta "Input:" "$DEMO_CSV"
script_meta() {
    local label="$1"; shift
    printf "  ${BOLD}%-10s${RESET} ${DIM}%s${RESET}\n" "$label" "$*"
}

# Per-demo explanation: what the test does, expected result, why
# swiftpandas is faster. Text is read from stdin (heredoc) and indented
# under a section header. Each script should explain its specific scenario;
# a generic "swiftpandas is faster because daemon" is too vague.
#
# Usage:
#   demo_intro <<EOF
#   What it does: ...
#
#   Expected: swiftpandas wins by ~5×.
#   Why:
#     • <reason 1>
#     • <reason 2>
#   EOF
demo_intro() {
    printf "\n${BOLD}${BLUE}━━━ About this demo $(_rule '━' 50)${RESET}\n"
    sed 's/^/  /' </dev/stdin
}

# Section header for the "Python + pandas" block.
pandas_section() {
    printf "\n${BOLD}${CYAN}━━━ Python + pandas $(_rule '━' 50)${RESET}\n"
}

# Section header for the "swiftpandas (daemon)" block.
swiftpandas_section() {
    printf "\n${BOLD}${MAGENTA}━━━ swiftpandas (daemon) $(_rule '━' 45)${RESET}\n"
}

# Inline code / command preview (printed just before we run it).
# Usage: show_code "Python" <<'EOF'
#   df = pd.read_csv("sales.csv")
#   df[df["revenue"] > 10000]
# EOF
show_code() {
    local label="${1:-Code}"
    printf "  ${DIM}── %s ──${RESET}\n" "$label"
    sed 's/^/    /' </dev/stdin
    printf "\n"
}

# Output marker (printed just before the actual data the operation produced).
output_label() {
    printf "  ${DIM}── Output ──${RESET}\n"
}

# Time marker printed at the end of a section. Captures the value into
# the variable named by $2 so the summary block can read it later.
# Usage: time_marker_and_save "$elapsed" PANDAS_T
time_marker_and_save() {
    local elapsed="$1" varname="$2"
    printf "\n  ${YELLOW}⏱  ${RESET}${BOLD}%s${RESET}\n" "$elapsed"
    eval "$varname=\$elapsed"
}

# Final side-by-side timing summary with speedup ratio.
# Usage: summary_block "$PANDAS_T" "$SP_T"
summary_block() {
    local pandas_t="$1" sp_t="$2"
    local w=72
    # Parse millisecond figures to compute a speedup ratio if both are present.
    local speedup=""
    local pms=""
    local sms=""
    if [[ "$pandas_t" =~ ^([0-9.]+)\ ms$ ]]; then pms="${pandas_t% ms}"; fi
    if [[ "$pandas_t" =~ ^([0-9.]+)\ s$  ]]; then pms=$(awk -v v="${pandas_t% s}" 'BEGIN {printf "%.3f", v*1000}'); fi
    if [[ "$sp_t"     =~ ^([0-9.]+)\ ms$ ]]; then sms="${sp_t% ms}"; fi
    if [[ "$sp_t"     =~ ^([0-9.]+)\ s$  ]]; then sms=$(awk -v v="${sp_t% s}"     'BEGIN {printf "%.3f", v*1000}'); fi
    if [ -n "$pms" ] && [ -n "$sms" ]; then
        speedup=$(awk -v p="$pms" -v s="$sms" 'BEGIN {
            if (s <= 0) { print ""; exit }
            printf "%.1f×", p/s
        }')
    fi

    printf "\n${BOLD}${YELLOW}┌─ Timing summary $(_rule '─' 55)┐${RESET}\n"
    printf "${BOLD}${YELLOW}│${RESET}  ${CYAN}Python + pandas${RESET}        %-20s ${BOLD}${YELLOW}│${RESET}\n" "$pandas_t"
    if [ -n "$speedup" ]; then
        printf "${BOLD}${YELLOW}│${RESET}  ${MAGENTA}swiftpandas (daemon)${RESET}   %-12s ${BOLD}${GREEN}⚡ %s faster${RESET}  ${BOLD}${YELLOW}│${RESET}\n" "$sp_t" "$speedup"
    else
        printf "${BOLD}${YELLOW}│${RESET}  ${MAGENTA}swiftpandas (daemon)${RESET}   %-20s ${BOLD}${YELLOW}│${RESET}\n" "$sp_t"
    fi
    printf "${BOLD}${YELLOW}└$(_rule '─' 71)┘${RESET}\n\n"
}

# Footer printed at the very end with the script's exit hint.
script_footer() {
    printf "${DIM}Demo daemon: ${SWIFTPANDAS_RUNTIME_DIR}${RESET}\n"
    if [ "${_DEMO_STARTED_BY_US:-0}" -eq 1 ]; then
        printf "${DIM}This script will stop the daemon on exit (we started it).${RESET}\n"
    else
        printf "${DIM}Daemon was already running; leaving it alone.${RESET}\n"
        printf "${DIM}Inspect it with: ${BOLD}swiftpandas server status${RESET}${DIM} or stop with ${BOLD}swiftpandas server stop${RESET}${DIM}${RESET}\n"
    fi
}

# ──────────────────────────────────────────────────────────────────────────
# Hi-resolution timing helpers
# ──────────────────────────────────────────────────────────────────────────
# Bash 3.2 (the macOS default) has no microsecond clock. We use perl, which
# ships on every macOS — Time::HiRes::time() returns wall-clock seconds as
# a float.

_T_START=""

time_start() {
    _T_START=$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()')
}

time_end_ms() {
    local end
    end=$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()')
    awk -v s="$_T_START" -v e="$end" 'BEGIN {
        ms = (e - s) * 1000
        if (ms < 1000) { printf "%.0f ms", ms }
        else           { printf "%.2f s",  ms / 1000 }
    }'
}

# ──────────────────────────────────────────────────────────────────────────
# Daemon lifecycle
# ──────────────────────────────────────────────────────────────────────────

# Whether THIS script invocation started the daemon. Set by
# `ensure_demo_daemon`; checked by `demo_cleanup`.
_DEMO_STARTED_BY_US=0

# Start the demo daemon (idempotent) and load $DEMO_CSV as `sales`.
#
# Handles the start-immediately-after-stop race: a daemon that received
# `shutdown` sends its reply before the process actually exits (there's a
# brief flush window in [Daemon.handleConnection]). If a follow-up script
# races into `server start` during that window, the pid file is still
# present and kill(pid,0) says the process is alive → exit 5. We retry
# a few times with a small backoff to ride over the race.
ensure_demo_daemon() {
    if "$SWIFTPANDAS" server status >/dev/null 2>&1; then
        _DEMO_STARTED_BY_US=0
    else
        local tries=0
        until "$SWIFTPANDAS" server start >/dev/null 2>&1; do
            tries=$((tries + 1))
            if [ "$tries" -ge 10 ]; then
                "$SWIFTPANDAS" server start
                return 1
            fi
            sleep 0.1
        done
        _DEMO_STARTED_BY_US=1
    fi
    "$SWIFTPANDAS" load "$DEMO_CSV" --name sales 2>/dev/null
}

# Stop the daemon iff THIS script invocation started it. Idempotent.
demo_cleanup() {
    if [ "${_DEMO_STARTED_BY_US:-0}" -eq 1 ]; then
        "$SWIFTPANDAS" server stop >/dev/null 2>&1 || true
    fi
}
trap demo_cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────
# pandas availability
# ──────────────────────────────────────────────────────────────────────────
# Returns 0 if `python3` is on PATH and `import pandas` succeeds; non-zero
# otherwise. Cached so we only pay the import probe cost once per script.
_PANDAS_PROBED=0
_PANDAS_AVAILABLE=1
pandas_available() {
    if [ "$_PANDAS_PROBED" -eq 0 ]; then
        _PANDAS_PROBED=1
        if command -v python3 >/dev/null 2>&1 && \
           python3 -W ignore -c "import pandas" >/dev/null 2>&1; then
            _PANDAS_AVAILABLE=0
        else
            _PANDAS_AVAILABLE=1
        fi
    fi
    return $_PANDAS_AVAILABLE
}

pandas_skipped_notice() {
    printf "\n${DIM}── Python + pandas — skipped (no python3 or pandas not installed) ──${RESET}\n"
    printf "${DIM}   Install with: pip3 install pandas${RESET}\n"
}
# ── End of inlined helpers ─────────────────────────────────────────────
ensure_demo_daemon

script_banner "02 — Filter + Sort + Head" "Top 3 active rows by revenue (descending)"
script_meta "Input:"    "$DEMO_CSV"
script_meta "Pipeline:" 'filter(status == "active") | sort(revenue, desc) | head(3)'

demo_intro <<EOF
What it does:
  Three operations chained: filter to active orders, sort by revenue
  descending, keep the top 3 rows.

Expected outcome: swiftpandas ~5-10× faster than pandas.

Why:
  • Same import / interpreter-startup tax as demo 01 — pandas pays ~650 ms
    of fixed cost on every run.
  • In swiftpandas, the entire 3-operation chain runs server-side in one
    'pipe' call. The client serializes the chain string, sends it once,
    and receives the resulting shape. No intermediate materializations
    cross the wire.
  • This makes chained pipelines an even bigger win for swiftpandas than
    single ops, because the per-operation overhead is roughly zero.
EOF

PANDAS_T="—"
if pandas_available; then
    pandas_section
    show_code "Python equivalent" <<'EOF'
df = pd.read_csv("sales.csv")
result = (df[df["status"] == "active"]
            .sort_values("revenue", ascending=False)
            .head(3))
print(result.to_csv(index=False), end="")
EOF
    output_label
    time_start
    $PY <<PYEOF
import pandas as pd
df = pd.read_csv("$DEMO_CSV")
result = (df[df["status"] == "active"]
            .sort_values("revenue", ascending=False)
            .head(3))
print(result.to_csv(index=False), end="")
PYEOF
    time_marker_and_save "$(time_end_ms)" PANDAS_T
else
    pandas_skipped_notice
fi

swiftpandas_section
show_code "swiftpandas commands" <<EOF
swiftpandas server start                       # (started by helpers below)
swiftpandas load sales.csv --name sales      # (already done above)
swiftpandas pipe --from sales --name r02 \\
    -c 'filter(status == "active") | sort(revenue, desc) | head(3)'
swiftpandas show r02
swiftpandas server stop                        # (stopped on script exit)
EOF
output_label
time_start
"$SWIFTPANDAS" pipe --from sales --name r02 \
  -c 'filter(status == "active") | sort(revenue, desc) | head(3)' >/dev/null
"$SWIFTPANDAS" show r02 | sed 's/^/    /'
time_marker_and_save "$(time_end_ms)" SP_T

summary_block "$PANDAS_T" "$SP_T"
script_footer
