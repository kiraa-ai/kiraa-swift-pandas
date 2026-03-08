#!/usr/bin/env python3
"""
Benchmark 11: Series sort_values() at 1M elements

Measures sorting a numeric Series in ascending order.

pandas: uses numpy.argsort() (introsort or radixsort in C) to compute a
permutation, then fancy-indexes the values. Returns a new Series with
reindexed labels.

SwiftPandas: stdlib TimSort on an enumerated array to produce a permutation,
then rebuilds a new Series with reordered values and index.

What to look for:
  - O(n log n) comparison sort dominates the cost.
  - Random data is the worst case for TimSort (no natural runs).
  - Pre-sorted and reverse-sorted data should be dramatically faster with TimSort.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 11: Series sort_values()")
    print_header("Series sort_values()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=11)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.sort_values()
    note(f"First 5 sorted: {result.head().tolist()}")
    note(f"Last 5 sorted: {result.tail().tolist()}")
    assert result.is_monotonic_increasing
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.sort_values(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "sort_values() — random data")

    section("4", "Sort Order Comparison")
    s_sorted = s.sort_values()
    s_reversed = s.sort_values(ascending=False)

    table_header()
    t_random = results["min"]
    bench_row("random data", t_random)

    t_sorted = benchmark(lambda: s_sorted.sort_values(), iterations=args.iterations)
    bench_row("already sorted", t_sorted, "best case for TimSort")

    t_rev = benchmark(lambda: s_reversed.sort_values(), iterations=args.iterations)
    bench_row("reverse sorted", t_rev)

    t_desc = benchmark(lambda: s.sort_values(ascending=False), iterations=args.iterations)
    bench_row("random desc", t_desc)
    print()

    section("5", "Scaling")
    sizes = [10_000, 100_000, 500_000, args.rows]
    table_header()
    for n in sizes:
        if n > args.rows:
            continue
        d = random_doubles(n, seed=11)
        ss = pd.Series(d)
        t = benchmark(lambda ss=ss: ss.sort_values(), iterations=args.iterations)
        bench_row(f"sort @ {n:,}", t)
        if n > 10_000:
            # Show n*log(n) scaling factor
            prev_n = sizes[sizes.index(n) - 1]
            expected_ratio = (n * np.log2(n)) / (prev_n * np.log2(prev_n))
            note(f"  Expected O(n log n) ratio vs previous: {expected_ratio:.1f}x")
    print()

    note("Algorithm: numpy.argsort (introsort/radixsort in C)")
    note("SwiftPandas: stdlib TimSort + permutation rebuild")


if __name__ == "__main__":
    main()
