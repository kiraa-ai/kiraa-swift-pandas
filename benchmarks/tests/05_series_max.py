#!/usr/bin/env python3
"""
Benchmark 05: Series max()

Measures the time to find the maximum value in a numeric Series.

pandas: delegates to numpy.max(), single-pass SIMD reduction.
SwiftPandas: Accelerate vDSP_maxvD, single-pass SIMD reduction.

Identical algorithm to min() — a single-pass comparison scan.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 05: Series max()")
    print_header("Series max()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=args.seed)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.max()
    expected = np.max(data)
    note(f"pd.Series.max() = {result:.6f}")
    note(f"np.max(data)    = {expected:.6f}")
    note(f"Match: {result == expected}")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.max(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series.max()")

    section("4", "All Single-Pass Reductions Compared")
    ops = {"sum": lambda: s.sum(), "mean": lambda: s.mean(),
           "min": lambda: s.min(), "max": lambda: s.max()}
    table_header()
    for name, fn in ops.items():
        t = benchmark(fn, iterations=args.iterations)
        bench_row(f"{name}()", t)
    print()

    note("Algorithm: single-pass comparison reduction via NumPy C kernel (SIMD/vDSP)")


if __name__ == "__main__":
    main()
