#!/usr/bin/env python3
"""
Benchmark 12: Series quantile(0.75)

Measures computing the 75th percentile of a numeric Series.

pandas: delegates to numpy.percentile(), which uses introselect (O(n) partial
sort) to find the kth element, then linear interpolation between neighbors.

SwiftPandas: O(n) quickselect with median-of-three pivot and raw-pointer inner
loop. For non-integer quantile positions, uses linear interpolation. Uses
ranged nthElement to find both neighbors efficiently.

What to look for:
  - Similar to median in cost — both are O(n) selection algorithms.
  - Random access pattern during partitioning limits cache efficiency.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 12: Series quantile(0.75)")
    print_header("Series quantile(0.75)", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=20)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    q25 = s.quantile(0.25)
    q50 = s.quantile(0.50)
    q75 = s.quantile(0.75)
    q90 = s.quantile(0.90)
    note(f"quantile(0.25) = {q25:.4f}")
    note(f"quantile(0.50) = {q50:.4f}  (= median)")
    note(f"quantile(0.75) = {q75:.4f}")
    note(f"quantile(0.90) = {q90:.4f}")
    note(f"median() check = {s.median():.4f}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.quantile(0.75),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "quantile(0.75)")

    section("4", "Different Quantile Positions")
    table_header()
    for q in [0.01, 0.10, 0.25, 0.50, 0.75, 0.90, 0.99]:
        t = benchmark(lambda q=q: s.quantile(q), iterations=args.iterations)
        bench_row(f"quantile({q})", t, f"= {s.quantile(q):.2f}")
    print()
    note("All positions should take similar time (same O(n) algorithm)")

    section("5", "quantile vs median vs sort")
    t_median = benchmark(lambda: s.median(), iterations=args.iterations)
    t_sort = benchmark(lambda: s.sort_values(), iterations=args.iterations)
    table_header()
    bench_row("quantile(0.75)", results["min"])
    bench_row("median()", t_median)
    bench_row("sort_values()", t_sort)
    if t_sort > 0:
        note(f"quantile is {t_sort / results['min']:.1f}x faster than full sort")
    print()

    note("Algorithm: O(n) introselect via NumPy (partial sort)")
    note("SwiftPandas: O(n) quickselect + linear interpolation")


if __name__ == "__main__":
    main()
