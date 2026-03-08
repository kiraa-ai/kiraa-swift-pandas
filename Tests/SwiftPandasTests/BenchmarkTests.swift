import XCTest
@testable import SwiftPandas
import Foundation

/// Performance benchmarks — SwiftPandas measured live.
/// All benchmarks at 1M rows (100K for merge). Times in nanoseconds.
/// Run with: swift test --filter BenchmarkTests
final class BenchmarkTests: XCTestCase {

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Formatting helpers                                                │
    // └─────────────────────────────────────────────────────────────────────┘

    static let W = 80

    static func banner(_ title: String) {
        let pad = max(0, W - title.count - 4)
        let left = pad / 2
        let right = pad - left
        print("")
        print("\u{2554}" + String(repeating: "\u{2550}", count: W) + "\u{2557}")
        print("\u{2551}" + String(repeating: " ", count: left) + "  " + title + String(repeating: " ", count: right) + "  \u{2551}")
        print("\u{255A}" + String(repeating: "\u{2550}", count: W) + "\u{255D}")
    }

    static func section(_ num: String, _ title: String) {
        print("")
        print("  \u{250C}" + String(repeating: "\u{2500}", count: W - 4) + "\u{2510}")
        print("  \u{2502}  \(num). \(title)" + String(repeating: " ", count: max(0, W - 8 - num.count - title.count)) + "\u{2502}")
        print("  \u{2514}" + String(repeating: "\u{2500}", count: W - 4) + "\u{2518}")
    }

    static func sub(_ title: String) {
        print("\n  \u{25B6} \(title)")
        print("  " + String(repeating: "\u{2500}", count: W - 4))
    }

    static func note(_ text: String) {
        print("    \u{2502} \(text)")
    }

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Benchmark table — all times in microseconds (µs)                   │
    // └─────────────────────────────────────────────────────────────────────┘

    static func tableHeader() {
        let op = "Operation".padding(toLength: 26, withPad: " ", startingAt: 0)
        let swift = "Swift (\u{00B5}s)".padding(toLength: 20, withPad: " ", startingAt: 0)
        let extra = "Details"
        print("    \u{25B8} \(op) \(swift) \(extra)")
        print("    " + String(repeating: "\u{2500}", count: W - 8))
    }

    static func benchRow(_ op: String, ns: Double, detail: String = "") {
        let name = op.padding(toLength: 26, withPad: " ", startingAt: 0)
        let t = formatUs(ns).padding(toLength: 20, withPad: " ", startingAt: 0)
        print("      \(name) \(t) \(detail)")
    }

    static func formatUs(_ ns: Double) -> String {
        let us = ns / 1000.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        formatter.groupingSeparator = ","
        return (formatter.string(from: NSNumber(value: us)) ?? String(format: "%.3f", us)) + " \u{00B5}s"
    }

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Timing & data generation                                          │
    // └─────────────────────────────────────────────────────────────────────┘

    /// Time a block, running it `iterations` times and returning the minimum in nanoseconds.
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

    /// Simple LCG for deterministic pseudo-random doubles in [0, 1).
    struct LCG {
        var state: UInt64

        init(seed: UInt64 = 42) {
            state = seed
        }

        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func nextInt(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }
    }

    /// Generate an array of random doubles.
    static func randomDoubles(_ count: Int, seed: UInt64 = 42) -> [Double] {
        var rng = LCG(seed: seed)
        return (0..<count).map { _ in rng.next() * 1000.0 }
    }

    /// Generate a numeric DataFrame with `cols` columns of `rows` random doubles.
    static func numericDataFrame(rows: Int, cols: Int, seed: UInt64 = 42) -> DataFrame {
        var rng = LCG(seed: seed)
        var columns: [(String, Column)] = []
        for c in 0..<cols {
            let data = (0..<rows).map { _ in rng.next() * 1000.0 }
            columns.append(("col\(c)", Column.fromDoubles(data)))
        }
        return DataFrame(columns: columns)
    }

    /// Generate a DataFrame with a string "group" column and numeric columns.
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

    /// Generate a CSV string with numeric data.
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

    func testAA_BenchmarkHeader() {
        BenchmarkTests.banner("SWIFTPANDAS 0.1.0 \u{2014} PERFORMANCE BENCHMARKS")

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

    func testBA_SeriesAggregation() {
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

    func testBB_SeriesArithmetic() {
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

    func testBC_SeriesSorting() {
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

    func testBD_SeriesStatistics() {
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

    func testCA_DataFrameConstruction() {
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

    func testCB_DataFrameFiltering() {
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

    func testCC_DataFrameSorting() {
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

    func testCD_DataFrameAggregation() {
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

    func testCE_DataFrameGroupBy() {
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

    func testCF_DataFrameMerge() {
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

    func testCG_DataFrameConcat() {
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

    func testDA_CSVIO() {
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

    func testEA_LazyVsEager() {
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

    func testZZ_BenchmarkSummary() {
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
        BenchmarkTests.note("Run benchmark_pandas.py for side-by-side comparison with pandas.")
        print("")
    }
}
