#!/usr/bin/env python3
"""
Benchmark 26: GroupBy sum() with 10,000 groups (1M rows)

Measures GroupBy sum with high cardinality (10K groups, ~100 rows/group).

What to look for:
  - Higher group count means the hash table is larger and less cache-friendly.
  - The accumulation step becomes more scattered (random access to accumulators).
  - pandas Cython implementation handles high cardinality efficiently via
    open-addressing hash tables.
  - SwiftPandas FNV-1a hash table with raw-pointer accumulators.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 26: GroupBy sum() (10K groups)")
    print_header("GroupBy sum() — 10,000 groups", args)

    section("1", f"Data Generation ({args.rows:,} rows, 10,000 groups)")
    df = groupable_dataframe(args.rows, 10_000, seed=71)
    note(f"Shape: {df.shape}, unique groups: {df['group'].nunique()}")
    note(f"Avg rows/group: {args.rows // 10_000}")
    print()

    section("2", "Correctness Check")
    result = df.groupby("group").sum()
    note(f"Result shape: {result.shape}")
    note(f"Total value1 sum: {result['value1'].sum():.2f}")
    note(f"Total from original: {df['value1'].sum():.2f}")
    assert abs(result["value1"].sum() - df["value1"].sum()) < 1.0
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    gb = df.groupby("group")
    results = benchmark_detailed(lambda: gb.sum(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "groupby('group').sum() @ 10K groups")

    section("4", "Group Cardinality Scaling")
    table_header()
    for ng in [10, 100, 1_000, 10_000, 50_000]:
        dfc = groupable_dataframe(args.rows, ng, seed=70 + ng)
        gbc = dfc.groupby("group")
        t = benchmark(lambda: gbc.sum(), iterations=args.iterations)
        bench_row(f"sum() @ {ng:,} groups", t, f"~{args.rows // ng} rows/group")
    print()
    note("Higher cardinality -> larger hash table -> more cache misses")

    section("5", "100 groups vs 10K groups")
    df100 = groupable_dataframe(args.rows, 100, seed=70)
    gb100 = df100.groupby("group")
    t_100g = benchmark(lambda: gb100.sum(), iterations=args.iterations)
    table_header()
    bench_row("100 groups", t_100g)
    bench_row("10,000 groups", results["min"])
    if t_100g > 0:
        note(f"10K groups is {results['min'] / t_100g:.1f}x slower than 100 groups")
    print()

    note("Algorithm: Cython hash table factorize + indexed accumulation")
    note("SwiftPandas: FNV-1a factorize + raw-pointer accumulators")


if __name__ == "__main__":
    main()
