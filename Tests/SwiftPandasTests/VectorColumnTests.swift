import XCTest
@testable import SwiftPandas

/// R1 acceptance: VectorArray construction, invariants, Column/Series
/// integration, and accessors.
final class VectorColumnTests: XCTestCase {

    // MARK: - Construction

    func test_fromVectors_basic() throws {
        let col = try Column.fromVectors([[1, 2, 3], [4, 5, 6]], dims: 3)
        XCTAssertEqual(col.count, 2)
        XCTAssertEqual(col.validCount, 2)
        XCTAssertEqual(col.naCount, 0)
        guard case .floatVector(let array) = col else {
            return XCTFail("expected .floatVector")
        }
        XCTAssertEqual(array.dims, 3)
    }

    func test_fromVectors_dimensionMismatch_throws() {
        XCTAssertThrowsError(try Column.fromVectors([[1, 2], [1, 2, 3]], dims: 2)) { error in
            guard case VectorError.dimensionMismatch(let expected, let got) = error else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(got, 3)
        }
    }

    func test_fromVectors_invalidDims_throws() {
        XCTAssertThrowsError(try Column.fromVectors([], dims: 0)) { error in
            guard case VectorError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func test_fromOptionalVectors_nullsAreZeroFilledAndMasked() throws {
        let col = try Column.fromOptionalVectors([[1, 1], nil, [2, 2]], dims: 2)
        XCTAssertEqual(col.count, 3)
        XCTAssertEqual(col.validCount, 2)
        XCTAssertEqual(col.naCount, 1)
        XCTAssertEqual(col.isNA(), [false, true, false])
        guard case .floatVector(let array) = col else {
            return XCTFail("expected .floatVector")
        }
        // Normative invariant: null rows are zero-filled in the plane.
        array.plane.withUnsafeBufferPointer { buf in
            XCTAssertEqual(Array(buf[2..<4]), [0, 0])
        }
        XCTAssertNil(array.row(1))
        XCTAssertEqual(array.row(2), [2, 2])
    }

    // MARK: - DType

    func test_dtype_reportsDims() throws {
        let col = try Column.fromVectors([[Float](repeating: 0, count: 1024)], dims: 1024)
        XCTAssertEqual(col.dtype, .floatVector(dims: 1024))
        XCTAssertEqual(col.dtype.description, "floatVector(1024)")
        XCTAssertFalse(col.dtype.isNumeric)
        XCTAssertFalse(col.isNumeric)
        // Dims is part of type identity.
        XCTAssertNotEqual(DTypeEnum.floatVector(dims: 8), DTypeEnum.floatVector(dims: 16))
    }

    func test_dataFrame_dtypes_reportsVectorColumn() throws {
        let df = DataFrame(columns: [
            ("id", .fromInts([1, 2])),
            ("embedding", try .fromVectors([[1, 0], [0, 1]], dims: 2)),
        ])
        let dtype = df.dtypes.first { $0.name == "embedding" }?.dtype
        XCTAssertEqual(dtype, .floatVector(dims: 2))
    }

    // MARK: - Series accessors

    func test_series_accessors() throws {
        let series = try Series(vectors: [[1, 2], [3, 4]], dims: 2, name: "v")
        XCTAssertEqual(series.vectorDims, 2)
        XCTAssertEqual(series.vector(at: 0), [1, 2])
        XCTAssertEqual(series.vectors(), [[1, 2], [3, 4]])
    }

    func test_vectorDims_isNilForScalarSeries() {
        let series = Series([1.0, 2.0], name: "x")
        XCTAssertNil(series.vectorDims)
    }

    func test_withUnsafeVectorPlane_isZeroCopy() throws {
        let series = try Series(vectors: [[1, 2], [3, 4]], dims: 2, name: "v")
        guard case .floatVector(let array) = series.data else {
            return XCTFail("expected .floatVector")
        }
        let expectedBase = array.plane.withUnsafeBufferPointer { $0.baseAddress }
        series.withUnsafeVectorPlane { plane, dims in
            XCTAssertEqual(dims, 2)
            XCTAssertEqual(plane.count, 4)
            // Same base address as the underlying storage — no copy.
            XCTAssertEqual(plane.baseAddress, expectedBase)
        }
    }

    // MARK: - nbytes

    func test_nbytes_coversPlaneAndBitmap() throws {
        let col = try Column.fromVectors(
            Array(repeating: [Float](repeating: 1, count: 8), count: 100), dims: 8)
        // Plane: 100*8*4 = 3200 bytes, plus bitmap + norm cache.
        XCTAssertGreaterThanOrEqual(col.nbytes, 3200)
    }

    // MARK: - take / copy / concat

    func test_take_indices_gathersAndNullsOutOfRange() throws {
        let array = try VectorArray(vectors: [[1, 1], [2, 2], [3, 3]], dims: 2)
        let taken = array.take(indices: [2, 0, -1, 99])
        XCTAssertEqual(taken.count, 4)
        XCTAssertEqual(taken.row(0), [3, 3])
        XCTAssertEqual(taken.row(1), [1, 1])
        XCTAssertNil(taken.row(2))
        XCTAssertNil(taken.row(3))
        // Norm cache sliced correctly.
        taken.squaredNorms.withUnsafeBufferPointer { norms in
            XCTAssertEqual(norms[0], 18)
            XCTAssertEqual(norms[2], 0)
        }
    }

    func test_take_mask() throws {
        let array = try VectorArray(vectors: [[1, 1], [2, 2], [3, 3]], dims: 2)
        let taken = array.take(mask: [true, false, true], trueCount: 2)
        XCTAssertEqual(taken.count, 2)
        XCTAssertEqual(taken.row(0), [1, 1])
        XCTAssertEqual(taken.row(1), [3, 3])
    }

    func test_concat_matchingDims() throws {
        let a = try VectorArray(vectors: [[1, 1]], dims: 2)
        let b = try VectorArray(vectors: [[2, 2], nil], dims: 2)
        let combined = try VectorArray.concat([a, b])
        XCTAssertEqual(combined.count, 3)
        XCTAssertEqual(combined.row(1), [2, 2])
        XCTAssertNil(combined.row(2))
    }

    func test_concat_dimsMismatch_throws() throws {
        let a = try VectorArray(vectors: [[1, 1]], dims: 2)
        let b = try VectorArray(vectors: [[1, 1, 1]], dims: 3)
        XCTAssertThrowsError(try VectorArray.concat([a, b])) { error in
            guard case VectorError.dimensionMismatch = error else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
        }
    }

    func test_copy_isIndependentAndEqual() throws {
        let col = try Column.fromOptionalVectors([[1, 2], nil], dims: 2)
        let copied = col.copy()
        XCTAssertEqual(col, copied)
    }

    // MARK: - Norm cache

    func test_squaredNorms_cachedAtConstruction() throws {
        let array = try VectorArray(vectors: [[3, 4], nil, [0, 0]], dims: 2)
        array.squaredNorms.withUnsafeBufferPointer { norms in
            XCTAssertEqual(norms[0], 25)
            XCTAssertEqual(norms[1], 0)  // null row
            XCTAssertEqual(norms[2], 0)  // zero vector
        }
    }
}
