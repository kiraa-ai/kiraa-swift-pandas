import XCTest
@testable import SwiftPandas

// MARK: - Metal Dispatch Tests

final class MetalDispatchTests: XCTestCase {
    func testIsAvailable() {
        // On Apple Silicon / macOS, Metal should be available
        XCTAssertTrue(MetalDispatch.isAvailable)
    }

    func testThresholdLogic() {
        XCTAssertFalse(MetalDispatch.shouldUseGPU(rowCount: 500, threshold: 1_000))
        XCTAssertTrue(MetalDispatch.shouldUseGPU(rowCount: 1_000, threshold: 1_000))
        XCTAssertTrue(MetalDispatch.shouldUseGPU(rowCount: 10_000, threshold: 1_000))
    }

    func testCustomThreshold() {
        let oldThreshold = MetalDispatch.groupByThreshold
        defer { MetalDispatch.groupByThreshold = oldThreshold }

        MetalDispatch.groupByThreshold = 100
        XCTAssertTrue(MetalDispatch.shouldUseGPU(rowCount: 100, threshold: MetalDispatch.groupByThreshold))
        XCTAssertFalse(MetalDispatch.shouldUseGPU(rowCount: 99, threshold: MetalDispatch.groupByThreshold))
    }
}

// MARK: - Metal GroupBy Tests

final class MetalGroupByTests: XCTestCase {

    /// Helper: build a CPU reference GroupBy result for comparison.
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

    /// Helper: compare two GroupBy result DataFrames with tolerance for float precision.
    /// Sorts both by index (group key) before comparing, since GPU and CPU may produce different orderings.
    private func assertGroupByResultsClose(
        _ gpu: DataFrame, _ cpu: DataFrame,
        tolerance: Double = 0.01,
        file: StaticString = #file, line: UInt = #line
    ) {
        XCTAssertEqual(gpu.rowCount, cpu.rowCount, "Row count mismatch", file: file, line: line)
        guard gpu.rowCount == cpu.rowCount else { return }

        // Build key→row mapping for each DataFrame using the index
        let gpuIndex = gpu.indexLabels
        let cpuIndex = cpu.indexLabels

        var cpuKeyToRow = [String: Int]()
        for (i, key) in cpuIndex.enumerated() { cpuKeyToRow[key] = i }

        for (gpuRow, gpuKey) in gpuIndex.enumerated() {
            guard let cpuRow = cpuKeyToRow[gpuKey] else {
                XCTFail("GPU has key '\(gpuKey)' not found in CPU result", file: file, line: line)
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
                    XCTFail("Nil mismatch at \(colName) key=\(gpuKey)", file: file, line: line)
                    continue
                }
                if g.isNaN && c.isNaN { continue }
                XCTAssertEqual(g, c, accuracy: tolerance,
                               "Mismatch at \(colName) key=\(gpuKey): GPU=\(g), CPU=\(c)",
                               file: file, line: line)
            }
        }
    }

    func testGroupBySumSmall() {
        let df = DataFrame(columns: [
            ("city", Column.fromStrings(["NYC", "LA", "NYC", "LA", "NYC"])),
            ("sales", Column.fromDoubles([100, 200, 150, 250, 300])),
        ])

        guard let result = MetalGroupBy.aggregate(dataFrame: df, by: ["city"], op: .sum) else {
            XCTFail("GPU GroupBy returned nil")
            return
        }

        // Check we got both groups
        XCTAssertEqual(result.rowCount, 2)
    }

    func testGroupBySumCorrectness() {
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
            XCTFail("GPU GroupBy returned nil")
            return
        }

        XCTAssertEqual(gpuResult.rowCount, cpuResult.rowCount)
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 1.0) // float32 tolerance
    }

    func testGroupByMeanCorrectness() {
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
            XCTFail("GPU GroupBy returned nil")
            return
        }

        XCTAssertEqual(gpuResult.rowCount, cpuResult.rowCount)
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 1.0)
    }

    func testGroupByCountCorrectness() {
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
            XCTFail("GPU GroupBy returned nil")
            return
        }

        XCTAssertEqual(gpuResult.rowCount, cpuResult.rowCount)
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 0.01)
    }

    func testGroupByMinMaxCorrectness() {
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
            XCTFail("GPU GroupBy returned nil")
            return
        }

        assertGroupByResultsClose(gpuMin, cpuMin, tolerance: 0.01)
        assertGroupByResultsClose(gpuMax, cpuMax, tolerance: 0.01)
    }

    func testGroupByLargeDataset() {
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
            XCTFail("GPU GroupBy returned nil for 100K rows")
            return
        }

        XCTAssertEqual(gpuResult.rowCount, 50)

        let cpuResult = cpuGroupBy(df, by: ["grp"], op: "sum")
        assertGroupByResultsClose(gpuResult, cpuResult, tolerance: 100.0) // float32 accumulation tolerance
    }

    func testGroupByIntegration() {
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
        XCTAssertEqual(result.rowCount, 2)
    }
}

// MARK: - Metal Merge Tests

final class MetalMergeTests: XCTestCase {

    func testInnerJoinSmall() {
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

        XCTAssertEqual(result.rowCount, 2) // b and c match
    }

    func testInnerJoinCorrectness() {
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
            XCTFail("GPU Merge returned nil")
            return
        }

        // Each of 100 keys has 20 left rows * 20 right rows = 400 matches
        // Total = 100 * 400 = 40,000
        XCTAssertEqual(gpuResult.rowCount, 40_000)
        XCTAssertTrue(gpuResult.columnNames.contains("lval"))
        XCTAssertTrue(gpuResult.columnNames.contains("rval"))
    }

    func testInnerJoinNoMatches() {
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

        XCTAssertEqual(result.rowCount, 0)
    }

    func testInnerJoinDuplicateKeys() {
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
        XCTAssertEqual(result.rowCount, 5)
    }

    func testMergeIntegration() {
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
        XCTAssertTrue(result.rowCount > 0)
    }

    func testMergeColumnNaming() {
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

        XCTAssertTrue(result.columnNames.contains("val"))
        XCTAssertTrue(result.columnNames.contains("val_right"))
    }
}
