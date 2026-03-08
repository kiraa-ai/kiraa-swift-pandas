#!/usr/bin/env python3
"""
Benchmark 10: Series * scalar

Measures multiplying every element of a numeric Series by a scalar.

pandas: numpy broadcasting + SIMD multiply.
SwiftPandas: Accelerate vDSP_vsmulD (vector-scalar multiply).

Same characteristics as Series + scalar — single array read + write.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 10: Series * scalar")
    print_header("Series * scalar", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=1)
    s = pd.Series(data)
    scalar = 2.5
    note(f"Series: {s.nbytes / 1024 / 1024:.1f} MB, scalar: {scalar}")
    print()

    section("2", "Correctness Check")
    result = s * scalar
    expected = np.array(data) * scalar
    note(f"First 5: {result.head().tolist()}")
    assert np.allclose(result.values, expected), "Mismatch!"
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s * scalar,
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series * scalar")

    section("4", "Throughput")
    min_us = results["min"] / 1000.0
    bytes_processed = args.rows * 8 * 2  # 1 read + 1 write
    throughput_gbs = bytes_processed / (results["min"] / 1e9) / 1e9
    note(f"Best time: {min_us:,.0f} \u00b5s")
    note(f"Throughput: {throughput_gbs:.1f} GB/s (1 read + 1 write)")
    print()

    note("Algorithm: NumPy broadcast + SIMD vectorized multiply")
    note("SwiftPandas: Accelerate vDSP_vsmulD")


if __name__ == "__main__":
    main()
