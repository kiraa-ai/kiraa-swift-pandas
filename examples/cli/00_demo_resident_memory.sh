#!/bin/bash
# ============================================================================
# demo_resident_memory.sh — End-to-end walkthrough of the swiftpandas daemon
# ============================================================================
#
# Generates a ~5 MB synthetic sales CSV, starts the swiftpandas daemon, loads
# the CSV into resident memory as df_test, runs a transform that reduces it
# to a short regional summary, saves the result, and shuts the daemon down.
# The script prints macOS process memory (RSS) snapshots before, during, and
# after so you can see the resident-memory footprint of the daemon.
#
# Usage:
#   ./examples/cli/demo_resident_memory.sh                # builds first if needed
#   SWIFTPANDAS_BIN=/usr/local/bin/swiftpandas \
#     ./examples/cli/demo_resident_memory.sh              # use a pre-installed binary
#
# Exit codes:
#   0 success
#   non-zero any step failed (script uses `set -euo pipefail`)
# ============================================================================
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO_DIR="$(mktemp -d "/tmp/swiftpandas-demo.XXXXXX")"
CSV_INPUT="$DEMO_DIR/sales_5mb.csv"
CSV_OUTPUT="$DEMO_DIR/regional_summary.csv"
SOCK="$DEMO_DIR/sock"
PIDF="$DEMO_DIR/pid"
LOGF="$DEMO_DIR/daemon.log"
TARGET_BYTES=$((5 * 1024 * 1024))   # ~5 MB

# Locate the binary: env override → installed → debug build → release build.
if [ -n "${SWIFTPANDAS_BIN:-}" ]; then
    SWIFTPANDAS="$SWIFTPANDAS_BIN"
elif command -v swiftpandas >/dev/null 2>&1; then
    SWIFTPANDAS="$(command -v swiftpandas)"
elif [ -x "$ROOT_DIR/.build/release/swiftpandas" ]; then
    SWIFTPANDAS="$ROOT_DIR/.build/release/swiftpandas"
elif [ -x "$ROOT_DIR/.build/debug/swiftpandas" ]; then
    SWIFTPANDAS="$ROOT_DIR/.build/debug/swiftpandas"
else
    echo "swiftpandas binary not found — building from source…" >&2
    (cd "$ROOT_DIR" && swift build -c release)
    SWIFTPANDAS="$ROOT_DIR/.build/release/swiftpandas"
fi

# ── Output helpers ─────────────────────────────────────────────────────────
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

step()   { printf "\n${BOLD}── %s ──${RESET}\n" "$*"; }
info()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
note()   { printf "  ${DIM}%s${RESET}\n" "$*"; }
header() { printf "\n${CYAN}${BOLD}%s${RESET}\n${DIM}%s${RESET}\n" "$*" "$(printf '=%.0s' {1..70})"; }

# Show RSS (resident set size, KB → human) of every swiftpandas process.
# Falls back to a friendly "no daemon" message when none are running.
mem_snapshot() {
    local label="$1"
    printf "\n  ${YELLOW}● MEMORY ($label)${RESET}\n"
    local pids
    pids=$(pgrep -x swiftpandas 2>/dev/null || true)
    if [ -z "$pids" ]; then
        printf "    ${DIM}(no swiftpandas processes resident)${RESET}\n"
        return
    fi
    printf "    %-8s %-10s %s\n" "PID" "RSS" "COMMAND"
    printf "    %-8s %-10s %s\n" "───" "───" "───────"
    # ps -o rss reports RSS in kilobytes on macOS.
    for pid in $pids; do
        local rss_kb command human
        rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0")
        command=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-50 || echo "?")
        # Convert KB → human-readable (B/KB/MB).
        if   [ "$rss_kb" -ge 1048576 ]; then human="$(awk "BEGIN {printf \"%.1f GB\", $rss_kb/1048576}")"
        elif [ "$rss_kb" -ge 1024 ]; then    human="$(awk "BEGIN {printf \"%.1f MB\", $rss_kb/1024}")"
        else                                 human="${rss_kb} KB"; fi
        printf "    %-8s %-10s %s\n" "$pid" "$human" "$command"
    done
}

