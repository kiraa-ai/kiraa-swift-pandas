#!/usr/bin/env python3
"""
Benchmark 15: DataFrame Construction (1M x 6 cols)

Measures the time to construct a DataFrame from dictionary-of-lists.

pandas: allocates a BlockManager with consolidated float64 blocks.
Data is copied from Python lists into contiguous numpy arrays.

SwiftPandas: creates Column.fromDoubles for each column (ContiguousArray
allocation), then assembles the DataFrame struct.

What to look for:
  - Dominated by memory allocation and data copying.
  - LCG data generation is included in the timing (same as Swift benchmarks).
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 15: DataFrame Construction")
    print_header("DataFrame Construction", args)

    section("1", "Parameters")
    cols = 6
    note(f"Rows: {args.rows:,}, Columns: {cols}")
    note(f"Total cells: {args.rows * cols:,}")
    note(f"Data size: {args.rows * cols * 8 / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    df = numeric_dataframe(args.rows, cols, seed=args.seed)
    note(f"Shape: {df.shape}")
    note(f"Columns: {list(df.columns)}")
    note(f"Dtypes: {dict(df.dtypes)}")
    note(f"Memory: {df.memory_usage(deep=True).sum() / 1024 / 1024:.1f} MB")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(
        lambda: numeric_dataframe(args.rows, cols, seed=args.seed),
        iterations=args.iterations, warmup=args.warmup)
    print_detailed_results(results, f"DataFrame({args.rows:,} x {cols})")

    section("4", "Breakdown: Data Gen vs Construction")
    # Time just the LCG data generation
    def gen_data_only():
        rng = LCG(args.seed)
        for c in range(cols):
            _ = [rng.next_float() * 1000.0 for _ in range(args.rows)]

    t_gen = benchmark_detailed(gen_data_only,
                               iterations=args.iterations, warmup=args.warmup)
    note(f"Data generation only: {format_us(t_gen['min'])}")
    note(f"Full construction:    {format_us(results['min'])}")
    overhead = results["min"] - t_gen["min"]
    note(f"DataFrame overhead:   {format_us(overhead)} ({overhead/results['min']*100:.0f}%)")
    print()

    section("5", "Scaling by Column Count")
    table_header()
    for nc in [1, 3, 6, 12]:
        t = benchmark(lambda nc=nc: numeric_dataframe(args.rows, nc, seed=args.seed),
                      iterations=args.iterations)
        bench_row(f"{args.rows:,} x {nc}", t, f"{args.rows * nc * 8 / 1024 / 1024:.0f} MB")
    print()

    note("Includes LCG data generation + ContiguousArray/BlockManager allocation")


if __name__ == "__main__":
    main()
