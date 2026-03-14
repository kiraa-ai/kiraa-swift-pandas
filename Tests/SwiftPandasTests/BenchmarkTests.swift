// ──────────────────────────────────────────────────────────────────────────────
// BenchmarkTests.swift
// SwiftPandasTests
//
// Performance benchmark suite for SwiftPandas.
//
// Methodology
// -----------
// Each benchmark follows a consistent protocol:
//   1. Data is generated deterministically using a Linear Congruential Generator
//      (LCG) seeded with a fixed value, so results are reproducible across runs.
//   2. The operation under test is executed 3 times (configurable via the
//      `iterations` parameter of the `benchmark` helper).
//   3. The **minimum** wall-clock time across the 3 iterations is reported, to
//      reduce noise from GC pauses, scheduling jitter, and thermal throttling.
//   4. Times are reported in microseconds (converted from nanosecond-resolution
//      `CFAbsoluteTimeGetCurrent` measurements).
//
// Default dataset sizes
// ---------------------
//   - Series / DataFrame operations: 1 000 000 rows (1M).
//   - Merge (inner join): 100 000 rows per side (100K), because the Cartesian
//     product of matching keys can explode row count.
//   - Concat: 10 DataFrames of 100 000 rows each (total 1M).
//   - CSV I/O: 1 000 000 rows x 6 columns.
//
// Benchmark sections
// ------------------
//   1.  Series aggregation      — sum, mean, std, min, max, median
//   2.  Series arithmetic       — element-wise +, *, scalar +, scalar *
//   3.  Series sorting          — sortValues at 1M
//   4.  Series statistics       — quantile, cumsum, valueCounts
//   5.  DataFrame construction  — dict-based creation at 1M x 6
//   6.  DataFrame filtering     — boolean mask at 1M x 6
//   7.  DataFrame sorting       — single and multi-column at 1M x 6
//   8.  DataFrame aggregation   — sum, mean, std, describe at 1M x 6
//   9.  GroupBy                 — sum, mean, count at 1M rows (100 and 10K groups)
//   10. Merge                   — inner join at 100K x 100K
//   11. Concat                  — vertical stacking (10 x 100K)
//   12. CSV I/O                 — read and write at 1M x 6
//   13. Lazy vs Eager           — filter+groupBy chains comparing lazy and eager
//
// The final test (`testZZ_BenchmarkSummary`) prints a summary of all
// optimizations applied by the library (Accelerate/vDSP, factorize-based
// GroupBy, quickselect median, byte-level CSV parser, Metal GPU, lazy engine).
//
// Run with: swift test --filter BenchmarkTests
// ──────────────────────────────────────────────────────────────────────────────

import Testing
@testable import SwiftPandas
import Foundation

/// Performance benchmark suite for SwiftPandas.
///
/// All benchmarks use deterministic LCG-generated data at 1M rows (100K for merge).
/// Each operation is run 3 times; the minimum wall-clock time is reported in
/// microseconds. Test methods are alphabetically prefixed (`testAA_`, `testBA_`,
/// etc.) to control execution order so that the header prints first and the
/// summary prints last.
@Suite(.serialized) struct BenchmarkTests {

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Formatting helpers                                                │
    // └─────────────────────────────────────────────────────────────────────┘

    /// The fixed character width used for formatting output banners and tables.
    static let W = 80

    /// Prints a top-level banner with a double-line box around the title.
    static func banner(_ title: String) {
        let pad = max(0, W - title.count - 4)
        let left = pad / 2
        let right = pad - left
        print("")
        print("\u{2554}" + String(repeating: "\u{2550}", count: W) + "\u{2557}")
        print("\u{2551}" + String(repeating: " ", count: left) + "  " + title + String(repeating: " ", count: right) + "  \u{2551}")
        print("\u{255A}" + String(repeating: "\u{2550}", count: W) + "\u{255D}")
    }

    /// Prints a numbered section header with a single-line box.
    static func section(_ num: String, _ title: String) {
        print("")
        print("  \u{250C}" + String(repeating: "\u{2500}", count: W - 4) + "\u{2510}")
        print("  \u{2502}  \(num). \(title)" + String(repeating: " ", count: max(0, W - 8 - num.count - title.count)) + "\u{2502}")
        print("  \u{2514}" + String(repeating: "\u{2500}", count: W - 4) + "\u{2518}")
    }

