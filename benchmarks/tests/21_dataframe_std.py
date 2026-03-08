#!/usr/bin/env python3
"""
Benchmark 21: DataFrame std() (1M x 6 cols)

Measures column-wise standard deviation across all columns.

pandas: per-column two-pass numpy.std (mean, then sum-of-squared-differences).
SwiftPandas: per-column Accelerate vDSP_meanvD + vDSP_vsaddD + vDSP_svesqD.

Expected to be ~2x slower than sum() due to the two-pass algorithm per column.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 21: DataFrame std()")
    print_header("DataFrame std()", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=60)
    note(f"Shape: {df.shape}")
    print()

    section("2", "Correctness Check")
    result = df.std()
    note("Column stds (ddof=1):")
    for col in df.columns:
        note(f"  {col}: {result[col]:.4f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.std(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "DataFrame.std()")

    section("4", "std vs sum (two-pass overhead)")
    t_sum = benchmark(lambda: df.sum(), iterations=args.iterations)
    table_header()
    bench_row("sum()", t_sum)
    bench_row("std()", results["min"])
    if t_sum > 0:
        note(f"std/sum ratio: {results['min'] / t_sum:.1f}x (expected ~2x for two-pass)")
    print()

    note("Algorithm: per-column two-pass std via NumPy")


if __name__ == "__main__":
    main()
