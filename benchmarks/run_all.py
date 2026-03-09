#!/usr/bin/env python3
"""
Run all 30 individual benchmark tests sequentially.

Usage:
    python3 benchmarks/run_all.py              # run all 30 tests
    python3 benchmarks/run_all.py 1 5 12       # run specific tests by number
    python3 benchmarks/run_all.py --list        # list all available tests
"""

import os
import sys
import subprocess
import glob
import time

TESTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tests")


def get_test_files():
    """Return sorted list of (number, filename, path) tuples."""
    pattern = os.path.join(TESTS_DIR, "[0-9][0-9]_*.py")
    files = sorted(glob.glob(pattern))
    result = []
    for path in files:
        name = os.path.basename(path)
        num = int(name[:2])
        result.append((num, name, path))
    return result


def main():
    tests = get_test_files()

    if "--list" in sys.argv:
        print(f"Available benchmark tests ({len(tests)} total):\n")
        for num, name, _ in tests:
            print(f"  {num:2d}. {name}")
        return

    # Filter by specific test numbers if provided
    requested = []
    for arg in sys.argv[1:]:
        if arg.isdigit():
            requested.append(int(arg))

    if requested:
        tests = [(n, name, path) for n, name, path in tests if n in requested]

    if not tests:
        print("No matching tests found.")
        return

    print(f"\n{'=' * 80}")
    print(f"  Running {len(tests)} benchmark test(s)")
    print(f"{'=' * 80}\n")

    passed = 0
    failed = 0
    start_time = time.time()

    for num, name, path in tests:
        print(f"\n{'=' * 80}")
        print(f"  [{num:2d}/{len(get_test_files())}] {name}")
        print(f"{'=' * 80}\n")

        result = subprocess.run(
            [sys.executable, path],
            cwd=os.path.dirname(TESTS_DIR),
        )

        if result.returncode == 0:
            passed += 1
        else:
            failed += 1
            print(f"\n  *** FAILED: {name} (exit code {result.returncode}) ***\n")

    elapsed = time.time() - start_time

    print(f"\n{'=' * 80}")
    print(f"  Results: {passed} passed, {failed} failed ({elapsed:.1f}s total)")
    print(f"{'=' * 80}\n")


if __name__ == "__main__":
    main()
