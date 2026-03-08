#!/usr/bin/env python3
"""
Benchmark 17: DataFrame Single-Column Sort (1M x 6 cols)

Measures sorting a DataFrame by a single column.

pandas: numpy.argsort on the sort column to get a permutation, then
take along axis 0 to reorder all columns.

SwiftPandas: stdlib TimSort on enumerated values to compute permutation,
then takeRows to allocate new columns in sorted order. When all values
are valid (no NA), uses a fast path that avoids NA-last handling.

What to look for:
  - The sort itself is O(n log n) on the key column.
  - takeRows is O(n * cols) — copying all columns in permuted order.
  - Total cost scales with both row count and column count.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 17: DataFrame Single-Column Sort")
    print_header("DataFrame Single-Column Sort", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=50)
    note(f"Shape: {df.shape}, memory: {df.memory_usage(deep=True).sum() / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    sorted_df = df.sort_values("col0")
    note(f"Sort by: col0")
    note(f"First 3 col0: {sorted_df['col0'].head(3).tolist()}")
    note(f"Last 3 col0: {sorted_df['col0'].tail(3).tolist()}")
    assert sorted_df["col0"].is_monotonic_increasing
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.sort_values("col0"),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "sort_values('col0')")

    section("4", "Column Count Impact")
    table_header()
    for nc in [1, 3, 6, 12]:
        dfc = numeric_dataframe(args.rows, nc, seed=50)
        t = benchmark(lambda dfc=dfc: dfc.sort_values("col0"), iterations=args.iterations)
        bench_row(f"sort {args.rows:,} x {nc}", t)
    print()
    note("More columns = more data to reorder after sort")

    section("5", "Ascending vs Descending")
    table_header()
    t_asc = results["min"]
    t_desc = benchmark(lambda: df.sort_values("col0", ascending=False),
                       iterations=args.iterations)
    bench_row("ascending", t_asc)
    bench_row("descending", t_desc)
    print()

    note("Algorithm: numpy.argsort (O(n log n)) + take along axis (O(n * cols))")
    note("SwiftPandas: TimSort + takeRows")


if __name__ == "__main__":
    main()
