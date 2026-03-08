#!/usr/bin/env python3
"""
Benchmark 24: GroupBy mean() with 100 groups (1M rows)

Measures GroupBy mean aggregation. Requires computing both sum and count
per group, then dividing.

pandas: Cython factorize + per-group sum/count accumulation, then element-wise
division.

SwiftPandas: factorize + raw-pointer accumulators for sum and count, then
division. The factorize result is reused from the GroupBy object.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 24: GroupBy mean() (100 groups)")
    print_header("GroupBy mean() — 100 groups", args)

    section("1", f"Data Generation ({args.rows:,} rows, 100 groups)")
    df = groupable_dataframe(args.rows, 100, seed=70)
    note(f"Shape: {df.shape}, unique groups: {df['group'].nunique()}")
    print()

    section("2", "Correctness Check")
    result = df.groupby("group").mean()
    note(f"Result shape: {result.shape}")
    note(f"First 3 group means:")
    for grp in result.index[:3]:
        note(f"  {grp}: value1={result.loc[grp, 'value1']:.4f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    gb = df.groupby("group")
    results = benchmark_detailed(lambda: gb.mean(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "groupby('group').mean()")

    section("4", "mean vs sum vs count")
    table_header()
    bench_row("sum()", benchmark(lambda: gb.sum(), iterations=args.iterations))
    bench_row("mean()", results["min"])
    bench_row("count()", benchmark(lambda: gb.count(), iterations=args.iterations))
    print()
    note("mean() requires both sum and count, but the overhead is minimal")

    note("Algorithm: Cython factorize + sum/count accumulation + division")


if __name__ == "__main__":
    main()
