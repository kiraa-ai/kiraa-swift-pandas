import Metal

/// Threshold-based dispatch for GPU vs CPU execution paths.
/// Metal is required on all supported platforms (macOS 13+, iOS 16+).
/// CPU fast-path beats GPU for datasets under ~500K rows due to GPU dispatch overhead.
public enum MetalDispatch {

    /// Minimum row count to use GPU for GroupBy operations.
    /// Set high because the CPU raw-pointer accumulation path is faster than
    /// GPU atomic reductions for typical group counts (< 100K groups).
    /// GPU GroupBy suffers from atomic contention when many threads write
    /// to few accumulators, plus synchronous kernel dispatch overhead.
    public static var groupByThreshold = 10_000_000

    /// Minimum row count to use GPU for Merge operations.
    public static var mergeThreshold = 500_000

    /// Whether Metal GPU is available on this device.
    public static var isAvailable: Bool {
        MetalContext.shared != nil
    }

    /// Check if GPU should be used given dataset size.
    public static func shouldUseGPU(rowCount: Int, threshold: Int) -> Bool {
        isAvailable && rowCount >= threshold
    }
}
