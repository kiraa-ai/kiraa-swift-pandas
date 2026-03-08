#!/usr/bin/env python3
"""
Benchmark 06: Series median()

Measures median computation on a numeric Series.

pandas: uses numpy.percentile(50), which internally does an O(n) introselect
(partial sort) to find the middle element(s). For even-length arrays, it
averages the two middle elements.

SwiftPandas: O(n) quickselect with median-of-three pivot selection and a
raw-pointer inner loop. For even-length arrays, finds the kth element then
scans the left partition for the maximum (avoiding a second quickselect call).

What to look for:
  - Much slower than sum/mean since quickselect/introselect has poor cache
    locality (random access pattern during partitioning).
  - Both are O(n) average case but with high constant factors.
  - The raw-pointer optimization in Swift can give a significant edge.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 06: Series median()")
    print_header("Series median()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=args.seed)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.median()
    expected = np.median(data)
    note(f"pd.Series.median() = {result:.6f}")
    note(f"np.median(data)    = {expected:.6f}")
    note(f"Difference:          {abs(result - expected):.2e}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.median(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series.median()")

    section("4", "median vs Other Aggregations")
    t_sum = benchmark(lambda: s.sum(), iterations=args.iterations)
    t_mean = benchmark(lambda: s.mean(), iterations=args.iterations)
    t_std = benchmark(lambda: s.std(), iterations=args.iterations)
    table_header()
    bench_row("sum()", t_sum)
    bench_row("mean()", t_mean)
    bench_row("std()", t_std)
    bench_row("median()", results["min"])
    ratio = results["min"] / t_sum if t_sum > 0 else 0
    note(f"median/sum ratio: {ratio:.1f}x")
    print()

    section("5", "Scaling")
    if args.rows >= 100_000:
        sizes = [10_000, 100_000, 500_000, args.rows]
        table_header()
        for n in sizes:
            if n > args.rows:
                continue
            d = random_doubles(n, seed=args.seed)
            ss = pd.Series(d)
            t = benchmark(lambda ss=ss: ss.median(), iterations=args.iterations)
            bench_row(f"median() @ {n:,}", t)
    print()

    note("Algorithm: O(n) introselect (partial sort) via NumPy")
    note("SwiftPandas: O(n) quickselect with median-of-three pivot + raw pointers")


if __name__ == "__main__":
    main()
