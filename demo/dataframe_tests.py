#!/usr/bin/env python3
"""
dataframe_tests.py — the single source of truth for the SwiftPandas vs pandas
correctness demo.

Every test lives in ONE place here, described by three things:

    desc   : a human-readable, one-line summary (shown on screen)
    code   : the Python + pandas snippet that computes the answer. It runs
             with `df` (the loaded DataFrame) and `pd` in scope and must
             leave its answer in a variable called `result`.
    chain  : the equivalent SwiftPandas DSL pipeline, fed to `swiftpandas pipe`.

The companion bash script (`compare.sh`) drives this file. For each test it:

    1. asks Python to compute the pandas answer      -> canonical CSV
    2. asks the swiftpandas binary to compute the same -> canonical CSV
    3. diffs the two canonical CSVs and reports MATCH / MISMATCH

"Canonical CSV" just means: same column order, floats rounded to 6 decimals
and formatted identically on both sides, so that 0.36666666667 (pandas) and
0.3666666666666667 (swiftpandas) are recognised as the SAME number and
76000 vs 76000.0 don't spuriously disagree.

CLI (all consumed by compare.sh — you don't normally call these by hand):

    python3 dataframe_tests.py list                 list test ids
    python3 dataframe_tests.py desc   <id>          one-line description
    python3 dataframe_tests.py code   <id>          the pandas snippet (for display)
    python3 dataframe_tests.py chain  <id>          the swiftpandas DSL (for display + run)
    python3 dataframe_tests.py pandas <id> <csv>    run pandas, print canonical CSV
    python3 dataframe_tests.py normalize            read CSV on stdin, print canonical CSV
"""

import os
import sys
import io

# --------------------------------------------------------------------------- #
# Two test catalogues, selected by the SP_SUITE environment variable:
#
#   SP_SUITE=sales  (default) — small 8-row sales.csv, correctness-focused.
#   SP_SUITE=volume           — millions of rows, correctness + speed.
#
# Add a new entry to either dict and it automatically shows up in the demo —
# no changes needed in the bash script.
# --------------------------------------------------------------------------- #
SALES_TESTS = {
    "filter": {
        "desc": "Keep only the rows where revenue is greater than 10,000",
        "code": 'result = df[df["revenue"] > 10000]',
        "chain": "filter(revenue > 10000)",
    },
    "groupby": {
        "desc": "Active rows: total revenue and average margin per region, biggest first",
        "code": (
            'active = df[df["status"] == "active"]\n'
            'result = (active.groupby("region", as_index=False)\n'
            '                .agg(revenue=("revenue", "sum"),\n'
            '                     margin=("margin", "mean"))\n'
            '                .sort_values("revenue", ascending=False))'
        ),
        "chain": 'filter(status == "active") | groupby(region) '
                 '| agg(sum:revenue, mean:margin) | sort(revenue desc)',
    },
    "derive": {
        "desc": "Add a profit column (revenue - cost) and preview the first 3 rows",
        "code": (
            'df2 = df.copy()\n'
            'df2["profit"] = df2["revenue"] - df2["cost"]\n'
            'result = df2[["region", "revenue", "cost", "profit"]].head(3)'
        ),
        "chain": "derive(profit = revenue - cost) "
                 "| select(region, revenue, cost, profit) | head(3)",
    },
    "sort_head": {
        "desc": "The 5 single highest-revenue rows across the whole dataset",
        "code": (
            'result = (df.sort_values("revenue", ascending=False)\n'
            '            [["region", "quarter", "sku", "revenue"]]\n'
            '            .head(5))'
        ),
        "chain": "sort(revenue desc) | select(region, quarter, sku, revenue) | head(5)",
    },
    "quarter_totals": {
        "desc": "Total transactions per quarter, in quarter order",
        "code": (
            'result = (df.groupby("quarter", as_index=False)\n'
            '            .agg(transactions=("transactions", "sum"))\n'
            '            .sort_values("quarter"))'
        ),
        "chain": "groupby(quarter) | agg(sum:transactions) | sort(quarter asc)",
    },
}