cleanup() {
    # Best-effort daemon shutdown + temp cleanup. Don't fail the script on
    # cleanup errors — we already showed the user what they came for.
    "$SWIFTPANDAS" server stop --socket "$SOCK" >/dev/null 2>&1 || true
    rm -rf "$DEMO_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Generate a ~5 MB synthetic CSV ──────────────────────────────────────
header "swiftpandas resident-memory demo"
note "scratch dir: $DEMO_DIR"
note "binary:      $SWIFTPANDAS"

step "1/7  Generating ~5 MB synthetic sales CSV"

# Header + a row per second of a fictional sales feed; ~80 bytes/row gets us
# to ~5 MB in around 65k rows. Awk is portable on every macOS shell.
awk -v target="$TARGET_BYTES" '
BEGIN {
    srand(42);
    regions["NA"]=0;  regions["EMEA"]=0;  regions["APAC"]=0;  regions["LATAM"]=0;
    n=0; total=0;
    header="order_id,region,sku,units,unit_price,discount,channel,status\n";
    printf "%s", header;
    total += length(header);
    while (total < target) {
        n++;
        reg_i = int(rand() * 4);
        if (reg_i==0) reg="NA"; else if (reg_i==1) reg="EMEA"; else if (reg_i==2) reg="APAC"; else reg="LATAM";
        sku = sprintf("SKU-%05d", int(rand()*9999)+1);
        units = int(rand()*40)+1;
        price = int((rand()*490+10) * 100) / 100;
        disc  = int(rand()*30) / 100;
        ch_i = int(rand()*3);
        if (ch_i==0) ch="online"; else if (ch_i==1) ch="retail"; else ch="wholesale";
        status_i = int(rand()*4);
        if (status_i==0) status="active"; else if (status_i==1) status="pending"; else if (status_i==2) status="cancelled"; else status="active";
        line = sprintf("%d,%s,%s,%d,%.2f,%.2f,%s,%s\n", n+10000000, reg, sku, units, price, disc, ch, status);
        printf "%s", line;
        total += length(line);
    }
}' > "$CSV_INPUT"

CSV_SIZE_HUMAN=$(du -h "$CSV_INPUT" | cut -f1)
CSV_ROWS=$(($(wc -l < "$CSV_INPUT") - 1))
info "Created $CSV_INPUT ($CSV_SIZE_HUMAN, $CSV_ROWS rows)"

# ── 2. Memory snapshot BEFORE the daemon exists ────────────────────────────
step "2/7  Memory snapshot — before server start"
mem_snapshot "before"

# ── 3. Start the daemon ────────────────────────────────────────────────────
step "3/7  swiftpandas server start"
"$SWIFTPANDAS" server start --socket "$SOCK" --pidfile "$PIDF" --log "$LOGF"
note "log file:    $LOGF"

# ── 4. Load the 5 MB CSV into resident memory as df_test ──────────────────
step "4/7  swiftpandas load $(basename "$CSV_INPUT") --name df_test"
"$SWIFTPANDAS" load "$CSV_INPUT" --name df_test --socket "$SOCK"

# Memory snapshot WITH the dataframe resident. Two numbers visible here:
#   - daemon process RSS (macOS view, shown by mem_snapshot)
#   - swiftpandas's own DataFrame.estimatedBytes (shown by `server status`)
step "5/7  Memory snapshots — daemon RSS and DataFrame.estimatedBytes"
mem_snapshot "after load"
echo ""
"$SWIFTPANDAS" server status --socket "$SOCK"

# ── 6. Summarise df_test into a regional summary ──────────────────────────
step "6/7  Transform df_test → regional_summary"

# Filter active orders, derive revenue = units * unit_price * (1 - discount),
# then groupby region and sum/mean to a tiny rollup.
"$SWIFTPANDAS" pipe \
    --from df_test \
    --name regional_summary \
    -c "filter(status == \"active\") | derive(revenue = units * unit_price) | groupby(region) | agg(sum:revenue, mean:units, count:units)" \
    --socket "$SOCK"

echo ""
echo "  ${CYAN}regional_summary (top 5):${RESET}"
"$SWIFTPANDAS" show regional_summary --head 5 --socket "$SOCK" | sed 's/^/    /'

# Export the result.
"$SWIFTPANDAS" save regional_summary "$CSV_OUTPUT" --socket "$SOCK"
SUMMARY_SIZE=$(du -h "$CSV_OUTPUT" | cut -f1)
info "Wrote $CSV_OUTPUT ($SUMMARY_SIZE)"

# ── 7. Stop the daemon and show that memory is released ───────────────────
step "7/7  swiftpandas server stop"
"$SWIFTPANDAS" server stop --socket "$SOCK"
# Give launchd / kernel a beat to fully reap.
sleep 0.2
mem_snapshot "after stop"

# Clean up trap will remove the temp dir.
header "Done"
note "Summary CSV:   $CSV_OUTPUT  ($SUMMARY_SIZE)"
note "Daemon log:    $LOGF"
note "Workspace:     $DEMO_DIR   (will be removed on exit)"
echo ""
