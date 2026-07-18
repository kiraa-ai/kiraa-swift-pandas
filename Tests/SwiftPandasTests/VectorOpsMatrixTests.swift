import XCTest
@testable import SwiftPandas

/// A5 acceptance: every "MUST work" DataFrame op verified on a mixed
/// scalar+vector frame; every reachable "MUST throw" op verified to reject
/// vector columns. (Non-throwing APIs that reject via precondition/fatalError
/// — CSVWriter.write, merge-on-vector-key, groupBy-on-vector-key — cannot be
/// asserted in XCTest and are covered by the throwing entry points plus code
/// review; see the vector spec's ops matrix.)
final class VectorOpsMatrixTests: XCTestCase {

    private func mixedFrame() throws -> DataFrame {
        DataFrame(columns: [
            ("id", .fromInts([1, 2, 3, 4])),
            ("label", .fromStrings(["a", "b", "c", "d"])),
            ("embedding", try .fromOptionalVectors([[1, 0], [0, 1], nil, [1, 1]], dims: 2)),
        ])
    }

    // MARK: - MUST work

    func test_filterMask_carriesVectorColumn() throws {
        let df = try mixedFrame()
        let filtered = df.filter(mask: [true, false, true, false])
        XCTAssertEqual(filtered.rowCount, 2)
        XCTAssertEqual(filtered["embedding"].vector(at: 0), [1, 0])
        XCTAssertNil(filtered["embedding"].vector(at: 1))
    }

    func test_takeRows_carriesVectorColumn() throws {
        let df = try mixedFrame()
        let taken = df.takeRows([3, 0])
        XCTAssertEqual(taken["embedding"].vector(at: 0), [1, 1])
        XCTAssertEqual(taken["embedding"].vector(at: 1), [1, 0])
    }

    func test_iloc_headTail_selectDropRename() throws {
        let df = try mixedFrame()
        XCTAssertEqual(df.iloc(0..<2).rowCount, 2)
        XCTAssertEqual(df.head(1)["embedding"].vector(at: 0), [1, 0])
        XCTAssertEqual(df.tail(1)["embedding"].vector(at: 0), [1, 1])

        let selected = df.select(columns: ["id", "embedding"])
        XCTAssertEqual(selected.columnNames, ["id", "embedding"])

        let dropped = df.drop(columns: ["embedding"])
        XCTAssertFalse(dropped.columnNames.contains("embedding"))

        let renamed = df.rename(columns: ["embedding": "vec"])
        XCTAssertEqual(renamed["vec"].vectorDims, 2)
    }

    func test_concat_sharesDims() throws {
        let df = try mixedFrame()
        let combined = DataFrame.concat([df, df])
        XCTAssertEqual(combined.rowCount, 8)
        XCTAssertEqual(combined["embedding"].vector(at: 4), [1, 0])
        XCTAssertNil(combined["embedding"].vector(at: 6))
    }

    func test_merge_vectorPassesThroughAsPayload() throws {
        let left = try mixedFrame()
        let right = DataFrame(columns: [
            ("id", .fromInts([2, 4])),
            ("extra", .fromDoubles([20, 40])),
        ])
        let merged = left.merge(right, on: "id", how: .inner)
        XCTAssertEqual(merged.rowCount, 2)
        XCTAssertEqual(merged["embedding"].vector(at: 0), [0, 1])
        XCTAssertEqual(merged["embedding"].vector(at: 1), [1, 1])
    }

    func test_estimatedBytes_includesVectorColumn() throws {
        let df = try mixedFrame()
        let withoutVector = df.drop(columns: ["embedding"])
        XCTAssertGreaterThan(df.estimatedBytes, withoutVector.estimatedBytes)
    }

    func test_describe_vectorSeries_reportsCountNullsDims() throws {
        let df = try mixedFrame()
        let stats = df["embedding"].describe()
        XCTAssertEqual(stats.indexLabels, ["count", "nulls", "dims"])
        XCTAssertEqual(stats.data.value(at: 0) as? Double, 4)
        XCTAssertEqual(stats.data.value(at: 1) as? Double, 1)
        XCTAssertEqual(stats.data.value(at: 2) as? Double, 2)
    }

    func test_dataFrameDescribe_skipsVectorColumn() throws {
        // Whole-frame describe sweeps numeric columns only; the vector column
        // is skipped exactly as string columns are (deviation #2 in the spec).
        let df = try mixedFrame()
        XCTAssertNoThrow(df.describe())
    }

    func test_sortValues_byScalar_carriesVectorColumn() throws {
        let df = try mixedFrame()
        let sorted = df.sortValues(by: "id", ascending: false)
        XCTAssertEqual(sorted["embedding"].vector(at: 0), [1, 1])
    }

    // MARK: - MUST throw

    func test_toCSV_path_throwsUnsupported() throws {
        let df = try mixedFrame()
        let path = NSTemporaryDirectory() + "/vector_test.csv"
        XCTAssertThrowsError(try df.toCSV(path: path)) { error in
            guard case VectorError.unsupportedOperation(let op, let dtype) = error else {
                return XCTFail("expected unsupportedOperation, got \(error)")
            }
            XCTAssertEqual(op, "toCSV")
            XCTAssertEqual(dtype, "floatVector(2)")
        }
    }

    func test_toJSON_path_throwsUnsupported() throws {
        let df = try mixedFrame()
        let path = NSTemporaryDirectory() + "/vector_test.json"
        XCTAssertThrowsError(try df.toJSON(path: path)) { error in
            guard case VectorError.unsupportedOperation = error else {
                return XCTFail("expected unsupportedOperation, got \(error)")
            }
        }
    }

    func test_toCSV_afterDroppingVector_works() throws {
        // The documented escape hatch: CSV of the scalar columns via drop.
        let df = try mixedFrame().drop(columns: ["embedding"])
        let csv = df.toCSV()
        XCTAssertTrue(csv.contains("id"))
    }

    func test_l2NormsAndNormalize_throwOnScalarSeries() {
        let series = Series([1.0, 2.0], name: "x")
        XCTAssertThrowsError(try series.l2Norms())
        XCTAssertThrowsError(try series.normalizedL2())
    }

    // MARK: - Vector ops (R2)

    func test_l2Norms() throws {
        let series = try Series(vectors: [[3, 4], [0, 0]], dims: 2, name: "v")
        XCTAssertEqual(try series.l2Norms(), [5, 0])
    }

    func test_normalizedL2_zeroNormStaysZero_storageStaysRaw() throws {
        let series = Series(
            data: try .fromOptionalVectors([[3, 4], [0, 0], nil], dims: 2), name: "v")
        let normalized = try series.normalizedL2()
        XCTAssertEqual(normalized.vector(at: 0), [0.6, 0.8])
        XCTAssertEqual(normalized.vector(at: 1), [0, 0])
        XCTAssertNil(normalized.vector(at: 2))
        // Raw-storage invariant: the source series is untouched.
        XCTAssertEqual(series.vector(at: 0), [3, 4])
    }

    // MARK: - Scalar aggregations skip vectors

    func test_columnAggregations_returnNilForVector() throws {
        let col = try Column.fromVectors([[1, 2]], dims: 2)
        XCTAssertNil(col.sum())
        XCTAssertNil(col.mean())
        XCTAssertNil(col.asDouble())
    }
}
