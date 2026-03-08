#!/usr/bin/env python3
"""
Benchmark 13: Series cumsum()

Measures cumulative sum (prefix sum) of a numeric Series.

pandas: delegates to numpy.cumsum(), a single-pass O(n) accumulation in C.
The result is a new Series with the same length.

SwiftPandas: single-pass O(n) prefix sum. When the Series has allValid mask,
uses the Accelerate fast path.

What to look for:
  - Pure sequential operation — no SIMD benefit since each output depends
    on the previous output (data dependency chain).
  - Should be slightly slower than sum() due to the write-back of N values.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 13: Series cumsum()")
    print_header("Series cumsum()", args)

    section("1", f"Data Generation ({args.rows:,} elements)")
    data = random_doubles(args.rows, seed=20)
    s = pd.Series(data)
    note(f"Series dtype: {s.dtype}, memory: {s.nbytes / 1024 / 1024:.1f} MB")
    print()

    section("2", "Correctness Check")
    result = s.cumsum()
    expected = np.cumsum(data)
    note(f"First 5: {result.head().tolist()}")
    note(f"Expected: {expected[:5].tolist()}")
    note(f"Last value: {result.iloc[-1]:.4f} (should equal sum: {s.sum():.4f})")
    assert np.allclose(result.values, expected), "Mismatch!"
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(lambda: s.cumsum(),
                                 iterations=args.iterations,
                                 warmup=args.warmup)
    print_detailed_results(results, "Series.cumsum()")

    section("4", "cumsum vs sum vs mean")
    t_sum = benchmark(lambda: s.sum(), iterations=args.iterations)
    t_mean = benchmark(lambda: s.mean(), iterations=args.iterations)
    table_header()
    bench_row("sum()", t_sum, "single output value")
    bench_row("mean()", t_mean, "single output value")
    bench_row("cumsum()", results["min"], "N output values")
    if t_sum > 0:
        note(f"cumsum/sum ratio: {results['min'] / t_sum:.1f}x (writes N values vs 1)")
    print()

    note("Algorithm: O(n) prefix sum via NumPy C kernel")
    note("Note: inherently sequential due to data dependency chain")


if __name__ == "__main__":
    main()