    /// Prints a subsection header with a triangle marker and horizontal rule.
    static func sub(_ title: String) {
        print("\n  \u{25B6} \(title)")
        print("  " + String(repeating: "\u{2500}", count: W - 4))
    }

    /// Prints an indented note line with a vertical bar prefix.
    static func note(_ text: String) {
        print("    \u{2502} \(text)")
    }

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Benchmark table — all times in microseconds (µs)                   │
    // └─────────────────────────────────────────────────────────────────────┘

    /// Prints the column header row for a benchmark results table.
    static func tableHeader() {
        let op = "Operation".padding(toLength: 26, withPad: " ", startingAt: 0)
        let swift = "Swift (\u{00B5}s)".padding(toLength: 20, withPad: " ", startingAt: 0)
        let extra = "Details"
        print("    \u{25B8} \(op) \(swift) \(extra)")
        print("    " + String(repeating: "\u{2500}", count: W - 8))
    }

    /// Prints a single benchmark result row with operation name, time, and optional detail.
    static func benchRow(_ op: String, ns: Double, detail: String = "") {
        let name = op.padding(toLength: 26, withPad: " ", startingAt: 0)
        let t = formatUs(ns).padding(toLength: 20, withPad: " ", startingAt: 0)
        print("      \(name) \(t) \(detail)")
    }

    /// Converts a nanosecond measurement to a formatted microsecond string (e.g. "1,234 us").
    static func formatUs(_ ns: Double) -> String {
        let us = ns / 1000.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = ","
        return (formatter.string(from: NSNumber(value: us)) ?? String(format: "%.0f", us)) + " \u{00B5}s"
    }

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Timing & data generation                                          │
    // └─────────────────────────────────────────────────────────────────────┘

