#!/usr/bin/env python3
"""
Benchmark 18: DataFrame Multi-Column Sort (1M x 6 cols, 2 keys)

Measures sorting a DataFrame by two columns (col0 ascending, col1 ascending).

pandas: uses lexsort (multi-key stable sort) via numpy. Processes keys
right-to-left, each with a stable sort, so the final result respects
the primary key ordering.

SwiftPandas: uses a SortKey enum that pre-extracts column values, then
a single TimSort with a multi-key comparator.

What to look for:
  - Multi-column sort is more expensive than single-column due to the
    multi-key comparison function.
  - pandas lexsort does multiple stable sorts; Swift uses a single sort
    with a compound comparator.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 18: DataFrame Multi-Column Sort")
    print_header("DataFrame Multi-Column Sort", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=50)
    note(f"Shape: {df.shape}")
    print()

    section("2", "Correctness Check")
    sorted_df = df.sort_values(["col0", "col1"])
    note(f"Sort by: col0, col1 (both ascending)")
    note(f"First 3 rows:")
    for i in range(3):
        note(f"  col0={sorted_df['col0'].iloc[i]:.2f}, col1={sorted_df['col1'].iloc[i]:.2f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.sort_values(["col0", "col1"]),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "sort_values(['col0', 'col1'])")

    section("4", "Single vs Multi-Column Sort")
    t_single = benchmark(lambda: df.sort_values("col0"), iterations=args.iterations)
    t_2key = results["min"]
    t_3key = benchmark(lambda: df.sort_values(["col0", "col1", "col2"]),
                       iterations=args.iterations)
    table_header()
    bench_row("1 key (col0)", t_single)
    bench_row("2 keys (col0, col1)", t_2key)
    bench_row("3 keys (col0-col2)", t_3key)
    if t_single > 0:
        note(f"2-key overhead vs 1-key: {(t_2key - t_single) / t_single * 100:+.0f}%")
        note(f"3-key overhead vs 1-key: {(t_3key - t_single) / t_single * 100:+.0f}%")
    print()

    section("5", "Mixed Ascending/Descending")
    table_header()
    t_both_asc = t_2key
    t_mixed = benchmark(
        lambda: df.sort_values(["col0", "col1"], ascending=[True, False]),
        iterations=args.iterations)
    bench_row("both ascending", t_both_asc)
    bench_row("col0 asc, col1 desc", t_mixed)
    print()

    note("Algorithm: numpy.lexsort (multi-key stable sort, right-to-left)")
    note("SwiftPandas: single TimSort with compound SortKey comparator")


if __name__ == "__main__":
    main()
