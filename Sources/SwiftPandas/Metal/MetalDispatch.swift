// MARK: - MetalDispatch.swift
// ---------------------------------------------------------------------------
// Threshold-Based GPU/CPU Routing for SwiftPandas
// ---------------------------------------------------------------------------
//
// This file provides the decision logic for routing compute operations to
// either the Metal GPU path or the CPU fallback path. The routing is based
// on dataset size thresholds that have been empirically tuned to balance
// GPU compute throughput against the fixed overhead of GPU dispatch.
//
// Why Thresholds Exist:
//
// GPU compute has a fixed overhead per dispatch: command buffer creation,
// encoder setup, kernel launch latency, and synchronous wait. For small
// datasets, this overhead dominates the actual computation time, making
// the CPU path faster. The crossover point depends on the operation:
//
//   - **GroupBy (10M rows):** The CPU path uses raw-pointer accumulation
//     with no synchronization, which is extremely fast. The GPU path uses
//     atomic reductions that suffer contention when many threads write to
//     few group accumulators. The GPU only wins for very large datasets
//     where the parallelism compensates for atomic overhead.
//
//   - **Merge (500K rows):** Hash join is more naturally parallel. The
//     build phase has minimal contention (each right-table row writes to
//     a different hash slot most of the time), and the probe phase is
//     embarrassingly parallel. The GPU wins at a lower threshold.
//
// Configurability:
//
// The thresholds are `var` (not `let`) to allow runtime tuning by users
// who have profiled their specific workloads and hardware. For example,
// M1 Ultra with many GPU cores may benefit from lower thresholds, while
// integrated Intel GPUs may need higher thresholds.
//
// Availability:
//
// `isAvailable` delegates to `MetalContext.shared`, which returns `nil` on
// platforms without Metal support (e.g., Linux, iOS Simulator). When Metal
// is unavailable, `shouldUseGPU` always returns `false`, and callers
// transparently use the CPU path.
// ---------------------------------------------------------------------------

import Metal

/// Threshold-based dispatch for GPU vs CPU execution paths.
///
/// Metal is required on all supported platforms (macOS 13+, iOS 16+).
/// CPU fast-path beats GPU for datasets under ~500K rows due to GPU
/// dispatch overhead (command buffer creation, kernel launch latency,
/// synchronous wait).
///
/// Usage:
/// ```swift
/// if MetalDispatch.shouldUseGPU(rowCount: df.rowCount, threshold: MetalDispatch.groupByThreshold) {
///     // GPU path
/// } else {
///     // CPU fallback
/// }
/// ```
public enum MetalDispatch {

    /// Minimum row count to use GPU for GroupBy operations.
    ///
    /// Set high (10M) because the CPU raw-pointer accumulation path is faster
    /// than GPU atomic reductions for typical group counts (< 100K groups).
    /// GPU GroupBy suffers from atomic contention when many threads write
    /// to few accumulators, plus synchronous kernel dispatch overhead.
    ///
    /// This is a `var` to allow runtime tuning for specific hardware/workloads.
    public static var groupByThreshold = 10_000_000

    /// Minimum row count to use GPU for Merge (hash join) operations.
    ///
    /// Lower than `groupByThreshold` because hash join is more naturally
    /// parallel: the build phase has minimal contention and the probe phase
    /// is embarrassingly parallel across left-table rows.
    ///
    /// This is a `var` to allow runtime tuning for specific hardware/workloads.
    public static var mergeThreshold = 500_000

    /// Whether Metal GPU compute is available on this device.
    ///
    /// Returns `false` on platforms without Metal support (Linux, iOS Simulator)
    /// or on hardware that lacks a Metal-capable GPU. Delegates to
    /// `MetalContext.shared`, which attempts lazy initialization on first access.
    public static var isAvailable: Bool {
        MetalContext.shared != nil
    }

    /// Determine whether GPU should be used for an operation given the dataset size.
    ///
    /// Returns `true` only when Metal is available **and** the row count meets
    /// or exceeds the specified threshold. When this returns `false`, callers
    /// should use the CPU fallback path.
    ///
    /// - Parameters:
    ///   - rowCount: The number of rows in the dataset to be processed.
    ///   - threshold: The minimum row count for GPU to be worthwhile
    ///     (typically `groupByThreshold` or `mergeThreshold`).
    /// - Returns: `true` if GPU execution is recommended for this workload size.
    public static func shouldUseGPU(rowCount: Int, threshold: Int) -> Bool {
        isAvailable && rowCount >= threshold
    }
}
