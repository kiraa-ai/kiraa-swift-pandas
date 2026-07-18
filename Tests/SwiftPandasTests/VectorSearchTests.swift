import XCTest
@testable import SwiftPandas

/// A1 (numeric pins) + A2 (determinism) acceptance for CPU similarity search.
final class VectorSearchTests: XCTestCase {

    private func frame(_ vectors: [[Float]?], dims: Int) throws -> DataFrame {
        DataFrame(columns: [
            ("id", .fromInts(Array(0..<vectors.count))),
            ("embedding", try .fromOptionalVectors(vectors, dims: dims)),
        ])
    }

    private func scores(_ result: SearchResultFrame) -> [Double] {
        guard case .double(let a) = result.frame["__score"].data else { return [] }
        return (0..<a.count).map { a[$0]! }
    }

    private func ids(_ result: SearchResultFrame) -> [Int64] {
        guard case .int64(let a) = result.frame["id"].data else { return [] }
        return (0..<a.count).map { a[$0]! }
    }

    // MARK: - A1 numeric pins (exact, per the bit-parity contract)

    func test_cosine_identicalVectors_isExactlyOne() throws {
        // Note: the exactness pin holds under the normative §4.2 float order
        // when norm² has an exact Float sqrt ([3,4] -> 25 -> 5). For general
        // vectors ([1,2,3]) sqrt(14)² rounds to 14.000001 in Float32 and the
        // pinned order — deliberately — does not fudge it back to 1.0.
        let df = try frame([[3, 4]], dims: 2)
        let result = try df.similaritySearch(on: "embedding", query: [3, 4])
        XCTAssertEqual(scores(result), [1.0])
        XCTAssertEqual(result.backendUsed, "cpu-vdsp")
    }

    func test_cosine_orthogonal_isExactlyZero() throws {
        let df = try frame([[0, 1]], dims: 2)
        let result = try df.similaritySearch(on: "embedding", query: [1, 0])
        XCTAssertEqual(scores(result), [0.0])
    }

    func test_cosine_opposite_isExactlyMinusOne() throws {
        let df = try frame([[-3, -4]], dims: 2)
        let result = try df.similaritySearch(on: "embedding", query: [3, 4])
        XCTAssertEqual(scores(result), [-1.0])
    }

    func test_cosine_zeroVector_isExactlyZero() throws {
        // Either-zero-norm -> score 0.0, both directions.
        let df = try frame([[0, 0], [1, 1]], dims: 2)
        let zeroQuery = try df.similaritySearch(on: "embedding", query: [0, 0])
        XCTAssertEqual(scores(zeroQuery), [0.0, 0.0])
        let zeroCandidate = try df.similaritySearch(on: "embedding", query: [1, 0])
        XCTAssertEqual(scores(zeroCandidate).last, 0.0)  // the [0,0] row
    }

    func test_dot_direction_higherIsBetter() throws {
        let df = try frame([[1, 0], [3, 0], [2, 0]], dims: 2)
        var options = SearchOptions()
        options.metric = .dot
        let result = try df.similaritySearch(on: "embedding", query: [1, 0], options: options)
        XCTAssertEqual(ids(result), [1, 2, 0])
        XCTAssertEqual(scores(result), [3.0, 2.0, 1.0])
    }

    func test_euclidean_direction_lowerIsBetter() throws {
        let df = try frame([[3, 0], [1, 0], [2, 0]], dims: 2)
        var options = SearchOptions()
        options.metric = .euclidean
        let result = try df.similaritySearch(on: "embedding", query: [0, 0], options: options)
        XCTAssertEqual(ids(result), [1, 2, 0])
        XCTAssertEqual(scores(result), [1.0, 2.0, 3.0])
    }

    func test_threshold_perMetricDirection() throws {
        let df = try frame([[1, 0], [0, 1], [-1, 0]], dims: 2)
        var options = SearchOptions()
        options.threshold = 0.5  // cosine: keep score >= 0.5
        let kept = try df.similaritySearch(on: "embedding", query: [1, 0], options: options)
        XCTAssertEqual(ids(kept), [0])

        var euclid = SearchOptions()
        euclid.metric = .euclidean
        euclid.threshold = 1.5  // euclidean: keep distance <= 1.5
        let near = try df.similaritySearch(on: "embedding", query: [1, 0], options: euclid)
        XCTAssertEqual(ids(near), [0, 1])  // distances 0, sqrt(2); [-1,0] is 2 away
    }

    func test_topK_truncatesAfterThreshold() throws {
        let df = try frame([[1, 0], [1, 0], [1, 0], [0, 1]], dims: 2)
        var options = SearchOptions()
        options.topK = 2
        options.threshold = 0.5
        let result = try df.similaritySearch(on: "embedding", query: [1, 0], options: options)
        XCTAssertEqual(result.frame.rowCount, 2)
        XCTAssertEqual(ids(result), [0, 1])  // tie-break: lower row index first
    }

    // MARK: - A2 determinism

