#!/usr/bin/env python3
"""
Benchmark 08: Series * Series (element-wise multiplication)

Measures element-wise multiplication of two equal-length numeric Series.

pandas: numpy array multiplication with SIMD.
SwiftPandas: Accelerate vDSP_vmulD on contiguous Double buffers.

Identical performance characteristics to addition — same memory access
pattern (2 reads + 1 write) and same SIMD pipeline utilization.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 08: Series * Series")
    print_header("Series * Series", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    d1 = random_doubles(args.rows, seed=1)
    d2 = random_doubles(args.rows, seed=2)
    s1 = pd.Series(d1)
    s2 = pd.Series(d2)
    note(f"Two Series, each {s1.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s1 * s2
    expected = np.array(d1) * np.array(d2)
    note(f"First 5: {result.head().tolist()}")
    assert np.allclose(result.values, expected), "Mismatch!"
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s1 * s2,
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series * Series")

    section("4", "All Element-wise Ops Compared")
    ops = {
        "add (+)": lambda: s1 + s2,
        "subtract (-)": lambda: s1 - s2,
        "multiply (*)": lambda: s1 * s2,
        "divide (/)": lambda: s1 / s2,
    }
    table_header()
    for name, fn in ops.items():
        t = benchmark(fn, iterations=args.iterations)
        bench_row(name, t)
    print()

    note("Algorithm: SIMD vectorized element-wise multiply via NumPy C kernel")


if __name__ == "__main__":
    main()
