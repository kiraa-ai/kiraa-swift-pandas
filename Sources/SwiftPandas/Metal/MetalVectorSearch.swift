// ===----------------------------------------------------------------------===//
//
// MetalVectorSearch.swift
// SwiftPandas
//
// GPU batch-cosine scoring for similarity search. This file owns only the
// *mechanics* of GPU scoring (buffer setup, dispatch, readback); backend
// *policy* — when to use the GPU, what to do when it is unusable — lives in
// VectorSearchEngine, because backend selection is a search-semantics
// decision.
//
// The GPU emits raw Float cosine scores only. Threshold, topK, and tie-break
// always run on the shared CPU steps of the engine, so ranking semantics
// exist in exactly one place. Scores may differ from the CPU backend at ulp
// level (GPU fma accumulation order); bit-stability requires `.cpu`.
//
// When a mask/null filter excludes rows, the candidate plane is compacted on
// the CPU before upload — mask-false rows never reach the GPU. When every row
// is a candidate, the VectorArray's plane feeds the buffer directly (one
// memcpy into shared memory via MetalContext.makeBuffer; no flattening pass).
//
// ===----------------------------------------------------------------------===//

#if canImport(Metal)
import Metal
#endif

internal enum MetalVectorSearch {
    /// Human-readable reason the GPU path is unusable, for
    /// `VectorError.metalUnavailable`.
    static var unavailabilityReason: String {
        if MetalDispatch.metalDisabled {
            return "Metal disabled via SWIFTPANDAS_DISABLE_METAL"
        }
        #if canImport(Metal)
        if MetalContext.shared == nil {
            return "no Metal device/pipeline available on this host"
        }
        return "Metal buffer allocation failed"
        #else
        return "Metal is not supported on this platform"
        #endif
    }

    /// Score cosine similarity of `query` against the candidate rows of
    /// `array` on the GPU. Returns scores in candidate order (the CPU
    /// zero-denominator rule is honored in-kernel), or `nil` when the GPU
    /// path is unusable — callers decide whether nil is an error (`.metal`)
    /// or a fallback (`.auto`).
    static func scoreCosine(
        _ array: VectorArray, query: [Float], candidates: [Int]
    ) -> [Double]? {
        #if canImport(Metal)
        guard !MetalDispatch.metalDisabled, let context = MetalContext.shared else { return nil }
        guard !candidates.isEmpty else { return [] }

        let dims = array.dims
        // sqrt(|q|²) once on the CPU, matching the CPU scorer's step order.
        let sqrtNQ = query.withUnsafeBufferPointer { VectorOps.dotF($0, $0) }.squareRoot()

        // Compact the candidate plane when rows are excluded; feed the raw
        // plane directly when every row is a candidate.
        let planeBuffer: MTLBuffer?
        if candidates.count == array.count {
            planeBuffer = context.makeBuffer(array.plane)
        } else {
            var compacted = [Float](repeating: 0, count: candidates.count * dims)
            array.plane.withUnsafeBufferPointer { src in
                compacted.withUnsafeMutableBufferPointer { dst in
                    for (slot, row) in candidates.enumerated() {
                        let s = row * dims
                        let d = slot * dims
                        for k in 0..<dims { dst[d + k] = src[s + k] }
                    }
                }
            }
            planeBuffer = context.makeBuffer(from: compacted)
        }

        guard
            let plane = planeBuffer,
            let queryBuffer = context.makeBuffer(from: query),
            let resultsBuffer = context.makeBuffer(length: candidates.count * MemoryLayout<Float>.stride),
            let dimsBuffer = context.makeBuffer(from: [UInt32(dims)]),
            let countBuffer = context.makeBuffer(from: [UInt32(candidates.count)]),
            let sqrtNQBuffer = context.makeBuffer(from: [sqrtNQ])
        else { return nil }

        context.dispatch(
            pipeline: context.vectorCosinePipeline,
            buffers: [
                (queryBuffer, 0), (plane, 1), (resultsBuffer, 2),
                (dimsBuffer, 3), (countBuffer, 4), (sqrtNQBuffer, 5),
            ],
            threadCount: candidates.count)

        let raw = resultsBuffer.contents().bindMemory(
            to: Float.self, capacity: candidates.count)
        return (0..<candidates.count).map { Double(raw[$0]) }
        #else
        return nil
        #endif
    }
}
