import Metal

/// Singleton manager for Metal GPU compute resources.
/// Thread-safe: initialized once via static let, immutable after construction.
internal final class MetalContext: @unchecked Sendable {

    /// Shared singleton. Returns nil if Metal is unavailable (e.g., simulator).
    static let shared: MetalContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: MetalShaders.allSource, options: nil)
            return MetalContext(device: device, queue: queue, library: library)
        } catch {
            print("SwiftPandas: Metal shader compilation failed: \(error)")
            return nil
        }
    }()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // Pre-cached pipeline states for each kernel
    let groupByHashInsertPipeline: MTLComputePipelineState
    let groupByReduceSumPipeline: MTLComputePipelineState
    let groupByReduceMinPipeline: MTLComputePipelineState
    let groupByReduceMaxPipeline: MTLComputePipelineState
    let groupByReduceCountPipeline: MTLComputePipelineState
    let mergeHashBuildPipeline: MTLComputePipelineState
    let mergeHashProbePipeline: MTLComputePipelineState

    private init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) {
        self.device = device
        self.commandQueue = queue
        self.library = library

        func makePipeline(_ name: String) -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                fatalError("SwiftPandas: Metal function '\(name)' not found in library")
            }
            do {
                return try device.makeComputePipelineState(function: fn)
            } catch {
                fatalError("SwiftPandas: Failed to create pipeline for '\(name)': \(error)")
            }
        }

        self.groupByHashInsertPipeline = makePipeline("groupby_hash_insert")
        self.groupByReduceSumPipeline = makePipeline("groupby_reduce_sum")
        self.groupByReduceMinPipeline = makePipeline("groupby_reduce_min")
        self.groupByReduceMaxPipeline = makePipeline("groupby_reduce_max")
        self.groupByReduceCountPipeline = makePipeline("groupby_reduce_count")
        self.mergeHashBuildPipeline = makePipeline("merge_hash_build")
        self.mergeHashProbePipeline = makePipeline("merge_hash_probe")
    }

    // MARK: - Buffer Helpers

    /// Create a shared-mode Metal buffer from a NativeArray.
    func makeBuffer<T>(_ array: NativeArray<T>) -> MTLBuffer? {
        array.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: base,
                length: buf.count * MemoryLayout<T>.stride,
                options: .storageModeShared
            )
        }
    }

    /// Create a shared-mode Metal buffer from a raw array.
    func makeBuffer<T>(from array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBufferPointer { buf in
            device.makeBuffer(
                bytes: buf.baseAddress!,
                length: buf.count * MemoryLayout<T>.stride,
                options: .storageModeShared
            )
        }
    }

    /// Create an empty shared-mode buffer of given byte length.
    func makeBuffer(length: Int) -> MTLBuffer? {
        device.makeBuffer(length: max(length, 4), options: .storageModeShared)
    }

    /// Dispatch a 1D compute kernel.
    func dispatch(
        pipeline: MTLComputePipelineState,
        buffers: [(MTLBuffer, Int)],
        threadCount: Int
    ) {
        guard let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(pipeline)
        for (buffer, index) in buffers {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }

        let threadsPerGroup = min(pipeline.maxTotalThreadsPerThreadgroup, threadCount)
        let threadgroups = (threadCount + threadsPerGroup - 1) / threadsPerGroup
        encoder.dispatchThreadgroups(
            MTLSize(width: threadgroups, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1)
        )
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
    }
}
