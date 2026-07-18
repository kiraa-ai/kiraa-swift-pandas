import XCTest
@testable import SwiftPandas

/// A3 acceptance: CPU↔Metal score parity (≤ 1e-5, identical ranking) on
/// seeded-random data, the strict `.metal` throw policy, and `.auto`
/// observability via `backendUsed`.
final class MetalVectorSearchTests: XCTestCase {

    /// Deterministic LCG-seeded vectors (same convention as BenchmarkTests).
    private func seededVectors(count: Int, dims: Int, seed: UInt64 = 42) -> [[Float]] {
        var state = seed
        var vectors = [[Float]]()
        vectors.reserveCapacity(count)
        for _ in 0..<count {
            var v = [Float](repeating: 0, count: dims)
            for k in 0..<dims {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                v[k] = Float(state >> 40) / Float(1 << 24) - 0.5
            }
            vectors.append(v)
        }
        return vectors
    }

    private func scores(_ result: SearchResultFrame) -> [Double] {
        guard case .double(let a) = result.frame["__score"].data else { return [] }
        return (0..<a.count).map { a[$0]! }
    }

    private func ids(_ result: SearchResultFrame) -> [Int64] {
        guard case .int64(let a) = result.frame["id"].data else { return [] }
        return (0..<a.count).map { a[$0]! }
    }

    // MARK: - A3 parity

    func test_cpuMetalParity_10Kx512_seededRandom() throws {
        guard MetalDispatch.isAvailable else {
            throw XCTSkip("No Metal device on this host; the throw policy is covered by test_metalBackend_whenDisabled_throwsMetalUnavailable")
        }
        let vectors = seededVectors(count: 10_000, dims: 512)
        let df = DataFrame(columns: [
            ("id", .fromInts(Array(0..<vectors.count))),
            ("embedding", try .fromVectors(vectors, dims: 512)),
        ])
        var cpuOptions = SearchOptions()
        cpuOptions.topK = 100
        var gpuOptions = cpuOptions
        gpuOptions.backend = .metal

        let query = vectors[123]
        let cpu = try df.similaritySearch(on: "embedding", query: query, options: cpuOptions)
        let gpu = try df.similaritySearch(on: "embedding", query: query, options: gpuOptions)

        XCTAssertEqual(cpu.backendUsed, "cpu-vdsp")
        XCTAssertEqual(gpu.backendUsed, "metal")
        // Identical ranking on non-degenerate data.
        XCTAssertEqual(ids(cpu), ids(gpu))
        // Scores within 1e-5 absolute (GPU fma order differs at ulp level).
        for (c, g) in zip(scores(cpu), scores(gpu)) {
            XCTAssertEqual(c, g, accuracy: 1e-5)
        }
    }

    func test_metalHonorsMaskAndNulls() throws {
        guard MetalDispatch.isAvailable else {
            throw XCTSkip("No Metal device on this host")
        }
        var optionals: [[Float]?] = seededVectors(count: 64, dims: 16)
        optionals[3] = nil
        optionals[40] = nil
        let df = DataFrame(columns: [
            ("id", .fromInts(Array(0..<optionals.count))),
            ("embedding", try .fromOptionalVectors(optionals, dims: 16)),
        ])
        var mask = [Bool](repeating: true, count: 64)
        for i in 0..<32 { mask[i] = false }

        var cpuOptions = SearchOptions()
        cpuOptions.topK = 64
        cpuOptions.mask = mask
        var gpuOptions = cpuOptions
        gpuOptions.backend = .metal

        let query = optionals[33]!
        let cpu = try df.similaritySearch(on: "embedding", query: query, options: cpuOptions)
        let gpu = try df.similaritySearch(on: "embedding", query: query, options: gpuOptions)
        XCTAssertEqual(ids(cpu), ids(gpu))
        XCTAssertFalse(ids(gpu).contains(40))  // null row excluded
        XCTAssertTrue(ids(gpu).allSatisfy { $0 >= 32 })  // mask honored
    }

    // MARK: - Strict `.metal` policy

    func test_metalBackend_whenDisabled_throwsMetalUnavailable() throws {
        // Force-disable so this assertion runs on GPU hosts too — the throw
        // policy must be asserted, never skipped silently (A3).
        let saved = MetalDispatch.metalDisabled
        MetalDispatch.metalDisabled = true
        defer { MetalDispatch.metalDisabled = saved }

        let df = DataFrame(columns: [
            ("embedding", try .fromVectors([[1, 0]], dims: 2)),
        ])
        var options = SearchOptions()
        options.backend = .metal
        XCTAssertThrowsError(
            try df.similaritySearch(on: "embedding", query: [1, 0], options: options)) { error in
            guard case VectorError.metalUnavailable(let reason) = error else {
                return XCTFail("expected metalUnavailable, got \(error)")
            }
            XCTAssertTrue(reason.contains("SWIFTPANDAS_DISABLE_METAL"))
        }
    }

    func test_metalBackend_nonCosineMetric_throwsUnsupportedMetric() throws {
        let df = DataFrame(columns: [
            ("embedding", try .fromVectors([[1, 0]], dims: 2)),
        ])
        for metric in [DistanceMetric.dot, .euclidean] {
            var options = SearchOptions()
            options.backend = .metal
            options.metric = metric
            XCTAssertThrowsError(
                try df.similaritySearch(on: "embedding", query: [1, 0], options: options)) { error in
                guard case VectorError.metalUnsupportedMetric(let m) = error else {
                    return XCTFail("expected metalUnsupportedMetric, got \(error)")
                }
                XCTAssertEqual(m, metric)
            }
        }
    }

    // MARK: - `.auto` observability

    func test_autoBackend_belowThreshold_usesCPU() throws {
        let df = DataFrame(columns: [
            ("embedding", try .fromVectors([[1, 0], [0, 1]], dims: 2)),
        ])
        var options = SearchOptions()
        options.backend = .auto(gpuThreshold: 16_384)
        let result = try df.similaritySearch(on: "embedding", query: [1, 0], options: options)
        XCTAssertEqual(result.backendUsed, "cpu-vdsp")
    }

    func test_autoBackend_aboveThreshold_usesMetalWhenAvailable() throws {
        let vectors = seededVectors(count: 512, dims: 32)
        let df = DataFrame(columns: [
            ("id", .fromInts(Array(0..<vectors.count))),
            ("embedding", try .fromVectors(vectors, dims: 32)),
        ])
        var options = SearchOptions()
        options.backend = .auto(gpuThreshold: 256)  // 512 candidates > 256
        let result = try df.similaritySearch(on: "embedding", query: vectors[0], options: options)
        if MetalDispatch.isAvailable {
            XCTAssertEqual(result.backendUsed, "metal")
        } else {
            XCTAssertEqual(result.backendUsed, "cpu-vdsp")  // observable fallback
        }
    }

    func test_autoBackend_whenDisabled_fallsBackObservably() throws {
        let saved = MetalDispatch.metalDisabled
        MetalDispatch.metalDisabled = true
        defer { MetalDispatch.metalDisabled = saved }

        let vectors = seededVectors(count: 512, dims: 8)
        let df = DataFrame(columns: [
            ("embedding", try .fromVectors(vectors, dims: 8)),
        ])
        var options = SearchOptions()
        options.backend = .auto(gpuThreshold: 16)
        let result = try df.similaritySearch(on: "embedding", query: vectors[0], options: options)
        XCTAssertEqual(result.backendUsed, "cpu-vdsp")
    }
}
