#!/usr/bin/env python3
"""
Benchmark 27: Merge (Inner Join) at 100K rows

Measures inner join (merge) on two DataFrames with string keys.

pandas: C-level hash join. Builds a hash table on the right-side keys,
then probes for each left-side row. Uses optimized Cython/C hash maps.

SwiftPandas: Dictionary<String, [Int]> hash index on right-side keys,
then probes for each left-side row. Metal GPU path available for >= 500K rows
(co-factorize -> GPU hash build -> GPU hash probe).

What to look for:
  - With ~50K distinct keys and 100K rows, many keys appear twice -> many-to-many.
  - Output size can be larger than either input due to key duplication.
  - Hash table construction dominates; probe is fast per row.
"""

from bench_utils import *


def main():
    args = parse_args("Benchmark 27: Merge Inner Join", default_rows=100_000)
    print_header("Merge (Inner Join)", args)

    section("1", f"Data Generation ({args.rows:,} rows per side)")
    rng = LCG(seed=80)
    keys = [f"k{rng.next_int(args.rows // 2)}" for _ in range(args.rows)]
    vals1 = [rng.next_float() * 100.0 for _ in range(args.rows)]
    vals2 = [rng.next_float() * 100.0 for _ in range(args.rows)]

    left = pd.DataFrame({"key": keys, "left_val": vals1})
    right_keys = keys.copy()
    np.random.seed(42)
    np.random.shuffle(right_keys)
    right = pd.DataFrame({"key": right_keys[:args.rows], "right_val": vals2})

    n_unique = left["key"].nunique()
    note(f"Left: {left.shape}, Right: {right.shape}")
    note(f"Unique keys: {n_unique:,} (of {args.rows:,})")
    note(f"Key duplication rate: {args.rows / n_unique:.1f}x")
    print()

    section("2", "Correctness Check")
    result = pd.merge(left, right, on="key", how="inner")
    note(f"Result shape: {result.shape}")
    note(f"Output rows: {len(result):,} (can exceed input due to many-to-many)")
    note(f"Output/input ratio: {len(result) / args.rows:.1f}x")
    print()

    section("3", f"Performance ({args.iterations} iterations, {args.warmup} warmup)")
    results = benchmark_detailed(
        lambda: pd.merge(left, right, on="key", how="inner"),
        iterations=args.iterations, warmup=args.warmup)
    print_detailed_results(results, f"inner join @ {args.rows:,}")

    section("4", "Join Type Comparison")
    table_header()
    for how in ["inner", "left", "right", "outer"]:
        t = benchmark(lambda h=how: pd.merge(left, right, on="key", how=h),
                      iterations=args.iterations)
        r = pd.merge(left, right, on="key", how=how)
        bench_row(f"{how} join", t, f"{len(r):,} rows")
    print()

    section("5", "Key Cardinality Impact")
    table_header()
    for key_frac in [0.1, 0.25, 0.5, 0.75, 1.0]:
        n_keys = max(1, int(args.rows * key_frac))
        rng2 = LCG(seed=80)
        k = [f"k{rng2.next_int(n_keys)}" for _ in range(args.rows)]
        v1 = [rng2.next_float() * 100.0 for _ in range(args.rows)]
        v2 = [rng2.next_float() * 100.0 for _ in range(args.rows)]
        l = pd.DataFrame({"key": k, "left_val": v1})
        r = pd.DataFrame({"key": k[:args.rows], "right_val": v2})
        res = pd.merge(l, r, on="key", how="inner")
        t = benchmark(lambda l=l, r=r: pd.merge(l, r, on="key", how="inner"),
                      iterations=args.iterations)
        bench_row(f"{n_keys:,} unique keys", t, f"output: {len(res):,} rows")
    print()
    note("More key duplication -> larger output -> slower")

    print()
    note("Algorithm: C-level hash join (build hash on right, probe from left)")
    note("SwiftPandas: Dictionary hash index + Metal GPU for >= 500K rows")


if __name__ == "__main__":
    main()
