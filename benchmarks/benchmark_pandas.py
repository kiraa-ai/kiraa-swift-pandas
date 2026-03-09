#!/usr/bin/env python3
"""
SwiftPandas vs Python pandas — Side-by-Side Benchmark Suite

Runs identical operations in Python pandas with detailed output,
then invokes the SwiftPandas benchmark tests and displays both results.

Usage:
    python3 benchmark_pandas.py

Requirements:
    pip install pandas numpy
"""

import sys
import time
import io
import os
import subprocess
import platform

# The project root has a 'pandas/' directory (CPython pandas source tree) that
# shadows the installed pandas package.  Remove it from sys.path so we import
# the real, installed pandas.
_project_dir = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p) != _project_dir]

import re
import warnings
import numpy as np
import pandas as pd

# Suppress numpy overflow warnings from the LCG (intentional wrapping arithmetic)
warnings.filterwarnings("ignore", category=RuntimeWarning, message="overflow")

# ═══════════════════════════════════════════════════════════════════════════════
# Formatting
# ═══════════════════════════════════════════════════════════════════════════════

W = 80
DIVIDER = "\u2550" * W
THIN = "\u2500" * W

def banner(title):
    pad = max(0, W - len(title) - 4)
    left = pad // 2
    right = pad - left
    print()
    print("\u2554" + "\u2550" * W + "\u2557")
    print("\u2551" + " " * left + "  " + title + " " * right + "  \u2551")
    print("\u255A" + "\u2550" * W + "\u255D")

def section(num, title):
    inner = W - 4
    label = f"  {num}. {title}"
    pad = max(0, inner - len(label))
    print()
    print("  \u250C" + "\u2500" * inner + "\u2510")
    print("  \u2502" + label + " " * pad + "\u2502")
    print("  \u2514" + "\u2500" * inner + "\u2518")

def sub(title):
    print(f"\n  \u25B6 {title}")
    print("  " + "\u2500" * (W - 4))

def note(text):
    print(f"    \u2502 {text}")

def table_header():
    op = "Operation".ljust(26)
    py = "Python (\u00b5s)".ljust(20)
    extra = "Details"
    print(f"    \u25B8 {op} {py} {extra}")
    print("    " + "\u2500" * (W - 8))

def bench_row(op, ns, detail=""):
    name = op.ljust(26)
    t = format_us(ns).ljust(20)
    print(f"      {name} {t} {detail}")

def format_us(ns):
    """Format nanoseconds as microseconds with no decimal places."""
    us = ns / 1000.0
    return f"{us:,.0f} \u00b5s"

def benchmark(fn, iterations=3):
    """Run fn `iterations` times, return minimum time in nanoseconds."""
    best = float("inf")
    for _ in range(iterations):
        start = time.perf_counter_ns()
        fn()
        elapsed = time.perf_counter_ns() - start
        best = min(best, elapsed)
    return best

def pass_fail(label, passed, detail=""):
    icon = "\u2705" if passed else "\u274C"
    msg = f"  {icon}  {label}"
    if detail:
        msg += f"  ({detail})"
    print(msg)

# ═══════════════════════════════════════════════════════════════════════════════
# Deterministic data generation (same LCG as SwiftPandas)
# ═══════════════════════════════════════════════════════════════════════════════

class LCG:
    """Linear congruential generator matching SwiftPandas BenchmarkTests.LCG."""
    def __init__(self, seed=42):
        self.state = np.uint64(seed)

    def next_float(self):
        self.state = np.uint64(
            np.uint64(self.state) * np.uint64(6364136223846793005)
            + np.uint64(1442695040888963407)
        )
        return float(self.state >> np.uint64(11)) / float(np.uint64(1) << np.uint64(53))

    def next_int(self, bound):
        self.state = np.uint64(
            np.uint64(self.state) * np.uint64(6364136223846793005)
            + np.uint64(1442695040888963407)
        )
        return int(self.state >> np.uint64(33)) % bound

def random_doubles(count, seed=42):
    rng = LCG(seed)
    return [rng.next_float() * 1000.0 for _ in range(count)]

def numeric_dataframe(rows, cols, seed=42):
    rng = LCG(seed)
    data = {}
    for c in range(cols):
        data[f"col{c}"] = [rng.next_float() * 1000.0 for _ in range(rows)]
    return pd.DataFrame(data)

def groupable_dataframe(rows, n_groups, seed=42):
    rng = LCG(seed)
    groups = [f"g{rng.next_int(n_groups)}" for _ in range(rows)]
    values1 = [rng.next_float() * 1000.0 for _ in range(rows)]
    values2 = [rng.next_float() * 500.0 for _ in range(rows)]
    return pd.DataFrame({"group": groups, "value1": values1, "value2": values2})

def csv_string(rows, cols, seed=42):
    rng = LCG(seed)
    header = ",".join(f"col{c}" for c in range(cols))
    lines = [header]
    for _ in range(rows):
        row = ",".join(f"{rng.next_float() * 1000.0:.2f}" for _ in range(cols))
        lines.append(row)
    return "\n".join(lines)

# ═══════════════════════════════════════════════════════════════════════════════
# Correctness Tests
# ═══════════════════════════════════════════════════════════════════════════════

test_results = []

def run_test(name, fn):
    """Run a test function, track pass/fail."""
    try:
        fn()
        test_results.append((name, True, ""))
        return True
    except AssertionError as e:
        test_results.append((name, False, str(e)))
        return False
    except Exception as e:
        test_results.append((name, False, f"Exception: {e}"))
        return False


# ═══════════════════════════════════════════════════════════════════════════════
# PART 1: Python pandas Detailed Tests
# ═══════════════════════════════════════════════════════════════════════════════