# --------------------------------------------------------------------------- #
# The VOLUME suite runs over a generated multi-million-row transactions CSV
# (schema: region,product,status,revenue,cost,units). Every test collapses
# all those rows down to a tiny result table, so the WORK is huge but the
# OUTPUT is small enough to print and diff on screen. This is where the
# resident-daemon speed advantage becomes obvious.
# --------------------------------------------------------------------------- #
VOLUME_TESTS = {
    "region_product_top": {
        "desc": "Top 10 region × product pairs by total revenue (over every row)",
        "code": (
            'result = (df.groupby(["region", "product"], as_index=False)\n'
            '            .agg(revenue=("revenue", "sum"),\n'
            '                 units=("units", "sum"))\n'
            '            .sort_values("revenue", ascending=False)\n'
            '            .head(10))'
        ),
        "chain": "groupby(region, product) | agg(sum:revenue, sum:units) "
                 "| sort(revenue desc) | head(10)",
    },
    "region_totals": {
        "desc": "Total revenue and average cost per region, biggest first",
        "code": (
            'result = (df.groupby("region", as_index=False)\n'
            '            .agg(revenue=("revenue", "sum"),\n'
            '                 cost=("cost", "mean"))\n'
            '            .sort_values("revenue", ascending=False))'
        ),
        "chain": "groupby(region) | agg(sum:revenue, mean:cost) | sort(revenue desc)",
    },
    "status_breakdown": {
        "desc": "Units sold and revenue per order status",
        "code": (
            'result = (df.groupby("status", as_index=False)\n'
            '            .agg(units=("units", "sum"),\n'
            '                 revenue=("revenue", "sum"))\n'
            '            .sort_values("status"))'
        ),
        "chain": "groupby(status) | agg(sum:units, sum:revenue) | sort(status asc)",
    },
}


# Pick the active suite from the environment (default: the small sales suite).
TESTS = VOLUME_TESTS if os.environ.get("SP_SUITE") == "volume" else SALES_TESTS


# --------------------------------------------------------------------------- #
# Display + comparison.
#
# Two different jobs, deliberately kept separate:
#
#   pretty()  — round floats to a few decimals JUST for readability, so both
#               result panels look clean and identical on screen.
#
#   compare() — decide MATCH / MISMATCH using a RELATIVE tolerance. This
#               matters at scale: summing 5,000,000 doubles in a different
#               order gives 1672436153.63 (pandas) vs 1672436153.62999
#               (swiftpandas) — the same number to ~11 significant figures.
#               That's floating-point non-associativity, not a wrong answer,
#               so we compare numbers within a small relative tolerance rather
#               than demanding byte-identical text.
# --------------------------------------------------------------------------- #
# On-screen rounding only. Volume figures are money (2 dp is plenty and keeps
# billion-scale sums visually identical); the small sales suite shows margins
# where 6 dp is more interesting.
DISPLAY_DECIMALS = 2 if os.environ.get("SP_SUITE") == "volume" else 6

# Two tolerance bands give a three-way verdict:
#   |diff| within MATCH_TOL  -> "match"     (identical to ~6 sig figs)
#   within CLOSE_TOL         -> "close"     (agree to ~3-4 sig figs)
#   otherwise                -> "mismatch"  (a real disagreement)
#
# The "close" band exists on purpose: at >= 10,000,000 rows swiftpandas routes
# groupby to the Metal GPU, which accumulates sums in Float32 for speed. On
# billion-scale sums that shows up as a ~0.04% difference vs pandas' Float64 —
# expected, and worth calling out on screen rather than hiding.
MATCH_TOL = 1e-6
CLOSE_TOL = 5e-3


def _pretty_cell(value: str) -> str:
    """Round a numeric cell for display; pass non-numbers through unchanged."""
    text = value.strip()
    try:
        number = float(text)
    except ValueError:
        return text
    formatted = f"{round(number, DISPLAY_DECIMALS):.{DISPLAY_DECIMALS}f}"
    formatted = formatted.rstrip("0").rstrip(".")
    return "0" if formatted in ("-0", "") else formatted


