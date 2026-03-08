#!/usr/bin/env python3
"""
Benchmark 03: Series std()

Measures standard deviation computation on a numeric Series.

pandas: uses a two-pass algorithm via numpy. Pass 1: compute mean.
Pass 2: compute sum of squared differences. Then sqrt(sos / (n-1)) for
sample std (ddof=1, the pandas default).

SwiftPandas: Accelerate two-pass — vDSP_meanvD then vDSP_vsaddD (subtract mean)
+ vDSP_svesqD (sum of squares). The two-pass approach is numerically stable
compared to the naive E[x^2] - E[x]^2 formula.

What to look for:
  - ~2x the time of sum() since it requires two passes over the data.
  - pandas default ddof=1 (sample std); SwiftPandas matches this.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 03: Series std()")
    print_header("Series std()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=args.seed)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result_ddof1 = s.std(ddof=1)
    result_ddof0 = s.std(ddof=0)
    np_std = np.std(data, ddof=1)
    note(f"pd.Series.std(ddof=1) = {result_ddof1:.6f}  (sample std, default)")
    note(f"pd.Series.std(ddof=0) = {result_ddof0:.6f}  (population std)")
    note(f"np.std(ddof=1)        = {np_std:.6f}")
    note(f"Difference:             {abs(result_ddof1 - np_std):.2e}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")

    sub("std(ddof=1) — sample standard deviation (default)")
    results = benchmark_detailed(lambda: s.std(ddof=1),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results)

    sub("std(ddof=0) — population standard deviation")
    results_pop = benchmark_detailed(lambda: s.std(ddof=0),
                                     iterations=args.iterations,
                                     warmup=args.warmup)
    print_detailed_results(results_pop)

    section("4", "Comparison with sum/mean")
    t_sum = benchmark(lambda: s.sum(), iterations=args.iterations)
    t_mean = benchmark(lambda: s.mean(), iterations=args.iterations)
    table_header()
    bench_row("sum()", t_sum)
    bench_row("mean()", t_mean)
    bench_row("std(ddof=1)", results["min"])
    bench_row("std(ddof=0)", results_pop["min"])
    ratio = results["min"] / t_sum if t_sum > 0 else 0
    note(f"std/sum ratio: {ratio:.1f}x (expected ~2x for two-pass)")
    print()

    note("Algorithm: two-pass (mean, then sum-of-squared-differences) via NumPy")


if __name__ == "__main__":
    main()
