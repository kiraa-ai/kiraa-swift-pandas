#!/usr/bin/env python3
"""
Benchmark 01: Series sum()

Measures the time to compute the sum of a numeric Series with N elements.

pandas implementation: delegates to numpy.sum(), which uses pairwise summation
with SIMD vectorization (vDSP on Apple Silicon). This is a single pass over a
contiguous float64 buffer.

SwiftPandas implementation: Accelerate vDSP_sveD on contiguous Double buffer.
Single-pass pairwise summation, same algorithm family as NumPy.

What to look for:
  - Both should be memory-bandwidth-bound at large N.
  - At 1M doubles (8MB), this fits in L3 cache on most machines.
  - Variance between runs should be very low (<5%).
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 01: Series sum()")
    print_header("Series sum()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=args.seed)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, shape: {s.shape}")
    note(f"Memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.sum()
    expected_np = np.sum(data)
    note(f"pd.Series.sum()  = {result:.6f}")
    note(f"np.sum(data)     = {expected_np:.6f}")
    note(f"Difference:        {abs(result - expected_np):.2e}")
    assert abs(result - expected_np) < 1e-6, "Sum mismatch!"
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")

    results = benchmark_detailed(lambda: s.sum(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series.sum()")

    section("4", "Throughput Analysis")
    min_us = results["min"] / 1000.0
    throughput_gbs = (args.rows * 8) / (results["min"] / 1e9) / 1e9
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Throughput: {throughput_gbs:.1f} GB/s")
    note(f"Elements/\u00b5s: {args.rows / min_us:,.0f}")
    print()

    section("5", "Scaling (if > 100K rows)")
    if args.rows >= 100_000:
        sizes = [10_000, 100_000, args.rows]
        if args.rows >= 1_000_000:
            sizes = [10_000, 100_000, 500_000, args.rows]
        table_header()
        for n in sizes:
            d = random_doubles(n, seed=args.seed)
            ss = pd.Series(d)
            t = benchmark(lambda ss=ss: ss.sum(), iterations=args.iterations)
            bench_row(f"sum() @ {n:,}", t, f"{n * 8 / 1024:.0f} KB")
    print()

    note("Algorithm: pairwise summation via NumPy C kernel (SIMD/vDSP on Apple)")


if __name__ == "__main__":
    main()
