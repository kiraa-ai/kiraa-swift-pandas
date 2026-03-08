#!/usr/bin/env python3
"""
Benchmark 20: DataFrame mean() (1M x 6 cols)

Measures column-wise mean aggregation across all columns.

pandas: per-column numpy.mean() with pairwise summation.
SwiftPandas: per-column Accelerate vDSP_meanvD.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 20: DataFrame mean()")
    print_header("DataFrame mean()", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=60)
    note(f"Shape: {df.shape}")
    print()

    section("2", "Correctness Check")
    result = df.mean()
    note("Column means:")
    for col in df.columns:
        note(f"  {col}: {result[col]:.4f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.mean(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "DataFrame.mean()")

    section("4", "mean vs sum")
    t_sum = benchmark(lambda: df.sum(), iterations=args.iterations)
    table_header()
    bench_row("sum()", t_sum)
    bench_row("mean()", results["min"])
    print()

    note("Algorithm: per-column numpy.mean (pairwise summation + division)")


if __name__ == "__main__":
    main()
