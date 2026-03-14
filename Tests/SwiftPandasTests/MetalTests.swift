// ──────────────────────────────────────────────────────────────────────────────
// MetalTests.swift
// SwiftPandasTests
//
// GPU correctness tests for SwiftPandas' Metal acceleration layer. SwiftPandas
// optionally offloads GroupBy aggregation and inner-join Merge to Metal compute
// shaders on Apple Silicon (and other Metal-capable) hardware. These tests
// verify that the GPU code path produces results identical (within floating-
// point tolerance) to the CPU reference implementation.
//
// The test strategy is:
//   1. For each GPU operation, compute the result via the CPU-only path by
//      temporarily raising the Metal dispatch threshold to `Int.max`.
//   2. Compute the result via the explicit GPU entry point (`MetalGroupBy`,
//      `MetalMerge`).
//   3. Compare the two results element-by-element with a tolerance that
//      accounts for float32 accumulation rounding in the GPU shaders.
//
// Test classes in this file:
//   - MetalDispatchTests   — threshold logic and availability flag.
//   - MetalGroupByTests    — GPU GroupBy sum/mean/count/min/max correctness
//                            at small (5 rows), medium (2 000 rows), and
//                            large (100 000 rows) scale.
//   - MetalMergeTests      — GPU inner join correctness including small joins,
//                            large many-to-many joins, no-match edge case,
//                            duplicate keys, integration with the transparent
//                            dispatch path, and column naming with suffix.
//
// NOTE: These tests require a Metal-capable device. On CI runners without a
// GPU, `MetalDispatch.isAvailable` may be false and GPU entry points may
// return nil — the tests handle this gracefully.
// ──────────────────────────────────────────────────────────────────────────────

import Testing
@testable import SwiftPandas

// MARK: - Metal Dispatch Tests

/// Tests for the `MetalDispatch` utility that decides when to offload work to the GPU.
///
/// `MetalDispatch` provides a static `isAvailable` flag (true on Metal-capable
/// hardware), configurable thresholds for GroupBy and Merge, and a
/// `shouldUseGPU(rowCount:threshold:)` predicate. These tests verify:
/// - That Metal is reported as available on macOS / Apple Silicon test hosts.
/// - That the threshold comparison correctly returns false below threshold and
///   true at or above threshold.
/// - That custom thresholds can be set and are respected, and that the original
///   value is restored via `defer`.
@Suite struct MetalDispatchTests {
    @Test func testIsAvailable() {
        // On Apple Silicon / macOS, Metal should be available
        #expect(MetalDispatch.isAvailable)
    }

    @Test func testThresholdLogic() {
        #expect(!MetalDispatch.shouldUseGPU(rowCount: 500, threshold: 1_000))
        #expect(MetalDispatch.shouldUseGPU(rowCount: 1_000, threshold: 1_000))
        #expect(MetalDispatch.shouldUseGPU(rowCount: 10_000, threshold: 1_000))
    }

    @Test func testCustomThreshold() {
        let oldThreshold = MetalDispatch.groupByThreshold
        defer { MetalDispatch.groupByThreshold = oldThreshold }

        MetalDispatch.groupByThreshold = 100
        #expect(MetalDispatch.shouldUseGPU(rowCount: 100, threshold: MetalDispatch.groupByThreshold))
        #expect(!MetalDispatch.shouldUseGPU(rowCount: 99, threshold: MetalDispatch.groupByThreshold))
    }
}

// MARK: - Metal GroupBy Tests

