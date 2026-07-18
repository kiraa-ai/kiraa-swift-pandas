// ===----------------------------------------------------------------------===//
//
// VectorSearch.swift
// SwiftPandas
//
// Similarity search over `.floatVector` columns: public options/result types,
// the DataFrame facade, and the internal engine that owns the one ordering of
// search decisions:
//
//     candidate compaction -> scoring -> threshold -> top-K -> tie-break
//
// The engine is the single implementation for every backend: the GPU (M4)
// produces raw scores only, so null/mask exclusion and ranking semantics can
// never diverge between backends.
//
// ## Numeric contract (normative, CPU backend — do not "optimize")
//
// Consumers pin bit-identical scores on the CPU backend. Cosine is computed,
// exactly, in Float32 order:
//
//   1. dot   = vDSP_dotpr(query, candidate)                      (Float)
//   2. nQ    = vDSP_dotpr(query, query)     — once per query     (Float)
//      nC    = squaredNorms[row]            — construction cache (Float;
//              bit-identical to on-the-fly vDSP_dotpr(v, v) by contract)
//   3. denom = sqrt(nQ) * sqrt(nC)          (Float sqrts, Float multiply)
//   4. denom == 0  ->  score = 0.0 (Double)
//      else           score = Double(dot / denom)  (Float divide, then widen)
//
// Dot:       score = Double(vDSP_dotpr(q, c))
// Euclidean: score = Double(sqrt(vDSP_distancesq(q, c)))  (Float sqrt, widen)
//
// No Double accumulation, no fused rearrangement, no epsilon guards. Bit
// determinism (same input -> same bytes, every run) is normative for the CPU
// backend on Apple platforms; non-Apple builds use VectorOps' scalar
// fallbacks, so the pin is per-platform.
//
// ===----------------------------------------------------------------------===//

/// Options for ``DataFrame/similaritySearch(on:query:options:)``.
public struct SearchOptions: Sendable {
    /// The scoring metric. Defaults to cosine.
    public var metric: DistanceMetric = .cosine
    /// Number of results to keep after threshold filtering. `topK <= 0`
    /// throws ``VectorError/invalidArgument(_:)``.
    public var topK: Int = 10
    /// Optional score cutoff. cosine/dot: keep `score >= threshold`;
    /// euclidean: keep `distance <= threshold`.
    public var threshold: Double? = nil
    /// Optional candidate pre-filter; length must equal the frame's row count
    /// (else ``VectorError/maskLengthMismatch(expected:got:)``). Mask-false
    /// rows are excluded before scoring.
    public var mask: [Bool]? = nil
    /// Which compute backend scores candidates. Defaults to CPU — the
    /// documented primary and the bit-stable path.
    public var backend: SearchBackend = .cpu
    public init() {}
}

/// Compute backend for candidate scoring.
public enum SearchBackend: Sendable {
    /// vDSP brute force — always available; the documented primary and the
    /// only bit-stable path.
    case cpu
    /// GPU batch scoring (cosine-only in v1). Throws when unusable — never
    /// falls back silently.
    case metal
    /// Uses metal iff post-mask candidate count exceeds `gpuThreshold` AND
    /// the pipeline is available; otherwise cpu. The decision is observable
    /// via ``SearchResultFrame/backendUsed``.
    case auto(gpuThreshold: Int = 16_384)
}

/// The result of a similarity search: matching rows of the source frame with
/// their scores, ranked best-first.
public struct SearchResultFrame: Sendable {
    /// Matching rows of the source frame (original columns) plus a
    /// `"__score"` Double column, ranked best-first.
    public let frame: DataFrame
    /// `"cpu-vdsp"` or `"metal"` — which backend actually scored. Never
    /// silent: `.auto` decisions are observable here.
    public let backendUsed: String
}

// MARK: - Engine

/// Internal single implementation of search semantics. Public facades and
/// (in M4) the Metal scorer all route through here.
enum VectorSearchEngine {
    struct Hits {
        let rowIndices: [Int]
        let scores: [Double]
        let backendUsed: String
    }

