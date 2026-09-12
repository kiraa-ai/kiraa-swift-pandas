#!/usr/bin/env bash
# Run every example end-to-end. Handy as a smoke test and as a tour.
set -euo pipefail
cd "$(dirname "$0")"

for ex in 01-quickstart 02-resident-session 03-sales-report; do
    printf '\n\033[1;35m═══ %s ═══\033[0m\n\n' "$ex"
    ( cd "$ex" && ./run.sh )
done

printf '\n\033[1;32mAll examples completed.\033[0m\n'