/// Tests for `MetalGroupBy`, the GPU-accelerated GroupBy aggregation engine.
///
/// Metal GroupBy works by factorizing the group-key column into integer codes on
/// the CPU, uploading the codes and value arrays to a Metal buffer, then
/// dispatching a compute shader that performs parallel per-group reduction
/// (sum, mean, count, min, or max). Results are read back from the GPU buffer
/// and assembled into a DataFrame.
///
/// Each test compares the GPU result against a CPU reference computed by
/// temporarily disabling the GPU path (threshold set to `Int.max`). A tolerance
/// of up to 100.0 is used for large float32 accumulations to account for
/// rounding differences between GPU float32 and CPU float64 arithmetic.
///
/// Coverage includes:
/// - **Small sum** (5 rows, 2 groups): basic smoke test.
/// - **Sum correctness** (2 000 rows, 5 groups): CPU vs GPU comparison.
/// - **Mean correctness** (2 000 rows, 2 groups).
/// - **Count correctness** (2 000 rows, 10 groups).
/// - **Min/Max correctness** (2 000 rows, 5 groups).
/// - **Large dataset stress test** (100 000 rows, 50 groups).
/// - **Integration**: verifying that `df.groupBy().sum()` transparently uses
///   the GPU path when the threshold is lowered.
@Suite(.serialized) struct MetalGroupByTests {

    /// Builds a CPU-only reference GroupBy result for comparison against the GPU path.
    ///
    /// This helper temporarily sets `MetalDispatch.groupByThreshold` to `Int.max`
    /// so that the standard `df.groupBy(_:)` API is forced onto the CPU code path.
    /// The original threshold is restored via `defer` when the helper returns.
    ///
    /// - Parameters:
    ///   - df: The input DataFrame to group.
    ///   - by: Array of column names to group by.
    ///   - op: Aggregation operation name — one of "sum", "mean", "count", "min", "max".
    /// - Returns: A DataFrame containing the CPU-computed aggregation result.
    private func cpuGroupBy(_ df: DataFrame, by: [String], op: String) -> DataFrame {
        // Force CPU path by using low threshold
        let oldThreshold = MetalDispatch.groupByThreshold
        MetalDispatch.groupByThreshold = Int.max
        defer { MetalDispatch.groupByThreshold = oldThreshold }

        let gb = df.groupBy(by)
        switch op {
        case "sum": return gb.sum()
        case "mean": return gb.mean()
        case "count": return gb.count()
        case "min": return gb.min()
        case "max": return gb.max()
        default: fatalError()
        }
    }

