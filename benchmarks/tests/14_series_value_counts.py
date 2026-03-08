#!/usr/bin/env python3
"""
Benchmark 14: Series value_counts()

Measures frequency counting of all unique values in a numeric Series.

pandas: uses a Cython-accelerated hash table to count occurrences, then
sorts by frequency (descending). For float64 data, uses kh_float64 hash map.

SwiftPandas: hash-based frequency counting using a dictionary. The result is
sorted by frequency descending using an indirect sort. For float64 data with
many unique values, the hash table dominates the cost.

What to look for:
  - Hash table operations are random-access and cache-unfriendly.
  - With 1M random doubles, most values are unique -> large hash table.
  - Much slower than sum/mean due to hash table overhead.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 14: Series value_counts()")
    print_header("Series value_counts()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=20)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    note(f"Unique values: {s.nunique():,}")
    print()

    section("2", "Correctness Check")
    result = s.value_counts()
    note(f"Top 5 values by frequency:")
    for val, count in result.head().items():
        note(f"  {val:.4f}: {count}")
    note(f"Total unique: {len(result):,}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.value_counts(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "value_counts() — float64, many unique")

    section("4", "Impact of Cardinality")
    # Low cardinality: integer-like data with few unique values
    rng = LCG(seed=args.seed)
    low_card = pd.Series([float(rng.next_int(100)) for _ in range(args.rows)])
    med_card = pd.Series([float(rng.next_int(10_000)) for _ in range(args.rows)])

    table_header()
    t_low = benchmark(lambda: low_card.value_counts(), iterations=args.iterations)
    bench_row(f"100 unique vals", t_low, f"cardinality ratio: {100/args.rows:.6f}")

    t_med = benchmark(lambda: med_card.value_counts(), iterations=args.iterations)
    bench_row(f"10K unique vals", t_med, f"cardinality ratio: {10000/args.rows:.4f}")

    bench_row(f"{s.nunique():,} unique vals", results["min"], "high cardinality (floats)")
    print()

    note("Algorithm: Cython hash table + frequency sort")
    note("SwiftPandas: Dictionary frequency table + indirect sort")


if __name__ == "__main__":
    main()
