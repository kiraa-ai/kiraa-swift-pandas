#!/usr/bin/env python3
"""
Benchmark 29: CSV Read (1M x 6 cols)

Measures parsing a CSV string into a DataFrame.

pandas: uses a C-level tokenizer (based on xsv) that processes bytes directly.
The parser handles quoting, escaping, type inference, and NA detection in a
single pass. For numeric-only CSVs, the conversion is optimized.

SwiftPandas: two-tier byte-level UTF-8 parser. Tier 1: parseFieldGrid builds
a flat array of byte ranges. Tier 2: column-wise type inference and conversion.
Uses fastParseDouble for the common integer+decimal pattern, falling back to
strtod for scientific notation.

What to look for:
  - CSV parsing is typically I/O-bound, but in-memory parsing is compute-bound.
  - String-to-double conversion dominates for numeric CSVs.
  - Field tokenization (finding delimiters) is fast with byte scanning.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 29: CSV Read")
    print_header("CSV Read", args)

    cols = 6

    section("1", f"CSV Generation ({args.rows:,} x {cols})")
    csv_data = csv_string(args.rows, cols, seed=100)
    size_mb = len(csv_data) / 1024 / 1024
    note(f"CSV size: {size_mb:.1f} MB ({len(csv_data):,} bytes)")
    note(f"Rows: {args.rows:,}, Columns: {cols}")
    note(f"First line: {csv_data[:80]}...")
    print()

    section("2", "Correctness Check")
    df = pd.read_csv(io.StringIO(csv_data))
    note(f"Result shape: {df.shape}")
    note(f"Columns: {list(df.columns)}")
    note(f"Dtypes: {dict(df.dtypes)}")
    note(f"First row: {df.iloc[0].tolist()}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: pd.read_csv(io.StringIO(csv_data)),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, f"read_csv @ {args.rows:,} x {cols}")

    section("4", "Throughput")
    min_us = results["min"] / 1000.0
    throughput_mbs = size_mb / (results["min"] / 1e9)
    rows_per_sec = args.rows / (results["min"] / 1e9)
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Throughput: {throughput_mbs:.0f} MB/s")
    note(f"Rows/second: {rows_per_sec:,.0f}")
    note(f"Cells/second: {rows_per_sec * cols:,.0f}")
    print()

    section("5", "Scaling")
    table_header()
    for n in [10_000, 100_000, 500_000, args.rows]:
        if n > args.rows:
            continue
        csv_n = csv_string(n, cols, seed=100)
        t = benchmark(lambda csv_n=csv_n: pd.read_csv(io.StringIO(csv_n)),
                      iterations=args.iterations)
        mb = len(csv_n) / 1024 / 1024
        bench_row(f"read @ {n:,}", t, f"{mb:.1f} MB")
    print()

    section("6", "Impact of Column Count")
    table_header()
    for nc in [1, 3, 6, 12]:
        csv_nc = csv_string(args.rows, nc, seed=100)
        t = benchmark(lambda csv_nc=csv_nc: pd.read_csv(io.StringIO(csv_nc)),
                      iterations=args.iterations)
        bench_row(f"{args.rows:,} x {nc}", t, f"{len(csv_nc) / 1024 / 1024:.1f} MB")
    print()

    note("Algorithm: C-level tokenizer + type inference + float64 conversion")
    note("SwiftPandas: byte-level UTF-8 state machine + fastParseDouble")


if __name__ == "__main__":
    main()