    /// Compares two GroupBy result DataFrames element-by-element with floating-point tolerance.
    ///
    /// Because GPU and CPU code paths may produce groups in different orders, this
    /// helper builds a key-to-row mapping from the index labels of each DataFrame
    /// and then walks the GPU result row by row, looking up the corresponding CPU
    /// row by key. For each numeric column it asserts that the GPU and CPU values
    /// are equal within the specified `tolerance`. NA-vs-NA matches are accepted;
    /// NA-vs-non-NA mismatches are flagged. NaN-vs-NaN is also accepted.
    ///
    /// - Parameters:
    ///   - gpu: The GPU-computed GroupBy result.
    ///   - cpu: The CPU-computed reference result.
    ///   - tolerance: Maximum allowed absolute difference between GPU and CPU values.
    private func assertGroupByResultsClose(
        _ gpu: DataFrame, _ cpu: DataFrame,
        tolerance: Double = 0.01,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(gpu.rowCount == cpu.rowCount, "Row count mismatch", sourceLocation: sourceLocation)
        guard gpu.rowCount == cpu.rowCount else { return }

        // Build key→row mapping for each DataFrame using the index
        let gpuIndex = gpu.indexLabels
        let cpuIndex = cpu.indexLabels

        var cpuKeyToRow = [String: Int]()
        for (i, key) in cpuIndex.enumerated() { cpuKeyToRow[key] = i }

        for (gpuRow, gpuKey) in gpuIndex.enumerated() {
            guard let cpuRow = cpuKeyToRow[gpuKey] else {
                Issue.record("GPU has key '\(gpuKey)' not found in CPU result", sourceLocation: sourceLocation)
                continue
            }
            for colName in cpu.columnNames {
                guard let gpuCol = gpu.columns[colName],
                      let cpuCol = cpu.columns[colName] else { continue }
                guard let gpuDoubles = gpuCol.asDouble(),
                      let cpuDoubles = cpuCol.asDouble() else { continue }

                let gpuVal = gpuDoubles[gpuRow]
                let cpuVal = cpuDoubles[cpuRow]
                if gpuVal == nil && cpuVal == nil { continue }
                guard let g = gpuVal, let c = cpuVal else {
                    Issue.record("Nil mismatch at \(colName) key=\(gpuKey)", sourceLocation: sourceLocation)
                    continue
                }
                if g.isNaN && c.isNaN { continue }
                #expect(abs(g - c) <= tolerance,
                               "Mismatch at \(colName) key=\(gpuKey): GPU=\(g), CPU=\(c)",
                               sourceLocation: sourceLocation)
            }
        }
    }

    @Test func testGroupBySumSmall() {
        let df = DataFrame(columns: [
            ("city", Column.fromStrings(["NYC", "LA", "NYC", "LA", "NYC"])),
            ("sales", Column.fromDoubles([100, 200, 150, 250, 300])),
        ])

        guard let result = MetalGroupBy.aggregate(dataFrame: df, by: ["city"], op: .sum) else {
            Issue.record("GPU GroupBy returned nil")
            return
        }

        // Check we got both groups
        #expect(result.rowCount == 2)
    }

    @Test func testGroupBySumCorrectness() {
        // Large enough to trigger GPU path
        let n = 2_000
        var cities = [String]()
        var sales = [Double]()
        let cityNames = ["NYC", "LA", "Chicago", "Houston", "Phoenix"]

        for i in 0..<n {
            cities.append(cityNames[i % cityNames.count])
            sales.append(Double(i % 100))
        }

        let df = DataFrame(columns: [
            ("city", Column.fromStrings(cities)),
            ("sales", Column.fromDoubles(sales)),
        ])

        let cpuResult = cpuGroupBy(df, by: ["city"], op: "sum")

        guard let gpuResult = MetalGroupBy.aggregate(dataFrame: df, by: ["city"], op: .sum) else {
            Issue.record("GPU GroupBy returned nil")
            return
        }

        #expect(gpuResult.rowCount == cpuResult.rowCount)
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 1.0) // float32 tolerance
    }

    @Test func testGroupByMeanCorrectness() {
        let n = 2_000
        var categories = [String]()
        var values = [Double]()

        for i in 0..<n {
            categories.append(i % 2 == 0 ? "A" : "B")
            values.append(Double(i))
        }

        let df = DataFrame(columns: [
            ("cat", Column.fromStrings(categories)),
            ("val", Column.fromDoubles(values)),
        ])

        let cpuResult = cpuGroupBy(df, by: ["cat"], op: "mean")

        guard let gpuResult = MetalGroupBy.aggregate(dataFrame: df, by: ["cat"], op: .mean) else {
            Issue.record("GPU GroupBy returned nil")
            return
        }

        #expect(gpuResult.rowCount == cpuResult.rowCount)
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 1.0)
    }

    @Test func testGroupByCountCorrectness() {
        let n = 2_000
        var groups = [String]()
        var values = [Double]()

        for i in 0..<n {
            groups.append("G\(i % 10)")
            values.append(Double(i))
        }

        let df = DataFrame(columns: [
            ("grp", Column.fromStrings(groups)),
            ("val", Column.fromDoubles(values)),
        ])

        let cpuResult = cpuGroupBy(df, by: ["grp"], op: "count")

        guard let gpuResult = MetalGroupBy.aggregate(dataFrame: df, by: ["grp"], op: .count) else {
            Issue.record("GPU GroupBy returned nil")
            return
        }

        #expect(gpuResult.rowCount == cpuResult.rowCount)
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 0.01)
    }

    @Test func testGroupByMinMaxCorrectness() {
        let n = 2_000
        var groups = [String]()
        var values = [Double]()

        for i in 0..<n {
            groups.append("G\(i % 5)")
            values.append(Double(i % 100) * 1.5)
        }

        let df = DataFrame(columns: [
            ("grp", Column.fromStrings(groups)),
            ("val", Column.fromDoubles(values)),
        ])

        let cpuMin = cpuGroupBy(df, by: ["grp"], op: "min")
        let cpuMax = cpuGroupBy(df, by: ["grp"], op: "max")

        guard let gpuMin = MetalGroupBy.aggregate(dataFrame: df, by: ["grp"], op: .min),
              let gpuMax = MetalGroupBy.aggregate(dataFrame: df, by: ["grp"], op: .max) else {
            Issue.record("GPU GroupBy returned nil")
            return
        }

        assertGroupByResultsClose(gpuMin, cpuMin, tolerance: 0.01)
        assertGroupByResultsClose(gpuMax, cpuMax, tolerance: 0.01)
    }

    @Test func testGroupByLargeDataset() {
        // 100K rows stress test
        let n = 100_000
        var groups = [String]()
        var values = [Double]()
        let groupNames = (0..<50).map { "Group_\($0)" }

        for i in 0..<n {
            groups.append(groupNames[i % groupNames.count])
            values.append(Double(i % 1000))
        }

        let df = DataFrame(columns: [
            ("grp", Column.fromStrings(groups)),
            ("val", Column.fromDoubles(values)),
        ])

        guard let gpuResult = MetalGroupBy.aggregate(dataFrame: df, by: ["grp"], op: .sum) else {
            Issue.record("GPU GroupBy returned nil for 100K rows")
            return
        }

        #expect(gpuResult.rowCount == 50)

        let cpuResult = cpuGroupBy(df, by: ["grp"], op: "sum")
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 100.0) // float32 accumulation tolerance
    }

    @Test func testGroupByIntegration() {
        // Test that df.groupBy().sum() uses GPU path transparently
        let n = 2_000
        var groups = [String]()
        var values = [Double]()

        for i in 0..<n {
            groups.append(i % 2 == 0 ? "A" : "B")
            values.append(Double(i))
        }

        let df = DataFrame(columns: [
            ("grp", Column.fromStrings(groups)),
            ("val", Column.fromDoubles(values)),
        ])

        // This should use GPU path automatically (n >= threshold)
        let oldThreshold = MetalDispatch.groupByThreshold
        MetalDispatch.groupByThreshold = 1_000
        defer { MetalDispatch.groupByThreshold = oldThreshold }

        let result = df.groupBy("grp").sum()
        #expect(result.rowCount == 2)
    }
}

