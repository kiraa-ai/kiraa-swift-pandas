// MARK: - MetalContext.swift
// ---------------------------------------------------------------------------
// GPU Compute Infrastructure for SwiftPandas
// ---------------------------------------------------------------------------
//
// This file provides the central Metal GPU compute context used by the entire
// SwiftPandas framework. It manages the lifecycle of the Metal device, command
// queue, shader library, and precompiled compute pipeline states.
//
// Architecture Overview:
//
// MetalContext uses the **singleton pattern** (via `static let shared`) to
// guarantee that GPU resources are initialized exactly once and shared across
// all call sites. The singleton is lazily constructed the first time it is
// accessed. Because `static let` in Swift is implicitly dispatch_once, this
// initialization is thread-safe without requiring explicit locking. After
// construction all stored properties are immutable, which is why the class is
// marked `@unchecked Sendable` — there is no mutable state to protect.
//
// Shader Loading — SPM vs Xcode:
//
// Metal shaders must be compiled into a `MTLLibrary` before use. The mechanism
// for obtaining that library differs between build systems:
//
//   - **Swift Package Manager (SPM):** SPM does not support compiling `.metal`
//     source files as part of its build pipeline. As a workaround, the MSL
//     (Metal Shading Language) source code is embedded as Swift string literals
//     in `MetalShaders.swift` and compiled at runtime via
//     `MTLDevice.makeLibrary(source:options:)`. This adds a small one-time
//     cost on first access but requires no special build configuration.
//
//   - **Xcode:** When built as a framework target in Xcode, the `.metal`
//     source files are compiled to a `default.metallib` binary at build time
//     by the Xcode Metal compiler toolchain. The precompiled library is loaded
//     from the framework bundle via `MTLDevice.makeDefaultLibrary(bundle:)`,
//     which is faster than runtime compilation.
//
// Pipeline Caching:
//
// Creating an `MTLComputePipelineState` involves driver-level compilation and
// is an expensive operation (potentially tens of milliseconds). To avoid
// paying this cost on every GPU dispatch, all seven pipeline states — for
// GroupBy hash insertion, four GroupBy reduction variants (sum, min, max,
// count), merge hash build, and merge hash probe — are created eagerly during
// singleton initialization and cached as immutable `let` properties. If any
// pipeline fails to compile, the process terminates with `fatalError` because
// the shaders are known at compile time and failure indicates a programming
// error or incompatible GPU hardware.
//
// Buffer Helpers:
//
// The `makeBuffer` family of methods provides convenience wrappers around
// `MTLDevice.makeBuffer`. All buffers use `.storageModeShared`, which places
// the buffer in unified memory accessible to both the CPU and GPU without
// explicit synchronization on Apple Silicon. This is essential for the
// synchronous dispatch model used here, where the CPU reads results
// immediately after `waitUntilCompleted()` returns.
//
// 1D Dispatch:
//
// The `dispatch(pipeline:buffers:threadCount:)` method encodes and submits a
// one-dimensional compute grid. It automatically selects the largest possible
// threadgroup size (up to the pipeline's `maxTotalThreadsPerThreadgroup`) and
// calculates the number of threadgroups using ceiling division. The call is
// **synchronous** — it blocks the calling thread until the GPU work completes.
// This simplifies the programming model at the cost of not overlapping CPU
// and GPU work, which is acceptable because the GPU kernels in SwiftPandas
// are the bottleneck operation and the CPU has no useful work to do in
// parallel.
// ---------------------------------------------------------------------------

import Metal

/// Singleton manager for Metal GPU compute resources.
///
/// Thread-safe: initialized exactly once via `static let` (which is implicitly
/// `dispatch_once`). All stored properties are immutable after construction,
/// making the instance safe to share across threads without synchronization.
///
/// Returns `nil` from `shared` if Metal is unavailable on the current device
/// (e.g., iOS Simulator, Linux, or hardware without Metal support), allowing
/// callers to fall back to CPU code paths gracefully.
internal final class MetalContext: @unchecked Sendable {

