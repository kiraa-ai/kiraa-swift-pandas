#!/usr/bin/env python3
"""
Benchmark 22: DataFrame describe() (1M x 6 cols)

Measures computing 8 summary statistics per column: count, mean, std, min,
25%, 50%, 75%, max.

pandas: calls multiple numpy operations per column (count, mean, std, min,
percentile, max). The three percentiles use introselect (partial sort).

SwiftPandas: uses ranged quickselect to compute 25/50/75 percentiles in a
single partial sort pass, plus Accelerate vDSP for sum/mean/std/min/max.

What to look for:
  - Much more expensive than any single aggregation.
  - The three percentiles dominate cost (each is O(n) quickselect).
  - SwiftPandas ranged quickselect can reuse partial order from previous
    percentile, potentially gaining an edge.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 22: DataFrame describe()")
    print_header("DataFrame describe()", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=60)
    note(f"Shape: {df.shape}")
    print()

    section("2", "Correctness Check")
    desc = df.describe()
    note(f"describe() shape: {desc.shape}")
    note(f"Stats computed: {list(desc.index)}")
    note(f"col0 summary:")
    for stat in desc.index:
        note(f"  {stat:>5s}: {desc.loc[stat, 'col0']:.4f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.describe(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "DataFrame.describe()")

    section("4", "describe() vs Individual Operations")
    table_header()
    bench_row("sum()", benchmark(lambda: df.sum(), iterations=args.iterations))
    bench_row("mean()", benchmark(lambda: df.mean(), iterations=args.iterations))
    bench_row("std()", benchmark(lambda: df.std(), iterations=args.iterations))
    bench_row("min()", benchmark(lambda: df.min(), iterations=args.iterations))
    bench_row("max()", benchmark(lambda: df.max(), iterations=args.iterations))

    # Approximate percentile cost
    s0 = df["col0"]
    bench_row("quantile(0.25) 1col", benchmark(lambda: s0.quantile(0.25), iterations=args.iterations))
    bench_row("describe()", results["min"], "all 8 stats x 6 cols")
    print()

    note("describe() = count + mean + std + min + 3 quantiles + max per column")
    note("Algorithm: NumPy reductions + introselect for percentiles")
    note("SwiftPandas: vDSP reductions + ranged quickselect (reuses partial order)")


if __name__ == "__main__":
    main()