    static let scoreColumnName = "__score"
    static let cpuBackendName = "cpu-vdsp"
    static let metalBackendName = "metal"

    static func search(
        _ array: VectorArray, query: [Float], options: SearchOptions, rowCount: Int
    ) throws -> Hits {
        // --- Validation (nothing returns an empty result on invalid input) ---
        guard options.topK > 0 else {
            throw VectorError.invalidArgument("topK must be > 0, got \(options.topK)")
        }
        guard !query.isEmpty else {
            throw VectorError.invalidArgument("query vector is empty")
        }
        guard query.count == array.dims else {
            throw VectorError.dimensionMismatch(expected: array.dims, got: query.count)
        }
        if let mask = options.mask, mask.count != rowCount {
            throw VectorError.maskLengthMismatch(expected: rowCount, got: mask.count)
        }

        // --- 1. Compact candidates once (bitmap-valid AND mask-true). Both
        //        CPU and GPU paths consume this one list, so null/mask
        //        exclusion cannot diverge between backends. ---
        var candidates = [Int]()
        candidates.reserveCapacity(array.count)
        if let mask = options.mask {
            for row in 0..<array.count where mask[row] && array.validity[row] {
                candidates.append(row)
            }
        } else if array.validity.allValid {
            candidates = Array(0..<array.count)
        } else {
            for row in 0..<array.count where array.validity[row] {
                candidates.append(row)
            }
        }

        // --- 2. Score (backend selection) ---
        let scores: [Double]
        let backendUsed: String
        switch options.backend {
        case .cpu:
            scores = scoreCPU(array, query: query, candidates: candidates, metric: options.metric)
            backendUsed = cpuBackendName
        case .metal:
            scores = try scoreMetalOrThrow(
                array, query: query, candidates: candidates, metric: options.metric)
            backendUsed = metalBackendName
        case .auto(let gpuThreshold):
            if options.metric == .cosine,
               candidates.count > gpuThreshold,
               let gpuScores = MetalVectorSearch.scoreCosine(
                   array, query: query, candidates: candidates) {
                scores = gpuScores
                backendUsed = metalBackendName
            } else {
                scores = scoreCPU(array, query: query, candidates: candidates, metric: options.metric)
                backendUsed = cpuBackendName
            }
        }

        // --- 3. Threshold filter (metric direction) ---
        var survivors = [(row: Int, score: Double)]()
        survivors.reserveCapacity(candidates.count)
        if let threshold = options.threshold {
            switch options.metric {
            case .cosine, .dot:
                for i in 0..<candidates.count where scores[i] >= threshold {
                    survivors.append((candidates[i], scores[i]))
                }
            case .euclidean:
                for i in 0..<candidates.count where scores[i] <= threshold {
                    survivors.append((candidates[i], scores[i]))
                }
            }
        } else {
            for i in 0..<candidates.count {
                survivors.append((candidates[i], scores[i]))
            }
        }

        // --- 4. Deterministic ranking: primary by score in metric direction,
        //        tie-break by source row index ascending. topK truncates
        //        after threshold filtering. ---
        let higherIsBetter = options.metric != .euclidean
        survivors.sort { a, b in
            if a.score != b.score {
                return higherIsBetter ? a.score > b.score : a.score < b.score
            }
            return a.row < b.row
        }
        let top = survivors.prefix(options.topK)
        return Hits(
            rowIndices: top.map { $0.row },
            scores: top.map { $0.score },
            backendUsed: backendUsed)
    }

    // MARK: CPU scorer (the bit-parity path — see file header contract)

