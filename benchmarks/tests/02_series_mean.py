#!/usr/bin/env python3
"""
Benchmark 02: Series mean()

Measures the time to compute the arithmetic mean of a numeric Series.

pandas: delegates to numpy.mean(), which computes sum/count in a single pass
over the contiguous float64 buffer. Uses pairwise summation for numerical
stability.

SwiftPandas: Accelerate vDSP_meanvD, a single-pass SIMD mean over contiguous
Double buffer. Returns NaN on empty input.

What to look for:
  - Nearly identical to sum() timing (mean = sum / count).
  - The division is negligible; the bottleneck is the reduction pass.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 02: Series mean()")
    print_header("Series mean()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=args.seed)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.mean()
    expected = np.mean(data)
    note(f"pd.Series.mean() = {result:.6f}")
    note(f"np.mean(data)    = {expected:.6f}")
    note(f"Difference:        {abs(result - expected):.2e}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.mean(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series.mean()")

    section("4", "Throughput Analysis")
    min_us = results["min"] / 1000.0
    throughput_gbs = (args.rows * 8) / (results["min"] / 1e9) / 1e9
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Throughput: {throughput_gbs:.1f} GB/s")
    note(f"Elements/\u00b5s: {args.rows / min_us:,.0f}")
    print()

    section("5", "Mean vs Sum Comparison")
    t_sum = benchmark_detailed(lambda: s.sum(),
                               iterations=args.iterations,
                               warmup=args.warmup)
    table_header()
    bench_row("sum()", t_sum["min"])
    bench_row("mean()", results["min"])
    overhead = (results["min"] - t_sum["min"]) / t_sum["min"] * 100
    note(f"mean() overhead vs sum(): {overhead:+.1f}%")
    print()

    note("Algorithm: pairwise summation + division via NumPy C kernel")


if __name__ == "__main__":
    main()
