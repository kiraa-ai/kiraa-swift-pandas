#!/usr/bin/env python3
"""
Benchmark 09: Series + scalar

Measures adding a scalar value to every element of a numeric Series.

pandas: numpy broadcasting — the scalar is broadcast to match the Series shape,
then element-wise addition is performed via SIMD.

SwiftPandas: Accelerate vDSP_vsaddD (vector-scalar add). When the Series has
allValid mask, this takes the fast Accelerate path directly.

What to look for:
  - Faster than Series+Series because only 1 array read + 1 write (16 bytes/element).
  - The scalar lives in a register, no second array fetch needed.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 09: Series + scalar")
    print_header("Series + scalar", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=1)
    s = pd.Series(data)
    scalar = 42.0
    note(f"Series: {s.nbytes / 1024 / 1024:.1f} MB, scalar: {scalar}")
    print()

    section("2", "Correctness Check")
    result = s + scalar
    expected = np.array(data) + scalar
    note(f"First 5: {result.head().tolist()}")
    assert np.allclose(result.values, expected), "Mismatch!"
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s + scalar,
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series + scalar")

    section("4", "Scalar Ops Compared")
    table_header()
    for name, fn in [
        ("+ scalar", lambda: s + scalar),
        ("- scalar", lambda: s - scalar),
        ("* scalar", lambda: s * 2.5),
        ("/ scalar", lambda: s / 3.0),
    ]:
        t = benchmark(fn, iterations=args.iterations)
        bench_row(f"Series {name}", t)
    print()

    section("5", "Scalar vs Element-wise")
    d2 = random_doubles(args.rows, seed=2)
    s2 = pd.Series(d2)
    t_elem = benchmark(lambda: s + s2, iterations=args.iterations)
    table_header()
    bench_row("Series + Series", t_elem)
    bench_row("Series + scalar", results["min"])
    if t_elem > 0:
        note(f"Scalar is {t_elem / results['min']:.2f}x faster (fewer memory reads)")
    print()

    note("Algorithm: NumPy broadcast + SIMD vectorized add")
    note("SwiftPandas: Accelerate vDSP_vsaddD (vector-scalar add)")


if __name__ == "__main__":
    main()