    private static func scoreCPU(
        _ array: VectorArray, query: [Float], candidates: [Int], metric: DistanceMetric
    ) -> [Double] {
        let dims = array.dims
        var scores = [Double](repeating: 0, count: candidates.count)
        query.withUnsafeBufferPointer { q in
            array.plane.withUnsafeBufferPointer { plane in
                switch metric {
                case .cosine:
                    let nQ = VectorOps.dotF(q, q)
                    let sqrtNQ = nQ.squareRoot()
                    array.squaredNorms.withUnsafeBufferPointer { norms in
                        for (i, row) in candidates.enumerated() {
                            let candidate = UnsafeBufferPointer(
                                rebasing: plane[(row * dims)..<((row + 1) * dims)])
                            let dot = VectorOps.dotF(q, candidate)
                            let denom = sqrtNQ * norms[row].squareRoot()
                            scores[i] = denom == 0 ? 0.0 : Double(dot / denom)
                        }
                    }
                case .dot:
                    for (i, row) in candidates.enumerated() {
                        let candidate = UnsafeBufferPointer(
                            rebasing: plane[(row * dims)..<((row + 1) * dims)])
                        scores[i] = Double(VectorOps.dotF(q, candidate))
                    }
                case .euclidean:
                    for (i, row) in candidates.enumerated() {
                        let candidate = UnsafeBufferPointer(
                            rebasing: plane[(row * dims)..<((row + 1) * dims)])
                        scores[i] = Double(VectorOps.distanceSqF(q, candidate).squareRoot())
                    }
                }
            }
        }
        return scores
    }

    // MARK: Metal (strict `.metal` policy; scorer lands in M4)

    private static func scoreMetalOrThrow(
        _ array: VectorArray, query: [Float], candidates: [Int], metric: DistanceMetric
    ) throws -> [Double] {
        guard metric == .cosine else {
            throw VectorError.metalUnsupportedMetric(metric)
        }
        guard let scores = MetalVectorSearch.scoreCosine(
            array, query: query, candidates: candidates) else {
            throw VectorError.metalUnavailable(MetalVectorSearch.unavailabilityReason)
        }
        return scores
    }
}

// MARK: - DataFrame facade

extension DataFrame {
    /// Top-K similarity search over a `.floatVector` column.
    ///
    /// Null vector rows and mask-false rows are excluded before scoring.
    /// Ranking is fully deterministic: primary by score (metric direction),
    /// ties broken by source row index ascending.
    ///
    /// - Parameters:
    ///   - column: Name of a `.floatVector` column.
    ///   - query: The query vector; its count must equal the column's dims.
    ///   - options: Metric, topK, threshold, mask, and backend.
    /// - Returns: Matching rows plus a `"__score"` Double column, best-first,
    ///   and the backend that actually scored.
    /// - Throws: ``DataFrameError/columnNotFound(_:)`` for a missing column;
    ///   ``VectorError`` for every vector-semantics misuse.
    public func similaritySearch(
        on column: String, query: [Float], options: SearchOptions = .init()
    ) throws -> SearchResultFrame {
        guard let col = columns[column] else {
            throw DataFrameError.columnNotFound(column)
        }
        guard case .floatVector(let array) = col else {
            throw VectorError.unsupportedOperation(
                op: "similaritySearch", dtype: col.dtype.description)
        }
        let hits = try VectorSearchEngine.search(
            array, query: query, options: options, rowCount: rowCount)
        var frame = takeRows(hits.rowIndices)
        frame[VectorSearchEngine.scoreColumnName] = Series(
            data: .fromDoubles(hits.scores), name: VectorSearchEngine.scoreColumnName)
        return SearchResultFrame(frame: frame, backendUsed: hits.backendUsed)
    }

    /// Batch form of ``similaritySearch(on:query:options:)``.
    ///
    /// Semantically identical to N sequential calls (executed sequentially in
    /// order, so the identity holds by construction); per-query results are
    /// order-stable.
    public func similaritySearchBatch(
        on column: String, queries: [[Float]], options: SearchOptions = .init()
    ) throws -> [SearchResultFrame] {
        var results = [SearchResultFrame]()
        results.reserveCapacity(queries.count)
        for query in queries {
            results.append(try similaritySearch(on: column, query: query, options: options))
        }
        return results
    }
}
