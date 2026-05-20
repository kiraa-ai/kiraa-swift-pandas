import XCTest
@testable import SwiftPandas

/// Unit tests for `DataFrame.estimatedBytes`, the memory accounting helper
/// used by the resident-memory server's `list` and `drop` commands.
final class DataFrameMemoryTests: XCTestCase {

    func test_emptyDataFrame_hasZeroBytes() {
        let df = DataFrame()
        XCTAssertEqual(df.estimatedBytes, 0)
    }

    func test_doubleColumn_countsStride() {
        let df = DataFrame(["x": [1.0, 2.0, 3.0, 4.0]])
        // 4 doubles × 8 bytes = 32 bytes for the data buffer; bitmap and
        // column-name string add a few more. Just assert lower bound.
        XCTAssertGreaterThanOrEqual(df.estimatedBytes, 32)
    }

    func test_largerDataFrame_isLargerThanSmaller() {
        let small = DataFrame(["x": [1.0, 2.0]])
        let big   = DataFrame(["x": Array(repeating: 1.0, count: 10_000)])
        XCTAssertGreaterThan(big.estimatedBytes, small.estimatedBytes)
        // 10_000 doubles × 8 bytes alone is 80_000 bytes
        XCTAssertGreaterThanOrEqual(big.estimatedBytes, 80_000)
    }

    func test_multipleColumns_sumIndividualSizes() {
        let one  = DataFrame(["a": [1.0, 2.0, 3.0]])
        let two  = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        XCTAssertGreaterThan(two.estimatedBytes, one.estimatedBytes)
    }

    func test_columnNameOverheadCounted() {
        let shortName = DataFrame(["x": [1.0]])
        let longName  = DataFrame([String(repeating: "x", count: 100): [1.0]])
        XCTAssertGreaterThan(longName.estimatedBytes, shortName.estimatedBytes)
    }
}