    /// Measures the wall-clock execution time of a block, returning the best (minimum) result.
    ///
    /// The block is executed `iterations` times (default 3). Each iteration is timed
    /// individually using `CFAbsoluteTimeGetCurrent`, which provides sub-microsecond
    /// resolution. The minimum time is returned to reduce the impact of system noise
    /// (GC, scheduling, thermal throttling). The result is in **nanoseconds**.
    ///
    /// - Parameters:
    ///   - iterations: Number of times to run the block (default: 3).
    ///   - block: The closure to benchmark. It should perform the operation under test
    ///     and discard the result (use `_ =` to prevent dead-code elimination).
    /// - Returns: The minimum elapsed time in nanoseconds across all iterations.
    static func benchmark(_ iterations: Int = 3, _ block: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            block()
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000_000.0
            best = Swift.min(best, elapsed)
        }
        return best
    }

    /// A minimal Linear Congruential Generator (LCG) for deterministic pseudo-random numbers.
    ///
    /// This generator uses the same multiplier and increment as the PCG family's
    /// default constants (`6364136223846793005` and `1442695040888963407`). It
    /// produces uniformly distributed `Double` values in [0, 1) via `next()` and
    /// bounded non-negative integers via `nextInt(_:)`.
    ///
    /// The LCG is used instead of `SystemRandomNumberGenerator` so that every
    /// benchmark run produces identical data, making results reproducible and
    /// comparable across machines and Swift versions.
    ///
    /// - Note: This is **not** cryptographically secure and is intended solely
    ///   for generating test/benchmark data.
    struct LCG {
        /// The internal 64-bit state, advanced on every call to `next()` or `nextInt(_:)`.
        var state: UInt64

        /// Creates an LCG with the given seed. The default seed is 42.
        init(seed: UInt64 = 42) {
            state = seed
        }

        /// Advances the state and returns a pseudo-random `Double` in [0, 1).
        ///
        /// The top 53 bits of the state are used to fill the significand of a
        /// Double, giving a resolution of 2^-53 (~1.1e-16).
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        /// Advances the state and returns a pseudo-random non-negative `Int` in [0, bound).
        ///
        /// Uses the top 31 bits of the state and reduces modulo `bound`. The modulo
        /// bias is negligible for the benchmark use cases (bound << 2^31).
        mutating func nextInt(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }
    }

    /// Generates an array of deterministic pseudo-random doubles in [0, 1000).
    ///
    /// Each value is `LCG.next() * 1000.0`, giving a uniform distribution over
    /// the range [0, 1000). The fixed seed ensures reproducibility.
    ///
    /// - Parameters:
    ///   - count: Number of doubles to generate.
    ///   - seed: LCG seed (default 42).
    /// - Returns: An array of `count` doubles.
    static func randomDoubles(_ count: Int, seed: UInt64 = 42) -> [Double] {
        var rng = LCG(seed: seed)
        return (0..<count).map { _ in rng.next() * 1000.0 }
    }

    /// Generates a purely numeric DataFrame with the specified number of rows and columns.
    ///
    /// Each column is named `"col0"`, `"col1"`, ..., `"col{cols-1}"` and contains
    /// `rows` pseudo-random doubles in [0, 1000). A single LCG instance is used
    /// across all columns so the data is fully deterministic given the seed.
    ///
    /// - Parameters:
    ///   - rows: Number of rows.
    ///   - cols: Number of columns.
    ///   - seed: LCG seed (default 42).
    /// - Returns: A DataFrame with `cols` float64 columns and `rows` rows.
    static func numericDataFrame(rows: Int, cols: Int, seed: UInt64 = 42) -> DataFrame {
        var rng = LCG(seed: seed)
        var columns: [(String, Column)] = []
        for c in 0..<cols {
            let data = (0..<rows).map { _ in rng.next() * 1000.0 }
            columns.append(("col\(c)", Column.fromDoubles(data)))
        }
        return DataFrame(columns: columns)
    }

    /// Generates a DataFrame suitable for GroupBy benchmarks.
    ///
    /// The resulting DataFrame has three columns:
    ///   - `"group"` (String): group labels `"g0"` through `"g{nGroups-1}"`,
    ///     assigned round-robin via `LCG.nextInt`.
    ///   - `"value1"` (Double): random doubles in [0, 1000).
    ///   - `"value2"` (Double): random doubles in [0, 500).
    ///
    /// - Parameters:
    ///   - rows: Number of rows.
    ///   - nGroups: Number of distinct group labels.
    ///   - seed: LCG seed (default 42).
    /// - Returns: A DataFrame with 1 string column and 2 float64 columns.
    static func groupableDataFrame(rows: Int, nGroups: Int, seed: UInt64 = 42) -> DataFrame {
        var rng = LCG(seed: seed)
        let groups = (0..<rows).map { _ in "g\(rng.nextInt(nGroups))" }
        let values = (0..<rows).map { _ in rng.next() * 1000.0 }
        let values2 = (0..<rows).map { _ in rng.next() * 500.0 }
        return DataFrame(columns: [
            ("group", Column.fromStrings(groups)),
            ("value1", Column.fromDoubles(values)),
            ("value2", Column.fromDoubles(values2)),
        ])
    }

    /// Generates a CSV-formatted string with numeric data for I/O benchmarks.
    ///
    /// The output has a header row (`col0,col1,...`) followed by `rows` data rows.
    /// Each cell is formatted to 2 decimal places. The entire string is returned
    /// in memory (not written to disk) so that `readCSV` can parse it directly.
    ///
    /// - Parameters:
    ///   - rows: Number of data rows (excluding the header).
    ///   - cols: Number of columns.
    ///   - seed: LCG seed (default 42).
    /// - Returns: A multi-line CSV string.
    static func csvString(rows: Int, cols: Int, seed: UInt64 = 42) -> String {
        var rng = LCG(seed: seed)
        var lines: [String] = []
        let header = (0..<cols).map { "col\($0)" }.joined(separator: ",")
        lines.append(header)
        for _ in 0..<rows {
            let row = (0..<cols).map { _ in String(format: "%.2f", rng.next() * 1000.0) }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Test Methods
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Prints the benchmark suite header, methodology description, and section index.
    /// Runs first due to the `AA` prefix.
    @Test func testAA_BenchmarkHeader() {
        BenchmarkTests.banner("SWIFTPANDAS \(SwiftPandas.version) \u{2014} PERFORMANCE BENCHMARKS")

        print("")
        print("  Methodology")
        print("  " + String(repeating: "\u{2500}", count: BenchmarkTests.W - 4))
        BenchmarkTests.note("Each operation is run 3 times; the minimum time is reported.")
        BenchmarkTests.note("All times in microseconds (\u{00B5}s). All benchmarks at 1M rows (merge: 100K).")
        BenchmarkTests.note("Data is generated deterministically (LCG seeded random).")
        print("")

        print("  Benchmark Sections")
        print("  " + String(repeating: "\u{2500}", count: BenchmarkTests.W - 4))
        BenchmarkTests.note("1. Series Aggregation    \u{2014} sum, mean, std, min, max, median")
        BenchmarkTests.note("2. Series Arithmetic     \u{2014} element-wise +, *, scalar ops")
        BenchmarkTests.note("3. Series Sorting        \u{2014} sortValues at 1M")
        BenchmarkTests.note("4. Series Statistics     \u{2014} quantile, cumsum, valueCounts")
        BenchmarkTests.note("5. DataFrame Construction \u{2014} dict-based creation at 1M")
        BenchmarkTests.note("6. DataFrame Filtering   \u{2014} boolean mask at 1M")
        BenchmarkTests.note("7. DataFrame Sorting     \u{2014} single and multi-column at 1M")
        BenchmarkTests.note("8. DataFrame Aggregation \u{2014} sum, mean, std, describe at 1M")
        BenchmarkTests.note("9. GroupBy               \u{2014} sum, mean, count at 1M rows")
        BenchmarkTests.note("10. Merge                \u{2014} inner join at 100K")
        BenchmarkTests.note("11. Concat               \u{2014} vertical stacking (10 x 100K)")
        BenchmarkTests.note("12. CSV I/O              \u{2014} read and write at 1M")
    }

    // ─── 1. Series Aggregation ──────────────────────────────────────────

    /// Benchmarks Series aggregation functions (sum, mean, std, min, max, median) at 1M elements.
    ///
    /// These are backed by Accelerate vDSP on contiguous Double buffers. Median
    /// uses an O(n) quickselect algorithm with a raw-pointer inner loop.
    @Test func testBA_SeriesAggregation() {
        BenchmarkTests.section("1", "Series Aggregation (1,000,000 elements)")

        let data = BenchmarkTests.randomDoubles(1_000_000)
        let series = Series(data, name: "bench")

        BenchmarkTests.tableHeader()

        let tSum = BenchmarkTests.benchmark { _ = series.sum() }
        BenchmarkTests.benchRow("sum()", ns: tSum)

        let tMean = BenchmarkTests.benchmark { _ = series.mean() }
        BenchmarkTests.benchRow("mean()", ns: tMean)

        let tStd = BenchmarkTests.benchmark { _ = series.std() }
        BenchmarkTests.benchRow("std()", ns: tStd)

        let tMin = BenchmarkTests.benchmark { _ = series.min() }
        BenchmarkTests.benchRow("min()", ns: tMin)

        let tMax = BenchmarkTests.benchmark { _ = series.max() }
        BenchmarkTests.benchRow("max()", ns: tMax)

        let tMedian = BenchmarkTests.benchmark { _ = series.median() }
        BenchmarkTests.benchRow("median()", ns: tMedian)

        print("")
        BenchmarkTests.note("Accelerate vDSP SIMD on contiguous Double buffers.")
        BenchmarkTests.note("median uses O(n) quickselect with raw pointer inner loop.")
    }

    // ─── 2. Series Arithmetic ───────────────────────────────────────────

    /// Benchmarks element-wise and scalar arithmetic on 1M-element Series pairs.
    ///
    /// Operations tested: `Series + Series`, `Series * Series`, `Series + scalar`,
    /// `Series * scalar`. All are vectorized via Accelerate vDSP through the
    /// underlying `NullableArray<Double>`.
    @Test func testBB_SeriesArithmetic() {
        BenchmarkTests.section("2", "Series Arithmetic (1,000,000 elements)")

        let d1 = BenchmarkTests.randomDoubles(1_000_000, seed: 1)
        let d2 = BenchmarkTests.randomDoubles(1_000_000, seed: 2)
        let s1 = Series(d1, name: "a")
        let s2 = Series(d2, name: "b")

        BenchmarkTests.tableHeader()

        let tAdd = BenchmarkTests.benchmark { _ = s1 + s2 }
        BenchmarkTests.benchRow("Series + Series", ns: tAdd)

        let tMul = BenchmarkTests.benchmark { _ = s1 * s2 }
        BenchmarkTests.benchRow("Series * Series", ns: tMul)

        let tAddS = BenchmarkTests.benchmark { _ = s1 + 42.0 }
        BenchmarkTests.benchRow("Series + scalar", ns: tAddS)

        let tMulS = BenchmarkTests.benchmark { _ = s1 * 2.5 }
        BenchmarkTests.benchRow("Series * scalar", ns: tMulS)

        print("")
        BenchmarkTests.note("Accelerate vDSP vectorized operations via NullableArray<Double>.")
    }

    // ─── 3. Series Sorting ──────────────────────────────────────────────

    /// Benchmarks `Series.sortValues()` at 1M elements.
    ///
    /// Uses stdlib TimSort on an enumerated array followed by index rebuild.
    @Test func testBC_SeriesSorting() {
        BenchmarkTests.section("3", "Series Sorting (1,000,000 elements)")

        let d1M = BenchmarkTests.randomDoubles(1_000_000, seed: 11)
        let s1M = Series(d1M, name: "s1m")

        BenchmarkTests.tableHeader()

        let t1M = BenchmarkTests.benchmark { _ = s1M.sortValues() }
        BenchmarkTests.benchRow("1M elements", ns: t1M)

        print("")
        BenchmarkTests.note("stdlib TimSort on enumerated array + index rebuild.")
    }

    // ─── 4. Series Statistics ─────────────────────────────────────────

    /// Benchmarks extended statistics (quantile, cumsum, valueCounts) at 1M elements.
    ///
    /// - `quantile(0.75)`: O(n) quickselect with raw pointer inner loop.
    /// - `cumsum()`: single-pass O(n) accumulation.
    /// - `valueCounts()`: hash-based frequency counting.
    @Test func testBD_SeriesStatistics() {
        BenchmarkTests.section("4", "Series Statistics (1,000,000 elements)")

        let d1M = BenchmarkTests.randomDoubles(1_000_000, seed: 20)
        let s1M = Series(d1M, name: "stats")

        BenchmarkTests.tableHeader()

        let tQ = BenchmarkTests.benchmark { _ = s1M.quantile(0.75) }
        BenchmarkTests.benchRow("quantile(0.75)", ns: tQ)

        let tCum = BenchmarkTests.benchmark { _ = s1M.cumsum() }
        BenchmarkTests.benchRow("cumsum()", ns: tCum)

        let tVC = BenchmarkTests.benchmark { _ = s1M.valueCounts() }
        BenchmarkTests.benchRow("valueCounts()", ns: tVC)

        print("")
        BenchmarkTests.note("quantile: O(n) quickselect with raw pointer inner loop.")
        BenchmarkTests.note("cumsum: O(n) single pass.")
    }

    // ─── 5. DataFrame Construction ──────────────────────────────────────

    /// Benchmarks DataFrame construction from 1M rows x 6 columns of random doubles.
    ///
    /// Includes both LCG data generation and `ContiguousArray` allocation, so the
    /// reported time is an upper bound on pure construction cost.
    @Test func testCA_DataFrameConstruction() {
        BenchmarkTests.section("5", "DataFrame Construction (1M x 6 cols)")

        BenchmarkTests.tableHeader()

        let t1M = BenchmarkTests.benchmark {
            _ = BenchmarkTests.numericDataFrame(rows: 1_000_000, cols: 6, seed: 31)
        }
        BenchmarkTests.benchRow("1M rows x 6 cols", ns: t1M)

        print("")
        BenchmarkTests.note("Includes LCG data generation + ContiguousArray allocation.")
    }

    // ─── 6. DataFrame Filtering ─────────────────────────────────────────

    /// Benchmarks boolean-mask filtering on a 1M x 6 DataFrame with ~50% selectivity.
    ///
    /// The filter `df["col0"] > 500.0` selects roughly half the rows. The benchmark
    /// includes both mask generation (comparison -> `[Bool]`) and row extraction
    /// (`reserveCapacity` + `takeRows`).
    @Test func testCB_DataFrameFiltering() {
        BenchmarkTests.section("6", "DataFrame Filtering (1M x 6 cols)")

        let df1M = BenchmarkTests.numericDataFrame(rows: 1_000_000, cols: 6, seed: 41)

        BenchmarkTests.sub("df[df[\"col0\"] > 500.0]  (~50% selectivity)")
        BenchmarkTests.tableHeader()

        let t1M = BenchmarkTests.benchmark {
            let mask = df1M["col0"] > 500.0
            _ = df1M.filter(mask: mask)
        }
        BenchmarkTests.benchRow("1M rows x 6 cols", ns: t1M)

        print("")
        BenchmarkTests.note("comparison -> [Bool] mask, then reserveCapacity + takeRows.")
    }

    // ─── 7. DataFrame Sorting ───────────────────────────────────────────

    /// Benchmarks single-column and multi-column (2-key) DataFrame sorting at 1M x 6.
    ///
    /// Uses stdlib TimSort to compute a permutation array, then `takeRows` to
    /// allocate new columns in sorted order.
    @Test func testCC_DataFrameSorting() {
        BenchmarkTests.section("7", "DataFrame Sorting (1,000,000 rows x 6 cols)")

        let df = BenchmarkTests.numericDataFrame(rows: 1_000_000, cols: 6, seed: 50)

        BenchmarkTests.tableHeader()

        let tSingle = BenchmarkTests.benchmark {
            _ = df.sortValues(by: "col0")
        }
        BenchmarkTests.benchRow("Single column", ns: tSingle)

        let tMulti = BenchmarkTests.benchmark {
            _ = df.sortValues(by: ["col0", "col1"])
        }
        BenchmarkTests.benchRow("Multi-column (2 keys)", ns: tMulti)

        print("")
        BenchmarkTests.note("stdlib TimSort + takeRows (allocates new columns).")
    }

    // ─── 8. DataFrame Aggregation ───────────────────────────────────────

    /// Benchmarks column-wise aggregation (sum, mean, std, describe) on a 1M x 6 DataFrame.
    ///
    /// `describe()` computes 8 statistics per column (count, mean, std, min, 25%,
    /// 50%, 75%, max), so it is significantly more expensive than a single reduction.
    @Test func testCD_DataFrameAggregation() {
        BenchmarkTests.section("8", "DataFrame Aggregation (1,000,000 rows x 6 cols)")

        let df = BenchmarkTests.numericDataFrame(rows: 1_000_000, cols: 6, seed: 60)

        BenchmarkTests.tableHeader()

        let tSum = BenchmarkTests.benchmark { _ = df.sum() }
        BenchmarkTests.benchRow("sum()", ns: tSum)

        let tMean = BenchmarkTests.benchmark { _ = df.mean() }
        BenchmarkTests.benchRow("mean()", ns: tMean)

        let tStd = BenchmarkTests.benchmark { _ = df.std() }
        BenchmarkTests.benchRow("std()", ns: tStd)

        let tDesc = BenchmarkTests.benchmark { _ = df.describe() }
        BenchmarkTests.benchRow("describe()", ns: tDesc)

        print("")
        BenchmarkTests.note("describe() computes count, mean, std, min, 25%, 50%, 75%, max per column.")
    }

    // ─── 9. GroupBy ─────────────────────────────────────────────────────

    /// Benchmarks GroupBy aggregation (sum, mean, count) at 1M rows with 100 and 10 000 groups.
    ///
    /// The GroupBy engine uses a fused factorize+accumulate strategy with FNV-1a
    /// hashing and raw-pointer accumulators. The Metal GPU path is reserved for
    /// datasets >= 10M rows; at 1M rows the CPU fast-path is faster due to lower
    /// dispatch overhead.
    @Test func testCE_DataFrameGroupBy() {
        BenchmarkTests.section("9", "GroupBy (1,000,000 rows)")

        let df100 = BenchmarkTests.groupableDataFrame(rows: 1_000_000, nGroups: 100, seed: 70)
        let df10K = BenchmarkTests.groupableDataFrame(rows: 1_000_000, nGroups: 10_000, seed: 71)

        BenchmarkTests.sub("100 groups")
        BenchmarkTests.tableHeader()

        let gb100 = df100.groupBy("group")

        let tSum = BenchmarkTests.benchmark { _ = gb100.sum() }
        BenchmarkTests.benchRow("sum()", ns: tSum)

        let tMean = BenchmarkTests.benchmark { _ = gb100.mean() }
        BenchmarkTests.benchRow("mean()", ns: tMean)

        let tCount = BenchmarkTests.benchmark { _ = gb100.count() }
        BenchmarkTests.benchRow("count()", ns: tCount)

        BenchmarkTests.sub("10,000 groups")
        BenchmarkTests.tableHeader()

        let gb10K = df10K.groupBy("group")

        let tSum10K = BenchmarkTests.benchmark { _ = gb10K.sum() }
        BenchmarkTests.benchRow("sum()", ns: tSum10K)

        print("")
        BenchmarkTests.note("Fused factorize+accumulate with FNV-1a hash, raw pointer accumulators.")
        BenchmarkTests.note("Metal GPU reserved for >= 10M rows (CPU fast-path faster for typical workloads).")
    }

    // ─── 10. Merge ──────────────────────────────────────────────────────

    /// Benchmarks inner join (merge) on 100K-row DataFrames with ~50K distinct string keys.
    ///
    /// The merge implementation uses a typed `Dictionary<String, [Int]>` hash index
    /// on the right-side keys, then probes it for each left-side row. Key generation
    /// is deterministic but shuffled on the right side to simulate realistic join patterns.
    @Test func testCF_DataFrameMerge() {
        BenchmarkTests.section("10", "Merge (Inner Join, 100K rows)")

        var rng1 = BenchmarkTests.LCG(seed: 80)
        let keys = (0..<100_000).map { _ in "k\(rng1.nextInt(50_000))" }
        let vals1 = (0..<100_000).map { _ in rng1.next() * 100.0 }
        let vals2 = (0..<100_000).map { _ in rng1.next() * 100.0 }

        let left = DataFrame(columns: [
            ("key", Column.fromStrings(keys)),
            ("left_val", Column.fromDoubles(vals1)),
        ])
        let right = DataFrame(columns: [
            ("key", Column.fromStrings(Array(keys.shuffled().prefix(100_000)))),
            ("right_val", Column.fromDoubles(vals2)),
        ])

        BenchmarkTests.tableHeader()

        let t = BenchmarkTests.benchmark {
            _ = left.merge(right, on: "key")
        }
        BenchmarkTests.benchRow("100K x 100K", ns: t)

        print("")
        BenchmarkTests.note("typed hash on String keys (Dictionary<String,[Int]>).")
    }

    // ─── 11. Concat ─────────────────────────────────────────────────────

    /// Benchmarks vertical concatenation of 10 DataFrames, each 100K rows x 6 columns.
    ///
    /// Concat performs per-column array concatenation followed by new DataFrame
    /// construction. The total result is 1M rows.
    @Test func testCG_DataFrameConcat() {
        BenchmarkTests.section("11", "Concat (Vertical Stack)")

        let frames = (0..<10).map { i in
            BenchmarkTests.numericDataFrame(rows: 100_000, cols: 6, seed: UInt64(90 + i))
        }

        BenchmarkTests.tableHeader()

        let tConcat = BenchmarkTests.benchmark {
            _ = DataFrame.concat(frames)
        }
        BenchmarkTests.benchRow("10 x 100K rows", ns: tConcat)

        print("")
        BenchmarkTests.note("per-column array concatenation + new DataFrame construction.")
    }

    // ─── 12. CSV I/O ────────────────────────────────────────────────────

    /// Benchmarks CSV reading (string -> DataFrame) and writing (DataFrame -> string) at 1M x 6.
    ///
    /// The CSV reader uses a byte-level UTF-8 state machine parser with per-cell
    /// `Double(String)` conversion. The writer formats each cell and joins with
    /// separators. Both operate entirely in memory (no disk I/O).
    @Test func testDA_CSVIO() {
        BenchmarkTests.section("12", "CSV I/O (1M rows x 6 cols)")

        let csv1M = BenchmarkTests.csvString(rows: 1_000_000, cols: 6, seed: 100)

        BenchmarkTests.sub("Read CSV (string -> DataFrame)")
        BenchmarkTests.tableHeader()

        let tRead = BenchmarkTests.benchmark {
            _ = DataFrame.readCSV(csv1M)
        }
        BenchmarkTests.benchRow("1M rows x 6 cols", ns: tRead)

        // Build DataFrame for write benchmark
        let df = DataFrame.readCSV(csv1M)

        BenchmarkTests.sub("Write CSV (DataFrame -> string)")
        BenchmarkTests.tableHeader()

        let tWrite = BenchmarkTests.benchmark {
            _ = df.toCSV()
        }
        BenchmarkTests.benchRow("1M rows x 6 cols", ns: tWrite)

        print("")
        BenchmarkTests.note("byte-level UTF-8 state machine parser + Double(String) per cell.")
    }

    // ─── Lazy vs Eager ─────────────────────────────────────────────────

    /// Benchmarks lazy vs. eager execution for multi-step pipelines at 1M rows.
    ///
    /// Three pipeline patterns are compared:
    ///   1. Filter -> GroupBy -> Sum
    ///   2. Filter -> Select -> GroupBy -> Sum
    ///   3. Multi-filter chain (two consecutive filters)
    ///
    /// The lazy engine eliminates intermediate DataFrame allocations and applies
    /// optimizer passes (filter fusion, predicate pushdown, projection pushdown).
    @Test func testEA_LazyVsEager() {
        BenchmarkTests.section("13", "Lazy vs Eager (1M rows)")

        let df = BenchmarkTests.groupableDataFrame(rows: 1_000_000, nGroups: 100, seed: 77)

        BenchmarkTests.sub("Filter → GroupBy → Sum")
        BenchmarkTests.tableHeader()

        let tEager = BenchmarkTests.benchmark {
            let mask = df["value1"] > 500
            let filtered = df.filter(mask: mask)
            _ = filtered.groupBy("group").sum()
        }
        BenchmarkTests.benchRow("eager", ns: tEager)

        let tLazy = BenchmarkTests.benchmark {
            _ = df.lazy()
                .filter(col("value1") > 500)
                .groupBy("group").sum()
                .collect()
        }
        BenchmarkTests.benchRow("lazy", ns: tLazy)

        BenchmarkTests.sub("Filter → Select → GroupBy → Sum")
        BenchmarkTests.tableHeader()

        let tEager2 = BenchmarkTests.benchmark {
            let mask = df["value1"] > 500
            let filtered = df.filter(mask: mask)
            let selected = filtered.select(columns: ["group", "value1"])
            _ = selected.groupBy("group").sum()
        }
        BenchmarkTests.benchRow("eager", ns: tEager2)

        let tLazy2 = BenchmarkTests.benchmark {
            _ = df.lazy()
                .filter(col("value1") > 500)
                .select("group", "value1")
                .groupBy("group").sum()
                .collect()
        }
        BenchmarkTests.benchRow("lazy", ns: tLazy2)

        BenchmarkTests.sub("Multi-Filter Chain")
        BenchmarkTests.tableHeader()

        let tEager3 = BenchmarkTests.benchmark {
            let mask1 = df["value1"] > 200
            let f1 = df.filter(mask: mask1)
            let mask2 = f1["value1"] < 800
            _ = f1.filter(mask: mask2)
        }
        BenchmarkTests.benchRow("eager", ns: tEager3)

        let tLazy3 = BenchmarkTests.benchmark {
            _ = df.lazy()
                .filter(col("value1") > 200)
                .filter(col("value1") < 800)
                .collect()
        }
        BenchmarkTests.benchRow("lazy", ns: tLazy3)

        print("")
        BenchmarkTests.note("Lazy evaluation eliminates intermediate DataFrames.")
        BenchmarkTests.note("Optimizer applies: filter fusion, predicate pushdown, projection pushdown.")
    }

    // ─── Summary ────────────────────────────────────────────────────────

    /// Prints a summary of all optimizations applied by SwiftPandas and Metal GPU details.
    /// Runs last due to the `ZZ` prefix.
    @Test func testZZ_BenchmarkSummary() {
        BenchmarkTests.banner("BENCHMARK SUMMARY")

        print("")
        print("  Optimizations Applied")
        print("  " + String(repeating: "\u{2500}", count: BenchmarkTests.W - 4))
        BenchmarkTests.note("  + Accelerate/vDSP wired into NullableArray + NativeArray")
        BenchmarkTests.note("  + Factorize-based GroupBy with direct accumulation")
        BenchmarkTests.note("  + O(n) quickselect for median/quantile (raw pointer inner loop)")
        BenchmarkTests.note("  + Byte-level UTF-8 CSV parser")
        BenchmarkTests.note("  + Typed merge (Double/String hash, not String formatting)")
        BenchmarkTests.note("  + Metal GPU compute shaders for GroupBy/Merge (>= 500K rows)")
        BenchmarkTests.note("  + Lazy evaluation engine with query optimizer (filter fusion, pushdown)")
        print("")

        print("  Metal GPU Acceleration")
        print("  " + String(repeating: "\u{2500}", count: BenchmarkTests.W - 4))
        BenchmarkTests.note("  GroupBy: factorize -> GPU hash insert -> parallel reduction")
        BenchmarkTests.note("  Merge: co-factorize -> GPU hash build -> probe")
        BenchmarkTests.note("  Apple M-series unified memory eliminates CPU<->GPU copies")
        BenchmarkTests.note("  Activates automatically for datasets >= 500K rows")
        print("")

        BenchmarkTests.note("All times in microseconds (\u{00B5}s), best-of-3 runs.")
        BenchmarkTests.note("Run benchmarks/benchmark_pandas.py for side-by-side comparison with pandas.")
        print("")
    }
}
