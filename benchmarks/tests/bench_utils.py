"""
Shared utilities for individual SwiftPandas benchmark tests.

Provides deterministic data generation (LCG matching SwiftPandas BenchmarkTests),
timing helpers, formatting, and a common CLI for running individual benchmarks
with configurable row counts and iteration counts.

Usage from individual test scripts:
    from bench_utils import *
"""

import sys
import os
import time
import io
import argparse
import platform
import warnings

# The project root has a 'pandas/' directory (CPython pandas source tree) that
# shadows the installed pandas package.  Remove it from sys.path so we import
# the real, installed pandas.
_project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path = [p for p in sys.path if os.path.abspath(p) != _project_dir]

import numpy as np
import pandas as pd

# Suppress numpy overflow warnings from the LCG (intentional wrapping arithmetic)
warnings.filterwarnings("ignore", category=RuntimeWarning, message="overflow")


# =============================================================================
# Formatting
# =============================================================================

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
    """Format nanoseconds as microseconds with comma separators."""
    us = ns / 1000.0
    return f"{us:,.0f} \u00b5s"

def format_ns(ns):
    """Format nanoseconds with comma separators."""
    return f"{ns:,.0f} ns"


# =============================================================================
# Timing
# =============================================================================

def benchmark(fn, iterations=3):
    """Run fn `iterations` times, return minimum time in nanoseconds."""
    best = float("inf")
    for _ in range(iterations):
        start = time.perf_counter_ns()
        fn()
        elapsed = time.perf_counter_ns() - start
        best = min(best, elapsed)
    return best

def benchmark_detailed(fn, iterations=5, warmup=1):
    """Run fn with warmup, return dict with min/max/mean/median/all times in ns."""
    for _ in range(warmup):
        fn()
    times = []
    for _ in range(iterations):
        start = time.perf_counter_ns()
        fn()
        elapsed = time.perf_counter_ns() - start
        times.append(elapsed)
    times.sort()
    return {
        "min": times[0],
        "max": times[-1],
        "mean": sum(times) / len(times),
        "median": times[len(times) // 2],
        "all": times,
    }


# =============================================================================
# Deterministic data generation (same LCG as SwiftPandas)
# =============================================================================

class LCG:
    """Linear congruential generator matching SwiftPandas BenchmarkTests.LCG."""
    def __init__(self, seed=42):
        self.state = np.uint64(seed)

    def next_float(self):
        self.state = np.uint64(
            np.uint64(self.state) * np.uint64(6364136223846793005)
            + np.uint64(1442695040888963407)
        )
        return float(np.uint64(self.state) >> np.uint64(11)) / float(np.uint64(1) << np.uint64(53))

    def next_int(self, bound):
        self.state = np.uint64(
            np.uint64(self.state) * np.uint64(6364136223846793005)
            + np.uint64(1442695040888963407)
        )
        return int(np.uint64(self.state) >> np.uint64(33)) % bound


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


# =============================================================================
# CLI argument parsing
# =============================================================================

def parse_args(description, default_rows=1_000_000):
    """Parse common CLI arguments for individual benchmark scripts."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("-n", "--rows", type=int, default=default_rows,
                        help=f"Number of rows (default: {default_rows:,})")
    parser.add_argument("-i", "--iterations", type=int, default=5,
                        help="Number of timed iterations (default: 5)")
    parser.add_argument("-w", "--warmup", type=int, default=1,
                        help="Number of warmup iterations (default: 1)")
    parser.add_argument("--seed", type=int, default=42,
                        help="LCG seed (default: 42)")
    return parser.parse_args()


def print_header(test_name, args):
    """Print a standard benchmark header with system info and parameters."""
    banner(f"BENCHMARK: {test_name}")
    print()
    note(f"Python {platform.python_version()} \u2022 pandas {pd.__version__} \u2022 NumPy {np.__version__}")
    note(f"Platform: {platform.machine()} {platform.system()} {platform.release()}")
    note(f"Rows: {args.rows:,}  |  Iterations: {args.iterations}  |  Warmup: {args.warmup}  |  Seed: {args.seed}")
    print()


def print_detailed_results(results, label=""):
    """Print detailed timing results from benchmark_detailed()."""
    if label:
        sub(label)
    print(f"    Min:    {format_us(results['min']):>14s}   (best)")
    print(f"    Median: {format_us(results['median']):>14s}")
    print(f"    Mean:   {format_us(results['mean']):>14s}")
    print(f"    Max:    {format_us(results['max']):>14s}   (worst)")
    print(f"    All runs (ns): {[int(t) for t in results['all']]}")
    print()
