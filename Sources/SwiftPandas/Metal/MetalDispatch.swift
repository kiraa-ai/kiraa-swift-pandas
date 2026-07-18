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

import Foundation
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

    // MARK: - Environment overrides
    //
    // These let operators tune routing without a rebuild — handy for
    // benchmarking, and to force the exact-and-fast CPU path when precision
    // matters more than raw throughput:
    //
    //   SWIFTPANDAS_DISABLE_METAL=1          — never use the GPU (CPU only)
    //   SWIFTPANDAS_GROUPBY_THRESHOLD=<n>    — min rows before GPU groupby
    //   SWIFTPANDAS_GROUPBY_MIN_GROUPS=<n>   — min distinct groups before GPU groupby
    //   SWIFTPANDAS_MERGE_THRESHOLD=<n>      — min rows before GPU merge

    private static func envInt(_ name: String) -> Int? {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = Int(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return value
    }

    private static func envFlag(_ name: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[name]?.lowercased() else { return false }
        return raw == "1" || raw == "true" || raw == "yes"
    }

    /// When `true`, all `shouldUseGPU` checks return `false` and every operation
    /// runs on the exact Float64 CPU path. Set `SWIFTPANDAS_DISABLE_METAL=1`.
    public static var metalDisabled = envFlag("SWIFTPANDAS_DISABLE_METAL")

    /// Minimum row count to use GPU for GroupBy operations.
    ///
    /// The GPU only wins for very large, **high-cardinality** group-bys. For the
    /// common low-cardinality case (a handful of groups) the CPU raw-pointer
    /// path is both faster and exact (Float64), so routing also consults
    /// ``groupByMinGroups`` — see ``shouldUseGPUForGroupBy(rowCount:groupCount:)``.
    ///
    /// A `var` (env-overridable via `SWIFTPANDAS_GROUPBY_THRESHOLD`) so it can be
    /// tuned for specific hardware/workloads.
    public static var groupByThreshold = envInt("SWIFTPANDAS_GROUPBY_THRESHOLD") ?? 10_000_000

    /// Minimum number of **distinct groups** before GPU groupby is worthwhile.
    ///
    /// GPU reduction accumulates into per-group atomics; with few groups, many
    /// threads contend on the same accumulators (slow) and a Float32 sum of
    /// millions of values loses precision. Above this many groups each group
    /// sums comparatively few rows, so contention is spread and precision is
    /// fine. Env-overridable via `SWIFTPANDAS_GROUPBY_MIN_GROUPS`.
    public static var groupByMinGroups = envInt("SWIFTPANDAS_GROUPBY_MIN_GROUPS") ?? 100_000

    /// Minimum row count to use GPU for Merge (hash join) operations.
    ///
    /// Lower than `groupByThreshold` because hash join is more naturally
    /// parallel: the build phase has minimal contention and the probe phase
    /// is embarrassingly parallel across left-table rows. Env-overridable via
    /// `SWIFTPANDAS_MERGE_THRESHOLD`.
    public static var mergeThreshold = envInt("SWIFTPANDAS_MERGE_THRESHOLD") ?? 500_000

    /// Whether Metal GPU compute is available on this device.
    ///
    /// Returns `false` on platforms without Metal support (Linux, iOS Simulator)
    /// or on hardware that lacks a Metal-capable GPU. Delegates to
    /// `MetalContext.shared`, which attempts lazy initialization on first access.
    public static var isAvailable: Bool {
        !metalDisabled && MetalContext.shared != nil
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

    /// GroupBy-specific routing that considers both row count **and** group
    /// cardinality. GPU is used only when Metal is available, the data is large
    /// enough (`groupByThreshold`), and there are enough distinct groups
    /// (`groupByMinGroups`) for the GPU to beat the exact CPU path.
    ///
    /// - Parameters:
    ///   - rowCount: Total rows to aggregate.
    ///   - groupCount: Number of distinct groups (known after factorization).
    public static func shouldUseGPUForGroupBy(rowCount: Int, groupCount: Int) -> Bool {
        isAvailable
            && rowCount >= groupByThreshold
            && groupCount >= groupByMinGroups
    }
}
