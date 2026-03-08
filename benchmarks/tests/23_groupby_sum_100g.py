#!/usr/bin/env python3
"""
Benchmark 23: GroupBy sum() with 100 groups (1M rows)

Measures GroupBy sum aggregation on a 1M-row DataFrame with 100 distinct
string group keys.

pandas: factorize step (Cython hash table maps strings to integer codes),
then per-group accumulation using a Cython-optimized aggregation loop.

SwiftPandas: fused factorize+accumulate with FNV-1a string hashing and
raw-pointer accumulators. For datasets >= 10M rows, Metal GPU dispatch is
used. At 1M rows, the CPU fast-path is used.

What to look for:
  - 100 groups with 1M rows -> ~10K rows per group on average.
  - The factorize step (string hashing) dominates for low group counts.
  - After factorize, the accumulation is a simple indexed sum.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 23: GroupBy sum() (100 groups)")
    print_header("GroupBy sum() — 100 groups", args)

    section("1", f"Data Generation ({args.rows:,} rows, 100 groups)")
    df = groupable_dataframe(args.rows, 100, seed=70)
    note(f"Shape: {df.shape}")
    note(f"Columns: {list(df.columns)}")
    note(f"Unique groups: {df['group'].nunique()}")
    note(f"Avg rows/group: {args.rows // 100:,}")
    print()

    section("2", "Correctness Check")
    result = df.groupby("group").sum()
    note(f"Result shape: {result.shape}")
    note(f"First 5 groups:")
    for grp in result.index[:5]:
        note(f"  {grp}: value1={result.loc[grp, 'value1']:.2f}, value2={result.loc[grp, 'value2']:.2f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    gb = df.groupby("group")
    results = benchmark_detailed(lambda: gb.sum(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "groupby('group').sum()")

    section("4", "All GroupBy Aggregations (100 groups)")
    table_header()
    for name in ["sum", "mean", "count", "min", "max", "std"]:
        fn = getattr(gb, name)
        t = benchmark(fn, iterations=args.iterations)
        bench_row(f"{name}()", t)
    print()

    section("5", "Factorize Cost Isolation")
    # Time just the factorize step (categorize keys)
    t_factorize = benchmark(lambda: pd.factorize(df["group"]),
                            iterations=args.iterations)
    table_header()
    bench_row("factorize only", t_factorize, "string -> integer codes")
    bench_row("full groupby.sum()", results["min"], "factorize + accumulate")
    overhead = results["min"] - t_factorize if t_factorize < results["min"] else 0
    note(f"Accumulation cost: ~{format_us(overhead)}")
    print()

    note("Algorithm: Cython hash table factorize + indexed accumulation")
    note("SwiftPandas: FNV-1a factorize + raw-pointer accumulators")
    note("SwiftPandas GPU: Metal compute shaders for >= 10M rows")


if __name__ == "__main__":
    main()
