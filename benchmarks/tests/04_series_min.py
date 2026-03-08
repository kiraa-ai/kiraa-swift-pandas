#!/usr/bin/env python3
"""
Benchmark 04: Series min()

Measures the time to find the minimum value in a numeric Series.

pandas: delegates to numpy.min(), a single-pass reduction with SIMD.

SwiftPandas: Accelerate vDSP_minvD, single-pass SIMD reduction.

What to look for:
  - Should be ~same speed as sum() — both are single-pass reductions.
  - min() cannot use pairwise summation tricks, but the single-pass
    comparison is equally memory-bandwidth-bound.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 04: Series min()")
    print_header("Series min()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=args.seed)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.min()
    expected = np.min(data)
    note(f"pd.Series.min() = {result:.6f}")
    note(f"np.min(data)    = {expected:.6f}")
    note(f"Match: {result == expected}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.min(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series.min()")

    section("4", "min vs max vs sum Comparison")
    t_max = benchmark_detailed(lambda: s.max(),
                               iterations=args.iterations,
                               warmup=args.warmup)
    t_sum = benchmark_detailed(lambda: s.sum(),
                               iterations=args.iterations,
                               warmup=args.warmup)
    table_header()
    bench_row("min()", results["min"])
    bench_row("max()", t_max["min"])
    bench_row("sum()", t_sum["min"])
    print()

    note("Algorithm: single-pass comparison reduction via NumPy C kernel (SIMD/vDSP)")


if __name__ == "__main__":
    main()
