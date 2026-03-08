#!/usr/bin/env python3
"""
Benchmark 28: Concat (Vertical Stack) — 10 x 100K DataFrames

Measures vertical concatenation (stacking) of multiple DataFrames.

pandas: BlockManager concatenation with reindexing. Allocates new contiguous
blocks and copies data from each input DataFrame.

SwiftPandas: per-column array concatenation (reserveCapacity + append) then
new DataFrame construction.

What to look for:
  - Dominated by memory allocation and copying.
  - Total output is 1M rows (10 x 100K).
  - Should scale linearly with total row count.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 28: Concat", default_rows=100_000)
    print_header("Concat (Vertical Stack)", args)

    n_frames = 10
    cols = 6

    section("1", f"Data Generation ({n_frames} x {args.rows:,} x {cols})")
    frames = [numeric_dataframe(args.rows, cols, seed=90 + i) for i in range(n_frames)]
    total_rows = args.rows * n_frames
    total_mb = total_rows * cols * 8 / 1024 / 1024
    note(f"Each frame: {args.rows:,} x {cols}")
    note(f"Total output: {total_rows:,} rows ({total_mb:.1f} MB)")
    print()

    section("2", "Correctness Check")
    result = pd.concat(frames, ignore_index=True)
    note(f"Result shape: {result.shape}")
    note(f"Expected rows: {total_rows:,}")
    assert len(result) == total_rows
    assert list(result.columns) == [f"col{i}" for i in range(cols)]
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(
        lambda: pd.concat(frames, ignore_index=True),
        iterations=args.iterations, warmup=args.warmup)
    print_detailed_results(results, f"concat({n_frames} x {args.rows:,})")

    section("4", "Throughput")
    min_us = results["min"] / 1000.0
    throughput_gbs = total_mb / 1024 / (results["min"] / 1e9)
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Throughput: {throughput_gbs:.1f} GB/s")
    print()

    section("5", "Scaling by Number of Frames")
    table_header()
    for nf in [2, 5, 10, 20]:
        frs = [numeric_dataframe(args.rows, cols, seed=90 + i) for i in range(nf)]
        t = benchmark(lambda frs=frs: pd.concat(frs, ignore_index=True),
                      iterations=args.iterations)
        bench_row(f"{nf} frames", t, f"{args.rows * nf:,} total rows")
    print()

    note("Algorithm: BlockManager concat + reindex (memory copy dominated)")
    note("SwiftPandas: per-column array concatenation + new DataFrame")


if __name__ == "__main__":
    main()
