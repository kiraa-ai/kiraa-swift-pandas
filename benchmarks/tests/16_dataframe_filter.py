#!/usr/bin/env python3
"""
Benchmark 16: DataFrame Boolean Filter (1M x 6 cols)

Measures filtering a DataFrame with a boolean mask (df[df["col0"] > 500.0]).

pandas: vectorized comparison creates a boolean numpy array, then fancy
indexing extracts matching rows. Uses C-level take() internally.

SwiftPandas: comparison generates a [Bool] mask, then filter(mask:) uses
an index-gather strategy (collect true indices, then takeRows) which avoids
branch misprediction on the per-element copy.

What to look for:
  - ~50% selectivity means ~500K rows in the result.
  - Cost includes both mask creation and row extraction.
  - Row extraction dominates (copies 6 columns worth of data).
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 16: DataFrame Filter")
    print_header("DataFrame Filter", args)

    cols = 6

    section("1", f"Data Generation ({args.rows:,} x {cols})")
    df = numeric_dataframe(args.rows, cols, seed=41)
    note(f"Shape: {df.shape}, memory: {df.memory_usage(deep=True).sum() / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    mask = df["col0"] > 500.0
    filtered = df[mask]
    selectivity = mask.sum() / len(mask)
    note(f"Filter: df['col0'] > 500.0")
    note(f"Selectivity: {selectivity:.1%} ({mask.sum():,} of {len(mask):,} rows)")
    note(f"Result shape: {filtered.shape}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df[df["col0"] > 500.0],
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, f"df[df['col0'] > 500.0] @ {args.rows:,}")

    section("4", "Breakdown: Mask vs Extraction")
    t_mask = benchmark_detailed(lambda: df["col0"] > 500.0,
                                iterations=args.iterations, warmup=args.warmup)
    precomputed_mask = df["col0"] > 500.0
    t_extract = benchmark_detailed(lambda: df[precomputed_mask],
                                   iterations=args.iterations, warmup=args.warmup)
    table_header()
    bench_row("mask creation", t_mask["min"], "comparison -> bool array")
    bench_row("row extraction", t_extract["min"], f"{mask.sum():,} rows x {cols} cols")
    bench_row("total", results["min"])
    print()

    section("5", "Selectivity Impact")
    table_header()
    for threshold in [100.0, 250.0, 500.0, 750.0, 900.0]:
        m = df["col0"] > threshold
        sel = m.sum() / len(m)
        t = benchmark(lambda t=threshold: df[df["col0"] > t], iterations=args.iterations)
        bench_row(f"> {threshold:.0f} ({sel:.0%})", t, f"{m.sum():,} rows")
    print()
    note("Lower selectivity = fewer rows copied = faster extraction")

    print()
    note("Algorithm: NumPy vectorized comparison + fancy indexing (C-level take)")
    note("SwiftPandas: [Bool] mask -> index gather -> takeRows")


if __name__ == "__main__":
    main()