    /// Shared singleton instance.
    ///
    /// Returns `nil` if Metal is unavailable on this device. Callers should
    /// always `guard let ctx = MetalContext.shared` and fall back to a CPU
    /// implementation when the guard fails.
    ///
    /// Initialization sequence:
    /// 1. Obtain the system default `MTLDevice` (GPU handle).
    /// 2. Create a `MTLCommandQueue` for submitting work to the GPU.
    /// 3. Load or compile the `MTLLibrary` containing all compute kernels.
    /// 4. Construct the `MetalContext`, which eagerly creates and caches all
    ///    `MTLComputePipelineState` objects.
    static let shared: MetalContext? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }

        let library: MTLLibrary
        #if SWIFT_PACKAGE
        // SPM builds: Metal `.metal` files cannot be compiled by SPM, so the
        // MSL source is embedded as Swift string literals in MetalShaders.swift.
        // We compile them at runtime here. This incurs a one-time cost of
        // ~10–50ms depending on shader complexity and GPU driver.
        do {
            library = try device.makeLibrary(source: MetalShaders.allSource, options: nil)
        } catch {
            print("SwiftPandas: Metal shader compilation failed: \(error)")
            return nil
        }
        #else
        // Xcode builds: `.metal` files are compiled to `default.metallib` at
        // build time by Xcode's Metal compiler. Loading the precompiled binary
        // is near-instantaneous compared to runtime compilation.
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle(for: MetalContext.self))
        } catch {
            print("SwiftPandas: Failed to load Metal library from bundle: \(error)")
            return nil
        }
        #endif

        return MetalContext(device: device, queue: queue, library: library)
    }()

    /// The Metal device (GPU) used for all compute operations.
    let device: MTLDevice

    /// Serial command queue for submitting compute command buffers to the GPU.
    let commandQueue: MTLCommandQueue

    /// Compiled shader library containing all compute kernel functions.
    let library: MTLLibrary

    // MARK: Pre-cached Pipeline States
    //
    // Each pipeline state corresponds to one MSL kernel function. They are
    // created eagerly at initialization time to avoid the overhead of
    // driver-level compilation on the hot path during GroupBy or Merge
    // operations.

    /// Pipeline for the `groupby_hash_insert` kernel (Phase 1: maps rows to group IDs).
    let groupByHashInsertPipeline: MTLComputePipelineState

    /// Pipeline for the `groupby_reduce_sum` kernel (Phase 2: atomic floating-point summation).
    let groupByReduceSumPipeline: MTLComputePipelineState

    /// Pipeline for the `groupby_reduce_min` kernel (Phase 2: atomic CAS-based minimum).
    let groupByReduceMinPipeline: MTLComputePipelineState

    /// Pipeline for the `groupby_reduce_max` kernel (Phase 2: atomic CAS-based maximum).
    let groupByReduceMaxPipeline: MTLComputePipelineState

    /// Pipeline for the `groupby_reduce_count` kernel (Phase 2: atomic count increment).
    let groupByReduceCountPipeline: MTLComputePipelineState

    /// Pipeline for the `merge_hash_build` kernel (Merge Phase 1: build hash table from right table).
    let mergeHashBuildPipeline: MTLComputePipelineState

    /// Pipeline for the `merge_hash_probe` kernel (Merge Phase 2: probe hash table with left table).
    let mergeHashProbePipeline: MTLComputePipelineState

    /// Private initializer — only called from the `shared` static closure.
    ///
    /// Creates all seven compute pipeline states eagerly. If any pipeline
    /// fails to compile, the process terminates with `fatalError` because
    /// these shaders are statically known and a compilation failure indicates
    /// a programming error or fundamentally incompatible hardware.
    ///
    /// - Parameters:
    ///   - device: The Metal device to create pipelines on.
    ///   - queue: The command queue for submitting work.
    ///   - library: The compiled shader library containing kernel functions.
    private init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) {
        self.device = device
        self.commandQueue = queue
        self.library = library

        /// Local helper that looks up a kernel function by name in the library
        /// and compiles it into a `MTLComputePipelineState`. Terminates on
        /// failure since these are compile-time-known shader names.
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
    //
    // All buffers are created with `.storageModeShared`, which on Apple Silicon
    // means the buffer resides in unified memory accessible to both CPU and GPU
    // without explicit copies. On Intel Macs with discrete GPUs, shared mode
    // still works but may involve implicit copies managed by the driver.

    /// Create a shared-mode Metal buffer by copying the contents of a `NativeArray`.
    ///
    /// The entire contiguous storage of the `NativeArray` is copied into a new
    /// GPU-accessible buffer. The buffer size is `count * MemoryLayout<T>.stride`
    /// bytes.
    ///
    /// - Parameter array: The source `NativeArray` whose elements will be copied.
    /// - Returns: A new `MTLBuffer` containing the data, or `nil` if the array
    ///   is empty or buffer allocation fails.
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

    /// Create a shared-mode Metal buffer by copying the contents of a Swift `Array`.
    ///
    /// Uses `withUnsafeBufferPointer` to obtain a pointer to the array's
    /// contiguous storage and copies it into a new GPU buffer.
    ///
    /// - Parameter array: The source array whose elements will be copied.
    /// - Returns: A new `MTLBuffer`, or `nil` if the array is empty or
    ///   allocation fails.
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

    /// Create an empty (zero-initialized) shared-mode buffer of the given byte length.
    ///
    /// The minimum allocated size is 4 bytes, even if `length` is smaller. This
    /// avoids Metal validation errors that can occur with zero-length buffers on
    /// some drivers.
    ///
    /// - Parameter length: Desired buffer size in bytes.
    /// - Returns: A new zero-initialized `MTLBuffer`, or `nil` on allocation failure.
    func makeBuffer(length: Int) -> MTLBuffer? {
        device.makeBuffer(length: max(length, 4), options: .storageModeShared)
    }

    // MARK: - 1D Compute Dispatch

    /// Dispatch a one-dimensional compute kernel synchronously.
    ///
    /// This method encodes and submits a compute pass, then **blocks** the
    /// calling thread until the GPU finishes execution. The synchronous model
    /// simplifies control flow — callers can read back results from shared
    /// buffers immediately after this method returns.
    ///
    /// Thread grid sizing:
    /// - `threadsPerGroup` is set to the smaller of the pipeline's maximum
    ///   threadgroup size and the total `threadCount`. This ensures we fully
    ///   utilize the GPU's SIMD lanes without exceeding hardware limits.
    /// - `threadgroups` is calculated as `ceil(threadCount / threadsPerGroup)`
    ///   to cover all elements. Kernels must include a bounds check
    ///   (`if (tid >= n) return;`) because the last threadgroup may have
    ///   excess threads beyond the actual data size.
    ///
    /// - Parameters:
    ///   - pipeline: The precompiled compute pipeline state to execute.
    ///   - buffers: An array of `(MTLBuffer, Int)` pairs, where each pair is
    ///     a buffer and its binding index in the kernel's argument table.
    ///   - threadCount: The total number of threads to launch (typically equal
    ///     to the number of data elements to process).
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

        // Calculate 1D grid dimensions. The GPU hardware will partition these
        // threadgroups across its compute units (shader cores).
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
