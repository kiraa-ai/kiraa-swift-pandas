#!/usr/bin/env python3
"""
Benchmark 19: DataFrame sum() (1M x 6 cols)

Measures column-wise sum aggregation across all columns of a DataFrame.

pandas: iterates over each column's numpy array and calls numpy.sum().
With a consolidated BlockManager, the columns may be in a single contiguous
2D array, enabling efficient column-wise reduction.

SwiftPandas: iterates each Column, calls .sum() which delegates to
Accelerate vDSP_sveD for Double columns.

What to look for:
  - Total time ~ 6x the single Series sum() time.
  - DataFrame overhead (metadata, iteration) should be minimal.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 19: DataFrame sum()")
    print_header("DataFrame sum()", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=60)
    note(f"Shape: {df.shape}")
    print()

    section("2", "Correctness Check")
    result = df.sum()
    note("Column sums:")
    for col in df.columns:
        note(f"  {col}: {result[col]:.2f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.sum(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "DataFrame.sum()")

    section("4", "All DataFrame Aggregations Compared")
    table_header()
    for name, fn in [
        ("sum()", lambda: df.sum()),
        ("mean()", lambda: df.mean()),
        ("std()", lambda: df.std()),
        ("min()", lambda: df.min()),
        ("max()", lambda: df.max()),
    ]:
        t = benchmark(fn, iterations=args.iterations)
        bench_row(name, t)
    print()

    section("5", "DataFrame sum vs Series sum")
    s = df["col0"]
    t_series = benchmark(lambda: s.sum(), iterations=args.iterations)
    table_header()
    bench_row("Series.sum() (1 col)", t_series)
    bench_row(f"DataFrame.sum() ({cols} cols)", results["min"])
    if t_series > 0:
        ratio = results["min"] / t_series
        note(f"Ratio: {ratio:.1f}x (expected ~{cols}x for {cols} columns)")
    print()

    note("Algorithm: per-column NumPy reduction (SIMD/vDSP)")


if __name__ == "__main__":
    main()
