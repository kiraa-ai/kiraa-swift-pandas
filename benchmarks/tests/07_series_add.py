#!/usr/bin/env python3
"""
Benchmark 07: Series + Series (element-wise addition)

Measures element-wise addition of two equal-length numeric Series.

pandas: delegates to numpy array addition, which uses SIMD vectorized loops
in C. The result is a new Series with a new backing array.

SwiftPandas: Accelerate vDSP_vaddD on contiguous Double buffers. Allocates a
new NullableArray for the result. When both Series have allValid masks, the
fast path skips per-element NA checks.

What to look for:
  - Memory-bandwidth-bound: reads 2 arrays, writes 1 array (24 bytes/element).
  - Allocation cost for the result array is included in timing.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 07: Series + Series")
    print_header("Series + Series", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    d1 = random_doubles(args.rows, seed=1)
    d2 = random_doubles(args.rows, seed=2)
    s1 = pd.Series(d1)
    s2 = pd.Series(d2)
    note(f"Two Series, each {s1.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s1 + s2
    expected = np.array(d1) + np.array(d2)
    note(f"First 5: {result.head().tolist()}")
    note(f"Expected: {expected[:5].tolist()}")
    assert np.allclose(result.values, expected), "Mismatch!"
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s1 + s2,
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series + Series")

    section("4", "Throughput")
    min_us = results["min"] / 1000.0
    bytes_processed = args.rows * 8 * 3  # 2 reads + 1 write
    throughput_gbs = bytes_processed / (results["min"] / 1e9) / 1e9
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Throughput: {throughput_gbs:.1f} GB/s (2 reads + 1 write)")
    print()

    note("Algorithm: SIMD vectorized element-wise add via NumPy C kernel")


if __name__ == "__main__":
    main()
