#!/usr/bin/env python3
"""
Benchmark 30: CSV Write (1M x 6 cols)

Measures converting a DataFrame to a CSV string.

pandas: Python-level string formatting for each cell, joined with separators.
The to_csv() method iterates rows and formats each value. This is typically
much slower than reading due to Python string overhead.

SwiftPandas: column-wise pre-formatting strategy. Each column is formatted
independently, then rows are assembled. Uses integer-style output optimization
for doubles that happen to be whole numbers. RFC 4180 quoting for strings
containing commas or quotes.

What to look for:
  - Write is typically slower than read due to float-to-string formatting.
  - pandas to_csv is notably slow because it uses Python-level formatting.
  - SwiftPandas column-wise pre-formatting can be significantly faster.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 30: CSV Write")
    print_header("CSV Write", args)

    cols = 6

    section("1", f"DataFrame Generation ({args.rows:,} x {cols})")
    csv_data = csv_string(args.rows, cols, seed=100)
    df = pd.read_csv(io.StringIO(csv_data))
    note(f"Shape: {df.shape}, memory: {df.memory_usage(deep=True).sum() / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    csv_out = df.to_csv(index=False)
    lines = csv_out.strip().split("\n")
    note(f"Output size: {len(csv_out) / 1024 / 1024:.1f} MB")
    note(f"Header: {lines[0]}")
    note(f"First row: {lines[1]}")
    note(f"Line count: {len(lines):,} (header + {len(lines) - 1:,} data rows)")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: df.to_csv(index=False),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, f"to_csv @ {args.rows:,} x {cols}")

    section("4", "Throughput")
    min_us = results["min"] / 1000.0
    output_mb = len(csv_out) / 1024 / 1024
    throughput_mbs = output_mb / (results["min"] / 1e9)
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Output size: {output_mb:.1f} MB")
    note(f"Throughput: {throughput_mbs:.0f} MB/s")
    print()

    section("5", "Read vs Write Comparison")
    t_read = benchmark(lambda: pd.read_csv(io.StringIO(csv_data)),
                       iterations=args.iterations)
    table_header()
    bench_row("read_csv()", t_read, f"input: {len(csv_data) / 1024 / 1024:.1f} MB")
    bench_row("to_csv()", results["min"], f"output: {output_mb:.1f} MB")
    if t_read > 0:
        note(f"Write/Read ratio: {results['min'] / t_read:.1f}x")
    print()

    section("6", "Impact of index= parameter")
    table_header()
    t_no_idx = results["min"]
    t_with_idx = benchmark(lambda: df.to_csv(index=True), iterations=args.iterations)
    bench_row("to_csv(index=False)", t_no_idx)
    bench_row("to_csv(index=True)", t_with_idx)
    print()

    note("Algorithm: Python-level cell formatting + string concatenation")
    note("SwiftPandas: column-wise pre-formatting + integer-style optimization")


if __name__ == "__main__":
    main()