    func test_repeatedSearches_returnBitEqualScores() throws {
        var vectors = [[Float]]()
        var seed: UInt64 = 42
        for _ in 0..<500 {
            var v = [Float]()
            for _ in 0..<32 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                v.append(Float(seed >> 40) / Float(1 << 24))
            }
            vectors.append(v)
        }
        let df = try frame(vectors, dims: 32)
        var options = SearchOptions()
        options.topK = 50
        let first = try df.similaritySearch(on: "embedding", query: vectors[7], options: options)
        for _ in 0..<3 {
            let again = try df.similaritySearch(on: "embedding", query: vectors[7], options: options)
            // Bit-pattern comparison: -0.0 / NaN drift cannot pass silently.
            XCTAssertEqual(
                scores(first).map { $0.bitPattern },
                scores(again).map { $0.bitPattern })
            XCTAssertEqual(ids(first), ids(again))
        }
    }

    func test_tieBreak_duplicatedVectors_sourceRowIndexAscending() throws {
        let df = try frame([[0, 1], [1, 0], [1, 0], [1, 0]], dims: 2)
        let result = try df.similaritySearch(on: "embedding", query: [1, 0])
        // Rows 1–3 are exact duplicates (score 1.0) -> source index order;
        // orthogonal row 0 (score 0.0) ranks last.
        XCTAssertEqual(scores(result), [1.0, 1.0, 1.0, 0.0])
        XCTAssertEqual(ids(result), [1, 2, 3, 0])
    }

    // MARK: - Batch ≡ sequential

    func test_batch_identicalToSequential() throws {
        let vectors: [[Float]] = [[1, 0], [0, 1], [1, 1], [-1, 0]]
        let df = try frame(vectors, dims: 2)
        let queries: [[Float]] = [[1, 0], [0, 1]]
        let batch = try df.similaritySearchBatch(on: "embedding", queries: queries)
        let sequential = try queries.map { try df.similaritySearch(on: "embedding", query: $0) }
        XCTAssertEqual(batch.count, sequential.count)
        for (b, s) in zip(batch, sequential) {
            XCTAssertEqual(scores(b).map { $0.bitPattern }, scores(s).map { $0.bitPattern })
            XCTAssertEqual(ids(b), ids(s))
            XCTAssertEqual(b.backendUsed, s.backendUsed)
        }
    }

    // MARK: - Candidate exclusion

    func test_nullRowsExcludedBeforeScoring() throws {
        let df = try frame([[1, 0], nil, [0, 1]], dims: 2)
        let result = try df.similaritySearch(on: "embedding", query: [1, 0])
        XCTAssertEqual(ids(result), [0, 2])  // null row 1 never scored
    }

    func test_maskExcludesCandidates() throws {
        let df = try frame([[1, 0], [1, 0], [0, 1]], dims: 2)
        var options = SearchOptions()
        options.mask = [false, true, true]
        let result = try df.similaritySearch(on: "embedding", query: [1, 0], options: options)
        XCTAssertEqual(ids(result), [1, 2])
    }

    func test_emptyResult_isValidNotError() throws {
        let df = try frame([[1, 0]], dims: 2)
        var options = SearchOptions()
        options.threshold = 0.99
        let result = try df.similaritySearch(on: "embedding", query: [0, 1], options: options)
        XCTAssertEqual(result.frame.rowCount, 0)
    }

    // MARK: - Validation errors

    func test_missingColumn_throwsDataFrameError() throws {
        let df = try frame([[1, 0]], dims: 2)
        XCTAssertThrowsError(try df.similaritySearch(on: "nope", query: [1, 0])) { error in
            guard case DataFrameError.columnNotFound(let name) = error else {
                return XCTFail("expected columnNotFound, got \(error)")
            }
            XCTAssertEqual(name, "nope")
        }
    }

    func test_scalarColumn_throwsUnsupported() throws {
        let df = try frame([[1, 0]], dims: 2)
        XCTAssertThrowsError(try df.similaritySearch(on: "id", query: [1, 0])) { error in
            guard case VectorError.unsupportedOperation = error else {
                return XCTFail("expected unsupportedOperation, got \(error)")
            }
        }
    }

    func test_queryDimsMismatch_throws() throws {
        let df = try frame([[1, 0]], dims: 2)
        XCTAssertThrowsError(try df.similaritySearch(on: "embedding", query: [1, 0, 0])) { error in
            guard case VectorError.dimensionMismatch(let expected, let got) = error else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(got, 3)
        }
    }

    func test_emptyQuery_throwsInvalidArgument() throws {
        let df = try frame([[1, 0]], dims: 2)
        XCTAssertThrowsError(try df.similaritySearch(on: "embedding", query: [])) { error in
            guard case VectorError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func test_nonPositiveTopK_throws() throws {
        let df = try frame([[1, 0]], dims: 2)
        var options = SearchOptions()
        options.topK = 0
        XCTAssertThrowsError(
            try df.similaritySearch(on: "embedding", query: [1, 0], options: options)) { error in
            guard case VectorError.invalidArgument = error else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
    }

    func test_maskLengthMismatch_throws() throws {
        let df = try frame([[1, 0], [0, 1]], dims: 2)
        var options = SearchOptions()
        options.mask = [true]
        XCTAssertThrowsError(
            try df.similaritySearch(on: "embedding", query: [1, 0], options: options)) { error in
            guard case VectorError.maskLengthMismatch(let expected, let got) = error else {
                return XCTFail("expected maskLengthMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 2)
            XCTAssertEqual(got, 1)
        }
    }

    // MARK: - Result frame shape

    func test_resultFrame_hasOriginalColumnsPlusScore() throws {
        let df = try frame([[1, 0], [0, 1]], dims: 2)
        let result = try df.similaritySearch(on: "embedding", query: [1, 0])
        XCTAssertEqual(result.frame.columnNames, ["id", "embedding", "__score"])
        // The vector column rides along intact through the result.
        XCTAssertEqual(result.frame["embedding"].vector(at: 0), [1, 0])
    }
}
