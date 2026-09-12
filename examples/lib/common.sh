#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# common.sh — shared helpers sourced by every example's run.sh
#
#   • find_swiftpandas   locate the CLI (env → local build → PATH)
#   • gen_sales_csv      write a deterministic sample sales dataset
#   • hr / say / timeit  small presentation helpers
#
# Nothing here is SwiftPandas-specific magic — it just keeps each example short
# and focused on the actual analytics.
# ----------------------------------------------------------------------------

# Resolve the CLI once. Order: $SWIFTPANDAS, repo-local debug build, then PATH.
find_swiftpandas() {
    if [ -n "${SWIFTPANDAS:-}" ] && [ -x "$SWIFTPANDAS" ]; then
        echo "$SWIFTPANDAS"; return 0
    fi
    # examples/lib/common.sh → repo root is two levels up.
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [ -x "$repo_root/.build/debug/swiftpandas" ]; then
        echo "$repo_root/.build/debug/swiftpandas"; return 0
    fi
    if command -v swiftpandas >/dev/null 2>&1; then
        command -v swiftpandas; return 0
    fi
    echo "ERROR: swiftpandas not found. Run 'swift build' at the repo root," >&2
    echo "       set \$SWIFTPANDAS, or install it on your PATH." >&2
    return 1
}

# Presentation helpers.
hr()  { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────"; }
say() { printf '\033[1;36m» %s\033[0m\n' "$*"; }
note(){ printf '\033[2m  %s\033[0m\n' "$*"; }

# Run a command, echo it first, and print how long it took (portable to bash 3.2).
timeit() {
    say "$*"
    local start end
    start=$(date +%s.%N 2>/dev/null || date +%s)
    "$@"
    end=$(date +%s.%N 2>/dev/null || date +%s)
    # awk handles both integer and fractional seconds.
    awk -v s="$start" -v e="$end" 'BEGIN { printf "\033[2m  ↳ %.3fs\033[0m\n", e - s }'
}

# Write a deterministic sample dataset of `n` sales rows to $1.
# Columns: date, region, product, channel, revenue, cost, units
gen_sales_csv() {
    local out="$1" n="${2:-2000}"
    awk -v n="$n" 'BEGIN {
        srand(42)  # deterministic
        regions[0]="North"; regions[1]="South"; regions[2]="East"; regions[3]="West"
        products[0]="Widget"; products[1]="Gadget"; products[2]="Gizmo"; products[3]="Sprocket"
        channels[0]="online"; channels[1]="retail"; channels[2]="partner"
        print "date,region,product,channel,revenue,cost,units"
        for (i = 0; i < n; i++) {
            day = 1 + int(rand() * 28)
            mon = 1 + int(rand() * 12)
            r = regions[int(rand() * 4)]
            p = products[int(rand() * 4)]
            c = channels[int(rand() * 3)]
            units = 1 + int(rand() * 200)
            price = 40 + int(rand() * 260)
            revenue = units * price
            cost = int(revenue * (0.45 + rand() * 0.3))
            printf "2025-%02d-%02d,%s,%s,%s,%d,%d,%d\n", mon, day, r, p, c, revenue, cost, units
        }
    }' > "$out"
}