def pretty(csv_text: str) -> str:
    """Round every numeric cell of a CSV for clean, consistent display."""
    out = []
    for line in csv_text.splitlines():
        if line == "":
            continue
        out.append(",".join(_pretty_cell(c) for c in line.split(",")))
    return "\n".join(out) + ("\n" if out else "")


_RANK = {"match": 0, "close": 1, "mismatch": 2}


def _cell_status(a: str, b: str) -> str:
    """Classify one cell pair as 'match', 'close', or 'mismatch'."""
    a, b = a.strip(), b.strip()
    if a == b:
        return "match"
    try:
        fa, fb = float(a), float(b)
    except ValueError:
        return "mismatch"
    import math
    if math.isclose(fa, fb, rel_tol=MATCH_TOL, abs_tol=1e-6):
        return "match"
    if math.isclose(fa, fb, rel_tol=CLOSE_TOL, abs_tol=1e-3):
        return "close"
    return "mismatch"


def compare(text_a: str, text_b: str):
    """Compare two CSV documents cell by cell.

    Returns (verdict, message) where verdict is 'match', 'close', or
    'mismatch' (the worst status across all cells). `message` lists the cells
    that were not an exact match, so the caller can show what differed.
    """
    rows_a = [ln for ln in text_a.splitlines() if ln != ""]
    rows_b = [ln for ln in text_b.splitlines() if ln != ""]
    if len(rows_a) != len(rows_b):
        return "mismatch", f"row count differs: pandas={len(rows_a)} swiftpandas={len(rows_b)}"

    verdict = "match"
    notes = []
    for i, (ra, rb) in enumerate(zip(rows_a, rows_b)):
        ca, cb = ra.split(","), rb.split(",")
        if len(ca) != len(cb):
            return "mismatch", f"row {i}: column count differs ({len(ca)} vs {len(cb)})"
        for j, (x, y) in enumerate(zip(ca, cb)):
            status = _cell_status(x, y)
            if status != "match":
                if _RANK[status] > _RANK[verdict]:
                    verdict = status
                notes.append(f"row {i} col {j}: pandas={x!r} vs swiftpandas={y!r} [{status}]")
    return verdict, "\n".join(notes[:20])


def _result_to_csv(result) -> str:
    """Turn a pandas DataFrame/Series/scalar `result` into headerless-safe CSV."""
    import pandas as pd

    if isinstance(result, pd.Series):
        result = result.to_frame().T if result.name is None else result.reset_index()
    if not isinstance(result, pd.DataFrame):
        # Scalar -> single-cell frame.
        result = pd.DataFrame({"value": [result]})
    buf = io.StringIO()
    result.to_csv(buf, index=False)
    return buf.getvalue()


# --------------------------------------------------------------------------- #
# CLI dispatch.
# --------------------------------------------------------------------------- #
def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    cmd = argv[1]

    if cmd == "list":
        for name in TESTS:
            print(name)
        return 0

    if cmd in ("desc", "code", "chain"):
        name = argv[2]
        print(TESTS[name][cmd])
        return 0

    if cmd == "pandas":
        # Compute the pandas answer and print it as raw CSV (real output).
        name, csv_path = argv[2], argv[3]
        import pandas as pd
        df = pd.read_csv(csv_path)
        namespace = {"df": df, "pd": pd}
        exec(TESTS[name]["code"], namespace)          # noqa: S102 (trusted, local demo)
        result = namespace["result"]
        sys.stdout.write(_result_to_csv(result))
        return 0

    if cmd == "pretty":
        # Round numbers for clean on-screen display (reads CSV on stdin).
        sys.stdout.write(pretty(sys.stdin.read()))
        return 0

    if cmd == "compare":
        # compare <pandas_csv_file> <swiftpandas_csv_file>
        # Prints the verdict ('match'/'close'/'mismatch') on the first line,
        # then any differing cells. Exit 0 unless it's an outright mismatch.
        with open(argv[2]) as fa, open(argv[3]) as fb:
            verdict, message = compare(fa.read(), fb.read())
        print(verdict)
        if message:
            sys.stdout.write(message + "\n")
        return 1 if verdict == "mismatch" else 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
