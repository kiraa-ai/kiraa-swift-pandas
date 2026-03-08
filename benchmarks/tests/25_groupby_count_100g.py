#!/usr/bin/env python3
"""
Benchmark 25: GroupBy count() with 100 groups (1M rows)

Measures GroupBy count aggregation — the simplest aggregation since it only
needs to increment a counter per group (no value accumulation).

pandas: Cython factorize + simple counter increment per group code.
SwiftPandas: factorize + raw-pointer counter array.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 25: GroupBy count() (100 groups)")
    print_header("GroupBy count() — 100 groups", args)

    section("1", f"Data Generation ({args.rows:,} rows, 100 groups)")
    df = groupable_dataframe(args.rows, 100, seed=70)
    note(f"Shape: {df.shape}, unique groups: {df['group'].nunique()}")
    print()

    section("2", "Correctness Check")
    result = df.groupby("group").count()
    total = result["value1"].sum()
    note(f"Total count across groups: {total:,} (expected: {args.rows:,})")
    note(f"Min group size: {result['value1'].min()}")
    note(f"Max group size: {result['value1'].max()}")
    assert total == args.rows
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    gb = df.groupby("group")
    results = benchmark_detailed(lambda: gb.count(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "groupby('group').count()")

    section("4", "Group Count Scaling")
    table_header()
    for ng in [10, 100, 1_000, 10_000]:
        dfc = groupable_dataframe(args.rows, ng, seed=70 + ng)
        gbc = dfc.groupby("group")
        t = benchmark(lambda: gbc.count(), iterations=args.iterations)
        bench_row(f"count() @ {ng:,} groups", t, f"~{args.rows // ng:,} rows/group")
    print()

    note("Algorithm: Cython factorize + counter increment")
    note("count() is the cheapest aggregation — no value accumulation needed")


if __name__ == "__main__":
    main()
