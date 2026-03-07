#if ACCELERATE_AVAILABLE
import Accelerate
#endif

/// Cross-platform vectorized operations.
///
/// On Apple platforms, dispatches to Accelerate framework (vDSP) for
/// SIMD-optimized performance. On Linux, falls back to scalar loops.
public enum VectorOps {
    // MARK: - Element-wise arithmetic

    /// Element-wise addition: result[i] = a[i] + b[i]
    public static func add(
        _ a: UnsafeBufferPointer<Double>,
        _ b: UnsafeBufferPointer<Double>,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == b.count && a.count == result.count)
        #if ACCELERATE_AVAILABLE
        vDSP_vaddD(a.baseAddress!, 1, b.baseAddress!, 1, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] + b[i] }
        #endif
    }

    /// Element-wise subtraction: result[i] = a[i] - b[i]
    public static func subtract(
        _ a: UnsafeBufferPointer<Double>,
        _ b: UnsafeBufferPointer<Double>,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == b.count && a.count == result.count)
        #if ACCELERATE_AVAILABLE
        vDSP_vsubD(b.baseAddress!, 1, a.baseAddress!, 1, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] - b[i] }
        #endif
    }

    /// Element-wise multiplication: result[i] = a[i] * b[i]
    public static func multiply(
        _ a: UnsafeBufferPointer<Double>,
        _ b: UnsafeBufferPointer<Double>,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == b.count && a.count == result.count)
        #if ACCELERATE_AVAILABLE
        vDSP_vmulD(a.baseAddress!, 1, b.baseAddress!, 1, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] * b[i] }
        #endif
    }

    /// Element-wise division: result[i] = a[i] / b[i]
    public static func divide(
        _ a: UnsafeBufferPointer<Double>,
        _ b: UnsafeBufferPointer<Double>,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == b.count && a.count == result.count)
        #if ACCELERATE_AVAILABLE
        vDSP_vdivD(b.baseAddress!, 1, a.baseAddress!, 1, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] / b[i] }
        #endif
    }

    // MARK: - Reductions

    /// Sum of all elements.
    public static func sum(_ a: UnsafeBufferPointer<Double>) -> Double {
        #if ACCELERATE_AVAILABLE
        var result: Double = 0
        vDSP_sveD(a.baseAddress!, 1, &result, vDSP_Length(a.count))
        return result
        #else
        var total: Double = 0
        for i in 0..<a.count { total += a[i] }
        return total
        #endif
    }

    /// Mean of all elements.
    public static func mean(_ a: UnsafeBufferPointer<Double>) -> Double {
        #if ACCELERATE_AVAILABLE
        var result: Double = 0
        vDSP_meanvD(a.baseAddress!, 1, &result, vDSP_Length(a.count))
        return result
        #else
        guard a.count > 0 else { return .nan }
        return sum(a) / Double(a.count)
        #endif
    }

    /// Maximum value.
    public static func max(_ a: UnsafeBufferPointer<Double>) -> Double {
        #if ACCELERATE_AVAILABLE
        var result: Double = 0
        vDSP_maxvD(a.baseAddress!, 1, &result, vDSP_Length(a.count))
        return result
        #else
        guard a.count > 0 else { return -.infinity }
        var result = a[0]
        for i in 1..<a.count { if a[i] > result { result = a[i] } }
        return result
        #endif
    }

    /// Minimum value.
    public static func min(_ a: UnsafeBufferPointer<Double>) -> Double {
        #if ACCELERATE_AVAILABLE
        var result: Double = 0
        vDSP_minvD(a.baseAddress!, 1, &result, vDSP_Length(a.count))
        return result
        #else
        guard a.count > 0 else { return .infinity }
        var result = a[0]
        for i in 1..<a.count { if a[i] < result { result = a[i] } }
        return result
        #endif
    }

    // MARK: - Scalar operations

    /// Multiply all elements by a scalar: result[i] = a[i] * scalar
    public static func scalarMultiply(
        _ a: UnsafeBufferPointer<Double>,
        _ scalar: Double,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == result.count)
        #if ACCELERATE_AVAILABLE
        var s = scalar
        vDSP_vsmulD(a.baseAddress!, 1, &s, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] * scalar }
        #endif
    }

    /// Add a scalar to all elements: result[i] = a[i] + scalar
    public static func scalarAdd(
        _ a: UnsafeBufferPointer<Double>,
        _ scalar: Double,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == result.count)
        #if ACCELERATE_AVAILABLE
        var s = scalar
        vDSP_vsaddD(a.baseAddress!, 1, &s, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] + scalar }
        #endif
    }

    /// Subtract a scalar from all elements: result[i] = a[i] - scalar
    public static func scalarSubtract(
        _ a: UnsafeBufferPointer<Double>,
        _ scalar: Double,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == result.count)
        #if ACCELERATE_AVAILABLE
        var s = -scalar
        vDSP_vsaddD(a.baseAddress!, 1, &s, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] - scalar }
        #endif
    }

    /// Divide all elements by a scalar: result[i] = a[i] / scalar
    public static func scalarDivide(
        _ a: UnsafeBufferPointer<Double>,
        _ scalar: Double,
        result: UnsafeMutableBufferPointer<Double>
    ) {
        precondition(a.count == result.count)
        #if ACCELERATE_AVAILABLE
        var s = scalar
        vDSP_vsdivD(a.baseAddress!, 1, &s, result.baseAddress!, 1, vDSP_Length(a.count))
        #else
        for i in 0..<a.count { result[i] = a[i] / scalar }
        #endif
    }

    // MARK: - Variance / Standard Deviation

    /// Sum of squared differences from mean: Σ(a[i] - mean)²
    public static func sumOfSquaredDifferences(
        _ a: UnsafeBufferPointer<Double>,
        mean: Double
    ) -> Double {
        #if ACCELERATE_AVAILABLE
        // Subtract mean, then compute sum of squares
        var m = -mean
        var result = [Double](repeating: 0, count: a.count)
        // a[i] - mean
        vDSP_vsaddD(a.baseAddress!, 1, &m, &result, 1, vDSP_Length(a.count))
        // sum of squares
        var sumSq: Double = 0
        vDSP_svesqD(result, 1, &sumSq, vDSP_Length(a.count))
        return sumSq
        #else
        var sumSq: Double = 0
        for i in 0..<a.count {
            let diff = a[i] - mean
            sumSq += diff * diff
        }
        return sumSq
        #endif
    }

    // MARK: - Sorting

    /// In-place sort using Accelerate's vDSP_vsortD.
    public static func sort(_ a: UnsafeMutableBufferPointer<Double>, ascending: Bool = true) {
        guard a.count > 1 else { return }
        #if ACCELERATE_AVAILABLE
        // vDSP_vsortD sorts in ascending (1) or descending (-1) order
        var order: Int32 = ascending ? 1 : -1
        vDSP_vsortD(a.baseAddress!, vDSP_Length(a.count), order)
        #else
        let sorted = ascending
            ? Array(UnsafeBufferPointer(a)).sorted()
            : Array(UnsafeBufferPointer(a)).sorted(by: >)
        _ = a.update(from: sorted)
        #endif
    }
}