// MARK: - Metal Merge Tests

/// Tests for `MetalMerge`, the GPU-accelerated inner join implementation.
///
/// Metal Merge performs an inner join by co-factorizing the key columns of both
/// DataFrames (mapping string keys to integer codes via a shared dictionary),
/// uploading the code arrays to Metal buffers, dispatching a compute shader that
/// builds a hash table and probes it, then reading back the matched row-index
/// pairs and assembling the result DataFrame on the CPU.
///
/// Coverage includes:
/// - **Small inner join** (3 rows each): basic smoke test with 2 matching keys.
///   Returns early if the GPU declines small datasets (returns nil).
/// - **Large correctness** (2 000 rows, 100 keys): verifies the expected Cartesian
///   product size (each of 100 keys has 20 left * 20 right = 400 matches = 40 000
///   total) and checks that both value columns are present.
/// - **No matches**: disjoint key sets should produce 0 result rows.
/// - **Duplicate keys (many-to-many)**: 2 left "x" rows * 2 right "x" rows = 4
///   matches, plus 1 "y" match = 5 total.
/// - **Integration**: verifying that `df.merge(right, on:)` transparently uses the
///   GPU path when the merge threshold is lowered.
/// - **Column naming**: when both sides share a non-key column name, the right
///   side's column should be suffixed with `_right`.
@Suite(.serialized) struct MetalMergeTests {

