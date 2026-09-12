import XCTest
@testable import SwiftPandas

/// B2a acceptance: the bounded-heap top-K selection must be byte-identical to
/// the previous full-sort-then-prefix behaviour.
///
/// Oracle: for the same query/options, requesting `topK >= candidateCount`
/// drives the engine's full-sort branch (the reference ranking); requesting a
/// smaller `topK` drives the bounded-heap branch (under test). The heap result
/// must equal the reference ranking's first K rows *and* scores exactly.
final class TopKParityTests: XCTestCase {

    // Deterministic LCG (Numerical Recipes constants) — no Math.random, so the
    // suite is reproducible run-to-run, matching the determinism contract.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        mutating func unitFloat() -> Float {
            Float(next() >> 40) / Float(1 << 24)  // [0,1)
        }
    }

    private func randomFrame(rows: Int, dims: Int, seed: UInt64) throws -> DataFrame {
        var rng = LCG(state: seed)
        var vectors = [[Float]]()
        vectors.reserveCapacity(rows)
        for _ in 0..<rows {
            vectors.append((0..<dims).map { _ in rng.unitFloat() * 2 - 1 })
        }
        return DataFrame(columns: [
            ("id", .fromInts(Array(0..<rows))),
            ("embedding", try .fromVectors(vectors, dims: dims)),
        ])
    }

    private func ids(_ result: SearchResultFrame) -> [Int64] {
        guard case .int64(let a) = result.frame["id"].data else { return [] }
        return (0..<a.count).map { a[$0]! }
    }

    private func scores(_ result: SearchResultFrame) -> [Double] {
        guard case .double(let a) = result.frame["__score"].data else { return [] }
        return (0..<a.count).map { a[$0]! }
    }

    /// Runs a search whose topK is large enough to hit the full-sort branch and
    /// returns the complete ranking (ids + scores), which serves as the oracle.
    private func fullRanking(
        _ df: DataFrame, query: [Float], metric: DistanceMetric,
        threshold: Double? = nil, mask: [Bool]? = nil
    ) throws -> (ids: [Int64], scores: [Double]) {
        var opts = SearchOptions()
        opts.metric = metric
        opts.threshold = threshold
        opts.mask = mask
        opts.topK = max(df.rowCount, 1)  // >= candidate count -> full-sort path
        let r = try df.similaritySearch(on: "embedding", query: query, options: opts)
        return (ids(r), scores(r))
    }

    private func heapTopK(
        _ df: DataFrame, query: [Float], metric: DistanceMetric, k: Int,
        threshold: Double? = nil, mask: [Bool]? = nil
    ) throws -> (ids: [Int64], scores: [Double]) {
        var opts = SearchOptions()
        opts.metric = metric
        opts.threshold = threshold
        opts.mask = mask
        opts.topK = k
        let r = try df.similaritySearch(on: "embedding", query: query, options: opts)
        return (ids(r), scores(r))
    }

    func test_heapTopK_matchesFullSort_acrossSeedsAndK() throws {
        let dims = 8
        for seed in UInt64(1)...30 {
            let rows = 200
            let df = try randomFrame(rows: rows, dims: dims, seed: seed)
            var rng = LCG(state: seed &* 7)
            let query = (0..<dims).map { _ in rng.unitFloat() * 2 - 1 }

            for metric in [DistanceMetric.cosine, .dot, .euclidean] {
                let oracle = try fullRanking(df, query: query, metric: metric)
                // Edge cases plus a spread of interior K values.
                for k in [1, 2, rows / 3, rows - 1, rows, rows + 5] {
                    let got = try heapTopK(df, query: query, metric: metric, k: k)
                    let expectedCount = min(k, oracle.ids.count)
                    XCTAssertEqual(
                        got.ids, Array(oracle.ids.prefix(expectedCount)),
                        "ids mismatch seed=\(seed) metric=\(metric) k=\(k)")
                    XCTAssertEqual(
                        got.scores, Array(oracle.scores.prefix(expectedCount)),
                        "scores mismatch seed=\(seed) metric=\(metric) k=\(k)")
                }
            }
        }
    }

    func test_heapTopK_matchesFullSort_withThreshold() throws {
        let dims = 6
        let rows = 150
        let df = try randomFrame(rows: rows, dims: dims, seed: 99)
        var rng = LCG(state: 12345)
        let query = (0..<dims).map { _ in rng.unitFloat() * 2 - 1 }

        // A threshold that eliminates roughly half the candidates.
        for (metric, threshold) in [(DistanceMetric.cosine, 0.0), (.dot, 0.0), (.euclidean, 2.0)] {
            let oracle = try fullRanking(df, query: query, metric: metric, threshold: threshold)
            for k in [1, 3, oracle.ids.count, oracle.ids.count + 10] {
                let got = try heapTopK(df, query: query, metric: metric, k: k, threshold: threshold)
                let expectedCount = min(k, oracle.ids.count)
                XCTAssertEqual(
                    got.ids, Array(oracle.ids.prefix(expectedCount)),
                    "threshold ids mismatch metric=\(metric) k=\(k)")
                XCTAssertEqual(got.scores, Array(oracle.scores.prefix(expectedCount)))
            }
        }
    }

    func test_heapTopK_matchesFullSort_withMask() throws {
        let dims = 4
        let rows = 120
        let df = try randomFrame(rows: rows, dims: dims, seed: 7)
        var rng = LCG(state: 555)
        let query = (0..<dims).map { _ in rng.unitFloat() * 2 - 1 }
        // Exclude every third row.
        let mask = (0..<rows).map { $0 % 3 != 0 }

        let oracle = try fullRanking(df, query: query, metric: .cosine, mask: mask)
        for k in [1, 5, oracle.ids.count - 1, oracle.ids.count] {
            let got = try heapTopK(df, query: query, metric: .cosine, k: k, mask: mask)
            let expectedCount = min(k, oracle.ids.count)
            XCTAssertEqual(got.ids, Array(oracle.ids.prefix(expectedCount)), "mask ids mismatch k=\(k)")
            XCTAssertEqual(got.scores, Array(oracle.scores.prefix(expectedCount)))
            // No masked-out row ever appears.
            for id in got.ids { XCTAssertTrue(mask[Int(id)], "masked row \(id) leaked") }
        }
    }

    func test_heapTopK_tiedScores_breakByRowAscending() throws {
        // Many identical vectors -> identical scores; tie-break must be row
        // index ascending, and the heap path must reproduce it exactly.
        let dims = 3
        let identical = Array(repeating: [Float](repeating: 1, count: dims), count: 50)
        let df = DataFrame(columns: [
            ("id", .fromInts(Array(0..<identical.count))),
            ("embedding", try .fromVectors(identical, dims: dims)),
        ])
        let got = try heapTopK(df, query: [1, 1, 1], metric: .cosine, k: 10)
        XCTAssertEqual(got.ids, Array(0..<10).map(Int64.init))
    }
}