def run_python_tests():
    banner("PYTHON PANDAS — DETAILED TEST SUITE")
    print()
    note(f"Python {platform.python_version()} \u2022 pandas {pd.__version__} \u2022 NumPy {np.__version__}")
    note(f"Platform: {platform.machine()} {platform.system()} {platform.release()}")
    print()

    # ── Stage 1: Series Creation & Properties ─────────────────────────
    section("1", "Series — Creation & Properties")
    print()

    def test_series_creation():
        s = pd.Series([1.0, 2.0, 3.0, 4.0, 5.0])
        assert len(s) == 5
        assert s.dtype == np.float64
        print(f"    pd.Series([1.0, 2.0, 3.0, 4.0, 5.0])")
        print(f"    dtype={s.dtype}, len={len(s)}")
        print(f"    {s.values}")
    run_test("Series creation", test_series_creation)

    def test_series_from_dict():
        s = pd.Series({"a": 1.0, "b": 2.0, "c": 3.0})
        assert s["a"] == 1.0
        assert len(s) == 3
        print(f"    pd.Series({{'a': 1.0, 'b': 2.0, 'c': 3.0}})")
        print(f"    index={list(s.index)}, values={list(s.values)}")
    run_test("Series from dict", test_series_from_dict)

    def test_series_na():
        s = pd.Series([1.0, np.nan, 3.0, np.nan, 5.0])
        assert s.isna().sum() == 2
        assert s.dropna().tolist() == [1.0, 3.0, 5.0]
        filled = s.fillna(0.0)
        assert filled.tolist() == [1.0, 0.0, 3.0, 0.0, 5.0]
        print(f"    Series with NA: {s.tolist()}")
        print(f"    isNA count: {s.isna().sum()}, dropNA: {s.dropna().tolist()}")
        print(f"    fillNA(0): {filled.tolist()}")
    run_test("Series NA handling", test_series_na)

    # ── Stage 2: Series Aggregation ───────────────────────────────────
    section("2", "Series — Aggregation")
    print()

    def test_series_aggregation():
        s = pd.Series([10.0, 20.0, 30.0, 40.0, 50.0])
        results = {
            "sum": s.sum(),
            "mean": s.mean(),
            "std": s.std(),
            "min": s.min(),
            "max": s.max(),
            "median": s.median(),
        }
        assert results["sum"] == 150.0
        assert results["mean"] == 30.0
        assert results["min"] == 10.0
        assert results["max"] == 50.0
        assert results["median"] == 30.0
        for k, v in results.items():
            print(f"    {k:>8s}() = {v:.4f}")
    run_test("Series aggregation", test_series_aggregation)

    def test_series_quantile():
        s = pd.Series(range(100), dtype=float)
        q25 = s.quantile(0.25)
        q75 = s.quantile(0.75)
        assert 24 <= q25 <= 25
        assert 74 <= q75 <= 75
        print(f"    quantile(0.25) = {q25}, quantile(0.75) = {q75}")
    run_test("Series quantile", test_series_quantile)

    def test_series_cumsum():
        s = pd.Series([1.0, 2.0, 3.0, 4.0, 5.0])
        cs = s.cumsum()
        assert cs.tolist() == [1.0, 3.0, 6.0, 10.0, 15.0]
        print(f"    cumsum([1,2,3,4,5]) = {cs.tolist()}")
    run_test("Series cumsum", test_series_cumsum)

    def test_series_value_counts():
        s = pd.Series(["a", "b", "a", "c", "b", "a"])
        vc = s.value_counts()
        assert vc["a"] == 3
        assert vc["b"] == 2
        assert vc["c"] == 1
        print(f"    value_counts: a={vc['a']}, b={vc['b']}, c={vc['c']}")
    run_test("Series value_counts", test_series_value_counts)

    # ── Stage 3: Series Arithmetic & Comparison ───────────────────────
    section("3", "Series — Arithmetic & Comparison")
    print()

    def test_series_arithmetic():
        a = pd.Series([1.0, 2.0, 3.0])
        b = pd.Series([10.0, 20.0, 30.0])
        print(f"    a + b = {(a + b).tolist()}")
        print(f"    a * b = {(a * b).tolist()}")
        print(f"    a + 10 = {(a + 10).tolist()}")
        print(f"    a * 2.5 = {(a * 2.5).tolist()}")
        assert (a + b).tolist() == [11.0, 22.0, 33.0]
        assert (a * 2.5).tolist() == [2.5, 5.0, 7.5]
    run_test("Series arithmetic", test_series_arithmetic)

    def test_series_comparison():
        s = pd.Series([1.0, 2.0, 3.0, 4.0, 5.0])
        gt3 = s > 3.0
        assert gt3.tolist() == [False, False, False, True, True]
        le3 = s <= 3.0
        assert le3.tolist() == [True, True, True, False, False]
        print(f"    s > 3.0: {gt3.tolist()}")
        print(f"    s <= 3.0: {le3.tolist()}")
    run_test("Series comparison", test_series_comparison)

    def test_series_sorting():
        s = pd.Series([3.0, 1.0, 4.0, 1.0, 5.0])
        sorted_s = s.sort_values()
        assert sorted_s.values.tolist() == [1.0, 1.0, 3.0, 4.0, 5.0]
        print(f"    sort_values: {sorted_s.values.tolist()}")
    run_test("Series sorting", test_series_sorting)

    # ── Stage 4: DataFrame Creation ───────────────────────────────────
    section("4", "DataFrame — Creation & Structure")
    print()

    def test_df_creation():
        df = pd.DataFrame({"a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]})
        assert df.shape == (3, 2)
        assert list(df.columns) == ["a", "b"]
        print(f"    shape: {df.shape}")
        print(f"    columns: {list(df.columns)}")
        print(f"    dtypes:\n{df.dtypes.to_string()}")
        print(f"\n{df.to_string()}")
    run_test("DataFrame creation", test_df_creation)

    def test_df_column_access():
        df = pd.DataFrame({"x": [1.0, 2.0], "y": [3.0, 4.0], "z": [5.0, 6.0]})
        assert df["x"].tolist() == [1.0, 2.0]
        subset = df[["x", "z"]]
        assert list(subset.columns) == ["x", "z"]
        print(f"    df['x'] = {df['x'].tolist()}")
        print(f"    df[['x','z']] columns = {list(subset.columns)}")
    run_test("DataFrame column access", test_df_column_access)

    def test_df_head_tail():
        df = pd.DataFrame({"v": list(range(10))})
        assert len(df.head(3)) == 3
        assert len(df.tail(2)) == 2
        print(f"    head(3): {df.head(3)['v'].tolist()}")
        print(f"    tail(2): {df.tail(2)['v'].tolist()}")
    run_test("DataFrame head/tail", test_df_head_tail)

    # ── Stage 5: DataFrame Filtering & Sorting ────────────────────────
    section("5", "DataFrame — Filtering & Sorting")
    print()

    def test_df_boolean_filter():
        df = pd.DataFrame({"a": [1.0, 2.0, 3.0, 4.0, 5.0], "b": [10.0, 20.0, 30.0, 40.0, 50.0]})
        filtered = df[df["a"] > 3.0]
        assert len(filtered) == 2
        assert filtered["a"].tolist() == [4.0, 5.0]
        print(f"    df[df['a'] > 3.0]:")
        print(f"    a={filtered['a'].tolist()}, b={filtered['b'].tolist()}")
    run_test("DataFrame boolean filter", test_df_boolean_filter)

    def test_df_sort():
        df = pd.DataFrame({"name": ["c", "a", "b"], "val": [3.0, 1.0, 2.0]})
        sorted_df = df.sort_values("val")
        assert sorted_df["name"].tolist() == ["a", "b", "c"]
        print(f"    sort_values('val'): names={sorted_df['name'].tolist()}")
    run_test("DataFrame sorting", test_df_sort)

    def test_df_multi_sort():
        df = pd.DataFrame({
            "dept": ["A", "B", "A", "B"],
            "score": [90, 85, 90, 95],
            "name": ["Alice", "Bob", "Charlie", "Diana"]
        })
        sorted_df = df.sort_values(["dept", "score"], ascending=[True, False])
        print(f"    Multi-sort (dept asc, score desc):")
        print(f"    names: {sorted_df['name'].tolist()}")
        assert sorted_df["name"].tolist()[0] in ("Alice", "Charlie")
    run_test("DataFrame multi-column sort", test_df_multi_sort)

    # ── Stage 6: DataFrame Aggregation ────────────────────────────────
    section("6", "DataFrame — Aggregation")
    print()

    def test_df_aggregation():
        df = pd.DataFrame({"a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]})
        print(f"    sum:  a={df['a'].sum()}, b={df['b'].sum()}")
        print(f"    mean: a={df['a'].mean()}, b={df['b'].mean()}")
        print(f"    std:  a={df['a'].std():.4f}, b={df['b'].std():.4f}")
        assert df["a"].sum() == 6.0
        assert df["b"].mean() == 5.0
    run_test("DataFrame aggregation", test_df_aggregation)

    def test_df_describe():
        df = pd.DataFrame({"v": [1.0, 2.0, 3.0, 4.0, 5.0]})
        desc = df.describe()
        assert desc.loc["count", "v"] == 5.0
        assert desc.loc["mean", "v"] == 3.0
        print(f"    describe():")
        print(f"    {desc.to_string()}")
    run_test("DataFrame describe", test_df_describe)

    # ── Stage 7: GroupBy ──────────────────────────────────────────────
    section("7", "GroupBy — Split-Apply-Combine")
    print()

    def test_groupby_sum():
        df = pd.DataFrame({
            "city": ["NYC", "LA", "NYC", "LA", "NYC"],
            "sales": [100.0, 200.0, 150.0, 250.0, 300.0]
        })
        result = df.groupby("city")["sales"].sum()
        assert result["NYC"] == 550.0
        assert result["LA"] == 450.0
        print(f"    groupby('city').sum():")
        print(f"    NYC={result['NYC']}, LA={result['LA']}")
    run_test("GroupBy sum", test_groupby_sum)

    def test_groupby_mean():
        df = pd.DataFrame({
            "cat": ["A", "B", "A", "B", "A"],
            "val": [10.0, 20.0, 30.0, 40.0, 50.0]
        })
        result = df.groupby("cat")["val"].mean()
        assert result["A"] == 30.0
        assert result["B"] == 30.0
        print(f"    groupby('cat').mean(): A={result['A']}, B={result['B']}")
    run_test("GroupBy mean", test_groupby_mean)

    def test_groupby_count():
        df = pd.DataFrame({
            "grp": ["X", "Y", "X", "Y", "X", "Z"],
            "val": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        })
        result = df.groupby("grp")["val"].count()
        assert result["X"] == 3
        assert result["Y"] == 2
        assert result["Z"] == 1
        print(f"    groupby('grp').count(): X={result['X']}, Y={result['Y']}, Z={result['Z']}")
    run_test("GroupBy count", test_groupby_count)

    def test_groupby_minmax():
        df = pd.DataFrame({
            "g": ["A", "B", "A", "B"],
            "v": [10.0, 20.0, 30.0, 5.0]
        })
        mn = df.groupby("g")["v"].min()
        mx = df.groupby("g")["v"].max()
        assert mn["A"] == 10.0
        assert mx["A"] == 30.0
        assert mn["B"] == 5.0
        assert mx["B"] == 20.0
        print(f"    min: A={mn['A']}, B={mn['B']}")
        print(f"    max: A={mx['A']}, B={mx['B']}")
    run_test("GroupBy min/max", test_groupby_minmax)

    def test_groupby_multi_column():
        df = pd.DataFrame({
            "dept": ["Eng", "Eng", "Sales", "Sales"],
            "region": ["US", "EU", "US", "EU"],
            "revenue": [100.0, 200.0, 300.0, 400.0]
        })
        result = df.groupby(["dept", "region"])["revenue"].sum()
        assert result[("Eng", "US")] == 100.0
        assert result[("Sales", "EU")] == 400.0
        print(f"    Multi-column groupby:")
        print(f"    {result.to_string()}")
    run_test("GroupBy multi-column", test_groupby_multi_column)

    # ── Stage 8: Merge ────────────────────────────────────────────────
    section("8", "Merge — Join Operations")
    print()

    def test_merge_inner():
        left = pd.DataFrame({"id": ["a", "b", "c"], "val": [1, 2, 3]})
        right = pd.DataFrame({"id": ["b", "c", "d"], "score": [10, 20, 30]})
        result = pd.merge(left, right, on="id", how="inner")
        assert len(result) == 2
        assert sorted(result["id"].tolist()) == ["b", "c"]
        print(f"    Inner join: {len(result)} rows, ids={sorted(result['id'].tolist())}")
        print(f"    {result.to_string()}")
    run_test("Merge inner join", test_merge_inner)

    def test_merge_left():
        left = pd.DataFrame({"id": ["a", "b", "c"], "val": [1, 2, 3]})
        right = pd.DataFrame({"id": ["b", "c", "d"], "score": [10, 20, 30]})
        result = pd.merge(left, right, on="id", how="left")
        assert len(result) == 3
        print(f"    Left join: {len(result)} rows")
        print(f"    {result.to_string()}")
    run_test("Merge left join", test_merge_left)

    def test_merge_many_to_many():
        left = pd.DataFrame({"id": ["x", "x", "y"], "a": [1, 2, 3]})
        right = pd.DataFrame({"id": ["x", "x", "y"], "b": [10, 20, 30]})
        result = pd.merge(left, right, on="id", how="inner")
        assert len(result) == 5  # 2*2 + 1*1
        print(f"    Many-to-many: {len(result)} rows (x: 2*2=4, y: 1*1=1)")
    run_test("Merge many-to-many", test_merge_many_to_many)

    # ── Stage 9: Concat ───────────────────────────────────────────────
    section("9", "Concat — Vertical Stacking")
    print()

    def test_concat():
        df1 = pd.DataFrame({"a": [1.0, 2.0], "b": [3.0, 4.0]})
        df2 = pd.DataFrame({"a": [5.0, 6.0], "b": [7.0, 8.0]})
        result = pd.concat([df1, df2], ignore_index=True)
        assert len(result) == 4
        assert result["a"].tolist() == [1.0, 2.0, 5.0, 6.0]
        print(f"    concat 2 DataFrames: {len(result)} rows")
        print(f"    a={result['a'].tolist()}")
    run_test("Concat", test_concat)

    # ── Stage 10: CSV I/O ─────────────────────────────────────────────
    section("10", "CSV I/O — Read & Write")
    print()

    def test_csv_read():
        csv_data = "name,age,score\nAlice,30,95.5\nBob,25,87.3\nCharlie,35,92.1"
        df = pd.read_csv(io.StringIO(csv_data))
        assert len(df) == 3
        assert list(df.columns) == ["name", "age", "score"]
        print(f"    read_csv: {df.shape}")
        print(f"    {df.to_string()}")
    run_test("CSV read", test_csv_read)

    def test_csv_write():
        df = pd.DataFrame({"x": [1.0, 2.0], "y": [3.0, 4.0]})
        csv_out = df.to_csv(index=False)
        assert "x,y" in csv_out
        print(f"    to_csv output:")
        print(f"    {csv_out.strip()}")
    run_test("CSV write", test_csv_write)

    # ── Stage 11: Duplicates & Unique ─────────────────────────────────
    section("11", "Duplicates & Unique")
    print()

    def test_duplicated():
        s = pd.Series([1, 2, 2, 3, 3, 3])
        assert s.duplicated().sum() == 3
        assert s.nunique() == 3
        assert sorted(s.unique().tolist()) == [1, 2, 3]
        dd = s.drop_duplicates()
        assert len(dd) == 3
        print(f"    duplicated count: {s.duplicated().sum()}")
        print(f"    nunique: {s.nunique()}")
        print(f"    unique: {sorted(s.unique().tolist())}")
        print(f"    drop_duplicates: {dd.tolist()}")
    run_test("Duplicated & unique", test_duplicated)

    def test_df_drop_duplicates():
        df = pd.DataFrame({"a": [1, 1, 2, 2], "b": [10, 10, 20, 30]})
        result = df.drop_duplicates()
        assert len(result) == 3
        print(f"    DataFrame drop_duplicates: {len(result)} rows from {len(df)}")
    run_test("DataFrame drop_duplicates", test_df_drop_duplicates)

    # ── Test Summary ──────────────────────────────────────────────────
    print()
    print(DIVIDER)
    print("  Python pandas — Test Results")
    print(THIN)

    passed = sum(1 for _, p, _ in test_results if p)
    failed = sum(1 for _, p, _ in test_results if not p)

    for name, p, detail in test_results:
        pass_fail(name, p, detail if not p else "")

    print(THIN)
    print(f"  Executed {len(test_results)} tests: {passed} passed, {failed} failed")
    print()

    return passed, failed


# ═══════════════════════════════════════════════════════════════════════════════
# PART 2: Python pandas Performance Benchmarks
# ═══════════════════════════════════════════════════════════════════════════════

def run_python_benchmarks():
    banner("PYTHON PANDAS — PERFORMANCE BENCHMARKS")
    print()
    note(f"Python {platform.python_version()} \u2022 pandas {pd.__version__} \u2022 NumPy {np.__version__}")
    note("Each operation: best of 3 runs")
    note(f"Machine: {platform.machine()} {platform.processor()}")
    print()

    results = {}

    # ── 1. Series Aggregation ─────────────────────────────────────────
    section("1", "Series Aggregation (1,000,000 elements)")
    data = random_doubles(1_000_000)
    s = pd.Series(data)

    table_header()
    for op_name in ["sum", "mean", "std", "min", "max", "median"]:
        fn = getattr(s, op_name)
        t = benchmark(fn)
        bench_row(f"{op_name}()", t, f"result={fn():.4f}" if op_name != "std" else "")
        results[f"agg_{op_name}"] = t

    print()
    note("NumPy C kernels with SIMD vectorization (vDSP on Apple).")
    note("median uses O(n) partial sort (introselect).")

    # ── 2. Series Arithmetic ──────────────────────────────────────────
    section("2", "Series Arithmetic (1,000,000 elements)")
    d1 = random_doubles(1_000_000, seed=1)
    d2 = random_doubles(1_000_000, seed=2)
    s1 = pd.Series(d1)
    s2 = pd.Series(d2)

    table_header()
    t = benchmark(lambda: s1 + s2)
    bench_row("Series + Series", t)
    results["arith_add"] = t

    t = benchmark(lambda: s1 * s2)
    bench_row("Series * Series", t)
    results["arith_mul"] = t

    t = benchmark(lambda: s1 + 42.0)
    bench_row("Series + scalar", t)
    results["arith_add_scalar"] = t

    t = benchmark(lambda: s1 * 2.5)
    bench_row("Series * scalar", t)
    results["arith_mul_scalar"] = t

    print()
    note("NumPy vectorized C/SIMD operations.")

    # ── 3. Series Sorting ─────────────────────────────────────────────
    section("3", "Series Sorting (1,000,000 elements)")
    d1m = random_doubles(1_000_000, seed=11)
    s1m = pd.Series(d1m)

    table_header()
    t = benchmark(lambda: s1m.sort_values())
    bench_row("1M elements", t)
    results["sort_1m"] = t

    print()
    note("NumPy argsort (introsort/radixsort in C).")

    # ── 4. Series Statistics ──────────────────────────────────────────
    section("4", "Series Statistics (1,000,000 elements)")
    d1m_stat = random_doubles(1_000_000, seed=20)
    s1m_stat = pd.Series(d1m_stat)

    table_header()
    t = benchmark(lambda: s1m_stat.quantile(0.75))
    bench_row("quantile(0.75)", t)
    results["quantile_1m"] = t

    t = benchmark(lambda: s1m_stat.cumsum())
    bench_row("cumsum()", t)
    results["cumsum_1m"] = t

    t = benchmark(lambda: s1m_stat.value_counts())
    bench_row("valueCounts()", t)
    results["valuecounts_1m"] = t

    print()
    note("quantile uses O(n) partial sort (introselect).")

    # ── 5. DataFrame Construction ─────────────────────────────────────
    section("5", "DataFrame Construction (1M x 6 cols)")
    table_header()

    t = benchmark(lambda: numeric_dataframe(1_000_000, 6, seed=31))
    bench_row("1M rows x 6 cols", t)
    results["df_construct_1m"] = t

    print()
    note("Includes LCG data generation + DataFrame construction.")

    # ── 6. DataFrame Filtering ────────────────────────────────────────
    section("6", "DataFrame Filtering (1M x 6 cols)")
    df1m = numeric_dataframe(1_000_000, 6, seed=41)

    sub("df[df['col0'] > 500.0]  (~50% selectivity)")
    table_header()

    t = benchmark(lambda: df1m[df1m["col0"] > 500.0])
    bench_row("1M rows x 6 cols", t)
    results["filter_1m"] = t

    print()
    note("NumPy vectorized comparison + fancy indexing in C.")

    # ── 7. DataFrame Sorting ──────────────────────────────────────────
    section("7", "DataFrame Sorting (1,000,000 rows x 6 cols)")
    df_sort = numeric_dataframe(1_000_000, 6, seed=50)

    table_header()

    t = benchmark(lambda: df_sort.sort_values("col0"))
    bench_row("Single column", t)
    results["df_sort_single"] = t

    t = benchmark(lambda: df_sort.sort_values(["col0", "col1"]))
    bench_row("Multi-column (2 keys)", t)
    results["df_sort_multi"] = t

    print()
    note("NumPy argsort + take along axis.")

    # ── 8. DataFrame Aggregation ──────────────────────────────────────
    section("8", "DataFrame Aggregation (1,000,000 rows x 6 cols)")
    df_agg = numeric_dataframe(1_000_000, 6, seed=60)

    table_header()

    t = benchmark(lambda: df_agg.sum())
    bench_row("sum()", t)
    results["df_sum"] = t

    t = benchmark(lambda: df_agg.mean())
    bench_row("mean()", t)
    results["df_mean"] = t

    t = benchmark(lambda: df_agg.std())
    bench_row("std()", t)
    results["df_std"] = t

    t = benchmark(lambda: df_agg.describe())
    bench_row("describe()", t)
    results["df_describe"] = t

    print()
    note("NumPy reduction kernels per column.")

    # ── 9. GroupBy ────────────────────────────────────────────────────
    section("9", "GroupBy (1,000,000 rows)")
    df100g = groupable_dataframe(1_000_000, 100, seed=70)
    df10kg = groupable_dataframe(1_000_000, 10_000, seed=71)

    sub("100 groups")
    table_header()

    gb100 = df100g.groupby("group")
    t = benchmark(lambda: gb100.sum())
    bench_row("sum()", t)
    results["gb_sum_100g"] = t

    t = benchmark(lambda: gb100.mean())
    bench_row("mean()", t)
    results["gb_mean_100g"] = t

    t = benchmark(lambda: gb100.count())
    bench_row("count()", t)
    results["gb_count_100g"] = t

    sub("10,000 groups")
    table_header()

    gb10k = df10kg.groupby("group")
    t = benchmark(lambda: gb10k.sum())
    bench_row("sum()", t)
    results["gb_sum_10kg"] = t

    print()
    note("Cython hash table on raw integer codes (factorize).")

    # ── 10. Merge ─────────────────────────────────────────────────────
    section("10", "Merge (Inner Join, 100K rows)")

    rng = LCG(seed=80)
    keys100k = [f"k{rng.next_int(50000)}" for _ in range(100_000)]
    vals1 = [rng.next_float() * 100.0 for _ in range(100_000)]
    vals2 = [rng.next_float() * 100.0 for _ in range(100_000)]

    left100k = pd.DataFrame({"key": keys100k, "left_val": vals1})
    right100k_keys = keys100k.copy()
    np.random.seed(42)
    np.random.shuffle(right100k_keys)
    right100k = pd.DataFrame({"key": right100k_keys[:100_000], "right_val": vals2})

    table_header()
    t = benchmark(lambda: pd.merge(left100k, right100k, on="key", how="inner"))
    bench_row("100K x 100K", t)
    results["merge_100k"] = t

    print()
    note("C-level hash join on raw array values.")

    # ── 11. Concat ────────────────────────────────────────────────────
    section("11", "Concat (Vertical Stack)")
    frames = [numeric_dataframe(100_000, 6, seed=90 + i) for i in range(10)]

    table_header()
    t = benchmark(lambda: pd.concat(frames, ignore_index=True))
    bench_row("10 x 100K rows", t)
    results["concat_10x100k"] = t

    print()
    note("BlockManager concat + reindex.")

    # ── 12. CSV I/O ───────────────────────────────────────────────────
    section("12", "CSV I/O (1M rows x 6 cols)")
    csv1m = csv_string(1_000_000, 6, seed=100)

    sub("Read CSV (string -> DataFrame)")
    table_header()

    t = benchmark(lambda: pd.read_csv(io.StringIO(csv1m)))
    bench_row("1M rows x 6 cols", t)
    results["csv_read_1m"] = t

    df_csv1m = pd.read_csv(io.StringIO(csv1m))

    sub("Write CSV (DataFrame -> string)")
    table_header()

    t = benchmark(lambda: df_csv1m.to_csv(index=False))
    bench_row("1M rows x 6 cols", t)
    results["csv_write_1m"] = t

    print()
    note("C-level tokenizer for reads; Python string formatting for writes.")

    return results


# ═══════════════════════════════════════════════════════════════════════════════
# PART 3: SwiftPandas Tests (invoke via swift test)
# ═══════════════════════════════════════════════════════════════════════════════

def run_swift_tests():
    banner("SWIFTPANDAS — TEST SUITE (via swift test)")

    package_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print()
    note(f"Package: {package_dir}")
    note("Running: swift test (Package.swift already specifies -O optimization)")
    print()
    print(THIN)

    try:
        result = subprocess.run(
            ["swift", "test"],
            cwd=package_dir,
            capture_output=True,
            text=True,
            timeout=600,
        )

        output = result.stdout + result.stderr

        # Show per-test pass/fail
        swift_passed = 0
        swift_failed = 0
        for line in output.splitlines():
            if "passed" in line and "Test Case" in line:
                name = line.split("'")[-2] if "'" in line else line
                name = name.replace("SwiftPandasTests.", "").rstrip("]")
                if name.startswith("-["):
                    name = name[2:]
                print(f"  \u2705  {name}")
                swift_passed += 1
            elif "failed" in line and "Test Case" in line:
                name = line.split("'")[-2] if "'" in line else line
                name = name.replace("SwiftPandasTests.", "").rstrip("]")
                if name.startswith("-["):
                    name = name[2:]
                print(f"  \u274C  {name}")
                swift_failed += 1

        # Show summary
        print(THIN)
        # Get last "Executed" line
        exec_lines = [l.strip() for l in output.splitlines() if "Executed" in l and "tests" in l]
        if exec_lines:
            print(f"  {exec_lines[-1]}")

        return swift_passed, swift_failed

    except FileNotFoundError:
        print("  ERROR: swift not found. Is Xcode/Swift installed?")
        return 0, -1
    except subprocess.TimeoutExpired:
        print("  ERROR: swift test timed out after 600 seconds.")
        return 0, -1

    except Exception as e:
        print(f"  ERROR: {e}")
        return 0, -1


# ═══════════════════════════════════════════════════════════════════════════════
# PART 4: SwiftPandas Benchmarks (invoke via swift build + xcrun xctest)
# ═══════════════════════════════════════════════════════════════════════════════

def run_swift_benchmarks():
    """Run SwiftPandas benchmarks and return parsed timing dict {op_name: ms}."""
    banner("SWIFTPANDAS — PERFORMANCE BENCHMARKS (via swift build + xcrun xctest)")

    package_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print()
    note("Running: swift build --build-tests")
    note("         + xcrun xctest -XCTest BenchmarkTests")
    note("Swift compiled with -O (optimized via Package.swift). C libs compiled with -O3.")
    print()
    print(THIN)

    swift_timings = {}

    try:
        # Build tests using SPM. Package.swift specifies -O (optimized) for both
        # the library and test targets, so even debug config produces optimized code.
        # This is critical for a fair comparison with pandas (compiled C/Cython).
        # We then run the XCTest binary directly via xcrun xctest to preserve
        # print() output from benchmark tests.
        build_result = subprocess.run(
            ["swift", "build", "--build-tests"],
            cwd=package_dir,
            capture_output=True, text=True, timeout=180,
        )

        if build_result.returncode != 0:
            print("  ERROR: swift build --build-tests failed:")
            # Show last few lines of build output
            for line in (build_result.stdout + build_result.stderr).splitlines()[-10:]:
                print(f"  {line}")
            return swift_timings

        # Find the built xctest bundle in .build directory
        import glob as _glob
        xctest_bundle = None
        # SPM names the bundle <Package>PackageTests.xctest
        for pattern in [
            os.path.join(package_dir, ".build", "*", "debug", "SwiftPandasPackageTests.xctest"),
            os.path.join(package_dir, ".build", "*", "release", "SwiftPandasPackageTests.xctest"),
            os.path.join(package_dir, ".build", "debug", "SwiftPandasPackageTests.xctest"),
            os.path.join(package_dir, ".build", "release", "SwiftPandasPackageTests.xctest"),
        ]:
            matches = _glob.glob(pattern)
            if matches:
                xctest_bundle = matches[0]
                break

        if not xctest_bundle or not os.path.exists(xctest_bundle):
            print("  ERROR: Could not find SwiftPandasPackageTests.xctest bundle.")
            print("  Run 'swift build --build-tests' first.")
            return swift_timings

        result = subprocess.run(
            [
                "xcrun", "xctest",
                "-XCTest", "SwiftPandasTests.BenchmarkTests",
                xctest_bundle,
            ],
            cwd=package_dir,
            capture_output=True, text=True, timeout=600,
        )

        output = result.stdout + "\n" + result.stderr

        # Show the benchmark output (print statements from the tests)
        for line in output.splitlines():
            # Skip build/test framework noise, show benchmark output
            if any(skip in line for skip in [
                "Building for", "Build complete", "Test Suite",
                "Executed", "Test Case", "[", "warning:",
            ]):
                continue
            stripped = line.rstrip()
            if stripped:
                print(stripped)

        # Parse Swift timing lines with section context.
        # Section headers: "  │  1. Series Aggregation ..."
        # Timing lines: "      sum()                      92,000"
        current_section = ""
        for line in output.splitlines():
            # Detect section numbers from the benchmark output
            sec_m = re.search(r'(\d+)\.\s+(Series|DataFrame|GroupBy|Merge|Concat|CSV)', line)
            if sec_m:
                num = sec_m.group(1)
                word = sec_m.group(2).lower()
                # Disambiguate DataFrame sub-sections by number
                df_sections = {
                    "5": "df_construct", "6": "df_filter",
                    "7": "df_sort", "8": "df_agg",
                }
                current_section = df_sections.get(num, word)

            # Detect sub-sections like "▶ 100 groups" or "▶ Read CSV"
            if "\u25B6" in line:
                sub_text = line.split("\u25B6")[-1].strip().lower()
                if "100 group" in sub_text:
                    current_section = "gb_100g"
                elif "10,000 group" in sub_text or "10000 group" in sub_text:
                    current_section = "gb_10kg"
                elif "read" in sub_text:
                    current_section = "csv_read"
                elif "write" in sub_text:
                    current_section = "csv_write"

            # Match timing data lines: "      op_name          123,456.789 µs"
            m = re.match(
                r'\s{6,}(\S.*?)\s{2,}([\d,]+\.?\d*)\s*\u00b5s',
                line,
            )
            if m:
                op_name = m.group(1).strip()
                us_val = float(m.group(2).replace(',', ''))
                swift_ns = us_val * 1000.0  # convert µs back to ns for comparison
                # Use section-qualified key to avoid collisions
                qualified = f"{current_section}:{op_name}"
                swift_timings[qualified] = swift_ns

        # Show summary
        print()
        print(THIN)
        for line in output.splitlines():
            if "Executed" in line and "tests" in line:
                print(f"  {line.strip()}")

    except FileNotFoundError:
        print("  ERROR: swift not found. Is Xcode/Swift installed?")
    except subprocess.TimeoutExpired:
        print("  ERROR: swift test timed out.")

    return swift_timings


# ═══════════════════════════════════════════════════════════════════════════════
# PART 5: Side-by-Side Comparison
# ═══════════════════════════════════════════════════════════════════════════════

def print_comparison(py_results, swift_results):
    banner("SIDE-BY-SIDE COMPARISON \u2014 Python pandas vs SwiftPandas")
    print()
    note("Both measured live on this machine. Best of 3 runs.")
    note("Swift compiled with -O (Release). All times in microseconds (\u00b5s).")
    note("+% = Swift faster than Python. -% = Swift slower than Python.")
    print()

    # Table header
    hdr_op   = "Operation".ljust(26)
    hdr_py   = "Python (\u00b5s)".rjust(18)
    hdr_sw   = "Swift (\u00b5s)".rjust(18)
    hdr_win  = "Winner".rjust(8)
    hdr_pct  = "vs Python".rjust(14)
    print(f"    {hdr_op} {hdr_py} {hdr_sw} {hdr_win} {hdr_pct}")
    print("    " + "\u2500" * 74)

    # Each entry: (display_name, py_key, swift_qualified_key)
    # swift_qualified_key is "section:operation" matching the parsed output
    rows = [
        ("Series Aggregation",  None,               None),
        ("  sum()",             "agg_sum",          "series:sum()"),
        ("  mean()",            "agg_mean",         "series:mean()"),
        ("  std()",             "agg_std",          "series:std()"),
        ("  min()",             "agg_min",          "series:min()"),
        ("  max()",             "agg_max",          "series:max()"),
        ("  median()",          "agg_median",       "series:median()"),
        ("",                    None,               None),
        ("Series Arithmetic",   None,               None),
        ("  Series + Series",   "arith_add",        "series:Series + Series"),
        ("  Series * Series",   "arith_mul",        "series:Series * Series"),
        ("  Series + scalar",   "arith_add_scalar", "series:Series + scalar"),
        ("  Series * scalar",   "arith_mul_scalar", "series:Series * scalar"),
        ("",                    None,               None),
        ("Series Sort/Stats",   None,               None),
        ("  sort 1M",           "sort_1m",          "series:1M elements"),
        ("  quantile(0.75)",    "quantile_1m",      "series:quantile(0.75)"),
        ("  cumsum()",          "cumsum_1m",        "series:cumsum()"),
        ("  valueCounts()",     "valuecounts_1m",   "series:valueCounts()"),
        ("",                    None,               None),
        ("DataFrame",           None,               None),
        ("  construct 1M",      "df_construct_1m",  "df_construct:1M rows x 6 cols"),
        ("  filter 1M",         "filter_1m",        "df_filter:1M rows x 6 cols"),
        ("  sort single",       "df_sort_single",   "df_sort:Single column"),
        ("  sort multi",        "df_sort_multi",    "df_sort:Multi-column (2 keys)"),
        ("  sum()",             "df_sum",           "df_agg:sum()"),
        ("  mean()",            "df_mean",          "df_agg:mean()"),
        ("  std()",             "df_std",           "df_agg:std()"),
        ("  describe()",        "df_describe",      "df_agg:describe()"),
        ("",                    None,               None),
        ("GroupBy (1M rows)",   None,               None),
        ("  sum 100g",          "gb_sum_100g",      "gb_100g:sum()"),
        ("  mean 100g",         "gb_mean_100g",     "gb_100g:mean()"),
        ("  count 100g",        "gb_count_100g",    "gb_100g:count()"),
        ("  sum 10Kg",          "gb_sum_10kg",      "gb_10kg:sum()"),
        ("",                    None,               None),
        ("Merge (100K)",        None,               None),
        ("  inner 100K",        "merge_100k",       "merge:100K x 100K"),
        ("",                    None,               None),
        ("Concat",              None,               None),
        ("  10 x 100K",         "concat_10x100k",   "concat:10 x 100K rows"),
        ("",                    None,               None),
        ("CSV I/O (1M)",        None,               None),
        ("  read 1M",           "csv_read_1m",      "csv_read:1M rows x 6 cols"),
        ("  write 1M",          "csv_write_1m",     "csv_write:1M rows x 6 cols"),
    ]

    def find_swift(swift_key):
        """Find the Swift timing for this row."""
        if not swift_key:
            return None
        # Exact match
        if swift_key in swift_results:
            return swift_results[swift_key]
        # Try without section prefix (fallback)
        _, _, op = swift_key.partition(":")
        for k, v in swift_results.items():
            if k.endswith(":" + op):
                return v
        return None

    swift_wins = 0
    py_wins = 0
    all_pct_diffs = []  # collect percentage differences for overall score

    for display, py_key, swift_key in rows:
        # Section header
        if py_key is None:
            if display:
                print(f"    {display}")
            else:
                print()
            continue

        py_ns = py_results.get(py_key)
        sw_ns = find_swift(swift_key)

        op_str = display.ljust(26)
        py_str = format_us(py_ns).rjust(18) if py_ns is not None else "\u2014".rjust(18)
        sw_str = format_us(sw_ns).rjust(18) if sw_ns is not None else "\u2014".rjust(18)

        if py_ns and sw_ns and py_ns > 0 and sw_ns > 0:
            # pct_diff > 0 means Swift is faster, < 0 means slower
            pct_diff = (py_ns - sw_ns) / py_ns * 100.0
            # Clamp to [-100, +100] so outliers don't skew the average
            clamped = max(-100.0, min(100.0, pct_diff))
            all_pct_diffs.append(clamped)

            if pct_diff >= 0:
                winner = "Swift"
                pct_str = f"+{min(pct_diff, 100):.0f}% faster"
                swift_wins += 1
            else:
                winner = "pandas"
                pct_str = f"{max(pct_diff, -100):.0f}% slower"
                py_wins += 1
        else:
            winner = ""
            pct_str = "\u2014"

        win_str = winner.rjust(8)
        pct_out = pct_str.rjust(14)
        print(f"    {op_str} {py_str} {sw_str} {win_str} {pct_out}")

    print()
    print("    " + "\u2500" * 74)
    print(f"    Scorecard:  Swift wins {swift_wins}  |  pandas wins {py_wins}")

    # Overall averaged score across all measured operations
    if all_pct_diffs:
        avg_pct = sum(all_pct_diffs) / len(all_pct_diffs)
        n = len(all_pct_diffs)
        if avg_pct > 0:
            print(f"    Overall:    SwiftPandas is {avg_pct:.1f}% faster than pandas on average ({n} tests)")
        elif avg_pct < 0:
            print(f"    Overall:    SwiftPandas is {abs(avg_pct):.1f}% slower than pandas on average ({n} tests)")
        else:
            print(f"    Overall:    SwiftPandas and pandas are equivalent on average ({n} tests)")
    print()


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main():
    print("\u2550" * W)
    print("  SwiftPandas vs Python pandas — Complete Benchmark Suite")
    print("\u2550" * W)
    print()
    note(f"Date: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    note(f"Python: {platform.python_version()}, pandas: {pd.__version__}, NumPy: {np.__version__}")
    note(f"Platform: {platform.machine()} {platform.system()} {platform.release()}")
    print()

    # Part 1: Python correctness tests
    py_passed, py_failed = run_python_tests()

    # Part 2: Python benchmarks
    py_bench_results = run_python_benchmarks()

    # Part 3: Swift correctness tests
    swift_passed, swift_failed = run_swift_tests()

    # Part 4: Swift benchmarks
    swift_bench_results = run_swift_benchmarks()

    # Part 5: Comparison table
    print_comparison(py_bench_results, swift_bench_results)

    # ── Final Summary ─────────────────────────────────────────────────
    banner("FINAL SUMMARY")
    print()
    print("  Python pandas:")
    print(f"    Correctness: {py_passed} passed, {py_failed} failed")
    print(f"    Benchmarks:  {len(py_bench_results)} operations measured")
    print()
    print("  SwiftPandas:")
    if swift_failed >= 0:
        print(f"    Correctness: {swift_passed} passed, {swift_failed} failed")
    else:
        print("    Correctness: could not run (swift not found or timeout)")
    print(f"    Benchmarks:  see swift test output above")
    print()

    print("  Configuration:")
    print("  " + "\u2500" * (W - 4))
    print("    Swift: compiled with -O (Release), C libs with -O3")
    print("    Python: pandas with C/Cython extensions, NumPy with SIMD/vDSP")
    print("    All benchmarks at 1M rows (merge: 100K). Best of 3 runs.")
    print()
    print("    Metal GPU: GroupBy + Merge accelerated via compute shaders")
    print("    for datasets >= 500K rows. Falls back to CPU for smaller datasets.")
    print()
    print("\u2550" * W)
    print("  Done.")
    print("\u2550" * W)


if __name__ == "__main__":
    main()
