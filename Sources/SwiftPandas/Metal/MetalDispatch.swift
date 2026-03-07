import Metal

/// Threshold-based dispatch for GPU vs CPU execution paths.
/// Metal is required on all supported platforms (macOS 13+, iOS 16+).
/// Small datasets fall back to CPU to avoid GPU dispatch overhead (~50μs).
public enum MetalDispatch {

    /// Minimum row count to use GPU for GroupBy operations.
    public static var groupByThreshold = 1_000

    /// Minimum row count to use GPU for Merge operations.
    public static var mergeThreshold = 1_000

    /// Whether Metal GPU is available on this device.
    public static var isAvailable: Bool {
        MetalContext.shared != nil
    }

    /// Check if GPU should be used given dataset size.
    public static func shouldUseGPU(rowCount: Int, threshold: Int) -> Bool {
        isAvailable && rowCount >= threshold
    }
}