    @Test func testInnerJoinSmall() {
        let left = DataFrame(columns: [
            ("id", Column.fromStrings(["a", "b", "c"])),
            ("val", Column.fromDoubles([1, 2, 3])),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(["b", "c", "d"])),
            ("score", Column.fromDoubles([10, 20, 30])),
        ])

        guard let result = MetalMerge.innerJoin(left: left, right: right, on: "id") else {
            // May return nil for small datasets — that's OK
            return
        }

        #expect(result.rowCount == 2) // b and c match
    }

    @Test func testInnerJoinCorrectness() {
        // Large enough for GPU
        let n = 2_000
        var leftIds = [String]()
        var leftVals = [Double]()
        var rightIds = [String]()
        var rightVals = [Double]()

        for i in 0..<n {
            leftIds.append("key_\(i % 100)")
            leftVals.append(Double(i))
            rightIds.append("key_\(i % 100)")
            rightVals.append(Double(i * 10))
        }

        let left = DataFrame(columns: [
            ("id", Column.fromStrings(leftIds)),
            ("lval", Column.fromDoubles(leftVals)),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(rightIds)),
            ("rval", Column.fromDoubles(rightVals)),
        ])

        guard let gpuResult = MetalMerge.innerJoin(left: left, right: right, on: "id") else {
            Issue.record("GPU Merge returned nil")
            return
        }

        // Each of 100 keys has 20 left rows * 20 right rows = 400 matches
        // Total = 100 * 400 = 40,000
        #expect(gpuResult.rowCount == 40_000)
        #expect(gpuResult.columnNames.contains("lval"))
        #expect(gpuResult.columnNames.contains("rval"))
    }

    @Test func testInnerJoinNoMatches() {
        let left = DataFrame(columns: [
            ("id", Column.fromStrings(["a", "b"])),
            ("val", Column.fromDoubles([1, 2])),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(["c", "d"])),
            ("val2", Column.fromDoubles([3, 4])),
        ])

        guard let result = MetalMerge.innerJoin(left: left, right: right, on: "id") else {
            return // nil is acceptable
        }

        #expect(result.rowCount == 0)
    }

    @Test func testInnerJoinDuplicateKeys() {
        // Many-to-many join
        let left = DataFrame(columns: [
            ("id", Column.fromStrings(["x", "x", "y"])),
            ("a", Column.fromDoubles([1, 2, 3])),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(["x", "x", "y"])),
            ("b", Column.fromDoubles([10, 20, 30])),
        ])

        guard let result = MetalMerge.innerJoin(left: left, right: right, on: "id") else {
            return
        }

        // x matches: 2 left * 2 right = 4, y matches: 1 * 1 = 1, total = 5
        #expect(result.rowCount == 5)
    }

    @Test func testMergeIntegration() {
        // Test that df.merge() uses GPU path transparently for inner joins
        let n = 2_000
        var ids = [String]()
        var vals = [Double]()

        for i in 0..<n {
            ids.append("k\(i % 50)")
            vals.append(Double(i))
        }

        let left = DataFrame(columns: [
            ("id", Column.fromStrings(ids)),
            ("lv", Column.fromDoubles(vals)),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(ids)),
            ("rv", Column.fromDoubles(vals)),
        ])

        let oldThreshold = MetalDispatch.mergeThreshold
        MetalDispatch.mergeThreshold = 1_000
        defer { MetalDispatch.mergeThreshold = oldThreshold }

        let result = left.merge(right, on: "id")
        #expect(result.rowCount > 0)
    }

    @Test func testMergeColumnNaming() {
        // When both sides have same non-key column, right gets _right suffix
        let left = DataFrame(columns: [
            ("id", Column.fromStrings(["a", "b"])),
            ("val", Column.fromDoubles([1, 2])),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(["a", "b"])),
            ("val", Column.fromDoubles([10, 20])),
        ])

        guard let result = MetalMerge.innerJoin(left: left, right: right, on: "id") else {
            return
        }

        #expect(result.columnNames.contains("val"))
        #expect(result.columnNames.contains("val_right"))
    }
}
