#!/usr/bin/env python3
"""
gen_data.py — deterministically generate a large transactions CSV so the
volume demo can compare SwiftPandas vs pandas on MILLIONS of rows.

Same schema as examples/data/transactions_100k.csv:

    region,product,status,revenue,cost,units

The data is fully deterministic (fixed seed) so the file is identical on
every machine and every run — pandas and swiftpandas therefore read the
exact same bytes, which is what makes the correctness comparison meaningful.

Usage:
    python3 gen_data.py <output.csv> <n_rows>

Idempotent: if <output.csv> already exists with the requested row count,
it is left untouched (generating 5M rows takes a few seconds; we don't
redo it on every take of the video).
"""

import csv
import os
import sys


def existing_row_count(path: str) -> int:
    """Return the data-row count of an existing CSV, or -1 if unreadable."""
    if not os.path.exists(path):
        return -1
    try:
        with open(path, "rb") as f:
            # Count newlines cheaply, subtract the header.
            n = sum(buf.count(b"\n") for buf in iter(lambda: f.read(1 << 20), b""))
        return max(n - 1, 0)
    except OSError:
        return -1


def generate(path: str, n_rows: int) -> None:
    regions = ["North", "South", "East", "West", "Central"]
    products = ["Widget", "Gadget", "Sprocket", "Bracket", "Valve", "Bearing"]
    statuses = ["completed", "pending", "refunded"]

    # A cheap deterministic PRNG (linear congruential) — no imports, no
    # per-row Python-object overhead from `random`, and identical everywhere.
    state = 2463534242
    def rnd():
        nonlocal state
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        return state

    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["region", "product", "status", "revenue", "cost", "units"])
        for _ in range(n_rows):
            region = regions[rnd() % len(regions)]
            product = products[rnd() % len(products)]
            status = statuses[rnd() % len(statuses)]
            # revenue in [10.00, 10_000.00], cost as ~55-80% of revenue.
            revenue = 10.0 + (rnd() % 999001) / 100.0
            cost = round(revenue * (0.55 + (rnd() % 2500) / 10000.0), 2)
            units = 1 + rnd() % 500
            w.writerow([region, product, status, f"{revenue:.2f}", f"{cost:.2f}", units])


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 1
    path, n_rows = argv[1], int(argv[2])
    have = existing_row_count(path)
    if have == n_rows:
        print(f"reuse: {path} already has {n_rows:,} rows")
        return 0
    print(f"generating {n_rows:,} rows -> {path} …", flush=True)
    generate(path, n_rows)
    print(f"done: {os.path.getsize(path) / 1e6:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
