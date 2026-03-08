// MARK: - VectorOps.swift
// ===========================================================================
// Vectorized Math Layer for SwiftPandas
// ===========================================================================
//
// This file provides the low-level, element-wise numeric primitives that
// underpin every arithmetic and statistical operation in SwiftPandas (Series
// math, DataFrame aggregations, GroupBy reductions, etc.).
//
// Conditional Compilation
// -----------------------
// The implementation uses conditional compilation via the custom flag
// `ACCELERATE_AVAILABLE`:
//
//   - When the flag IS defined (Apple platforms — macOS, iOS, tvOS, watchOS,
//     visionOS), every operation dispatches to the Accelerate framework's vDSP
//     routines, which leverage hand-tuned SIMD (NEON on ARM, SSE/AVX on x86)
//     to process vectors at near-peak memory bandwidth.
//
//   - When the flag is NOT defined (Linux, Windows, or any non-Apple target),
//     each operation falls back to a simple scalar `for` loop.  These loops
//     are still correct and reasonably fast (the Swift optimizer can auto-
//     vectorize simple loops), but they lack the micro-optimised instruction
//     scheduling of Accelerate.
//
// The flag is expected to be set in the Swift Package Manager build settings
// (e.g., `.define("ACCELERATE_AVAILABLE", .when(platforms: [.macOS, ...]))`).
//
// vDSP Argument-Order Pitfalls
// ----------------------------
// Several vDSP functions use a reversed argument order relative to what you
// might expect:
//
//   - `vDSP_vsubD(B, 1, A, 1, C, 1, N)` computes `C = A - B` (NOT `B - A`).
//     The *first* pointer is the subtrahend (what is subtracted), and the
//     *second* pointer is the minuend (what it is subtracted from).
//
//   - `vDSP_vdivD(B, 1, A, 1, C, 1, N)` computes `C = A / B` (NOT `B / A`).
//     The *first* pointer is the divisor and the *second* is the dividend.
//
// The wrapper methods in this file account for these reversals so that
// callers see the intuitive `subtract(a, b) -> a - b` semantics.
//
// Design Rationale: Why UnsafeBufferPointer?
// ------------------------------------------
// All methods operate on `UnsafeBufferPointer<Double>` /
// `UnsafeMutableBufferPointer<Double>` rather than `[Double]`.  This avoids
// accidental array copies (Swift arrays are COW, but passing them to C
// functions requires a temporary pointer anyway) and makes the boundary
// between safe Swift and unsafe C interop explicit.  Callers are expected to
// use `withUnsafeBufferPointer` / `withUnsafeMutableBufferPointer` to obtain
// the pointer spans.
//
// Thread Safety
// -------------
// `VectorOps` is a caseless enum (no stored state), so all methods are
// inherently safe to call from any thread.  The caller is responsible for
// ensuring that the buffer pointers do not alias each other in unsupported
// ways (input and output buffers should not overlap unless explicitly noted).
// ===========================================================================

#if ACCELERATE_AVAILABLE
import Accelerate
#endif

/// Caseless enum providing cross-platform vectorized operations on contiguous
/// `Double` buffers.
///
/// On Apple platforms (when `ACCELERATE_AVAILABLE` is defined), every method
/// dispatches to the corresponding Accelerate / vDSP routine for
/// hardware-accelerated SIMD execution.  On all other platforms, each method
/// falls back to a straightforward scalar loop that the Swift compiler may
/// auto-vectorize.
///
/// All methods are `static` — `VectorOps` carries no instance state and is
/// declared as an `enum` to prevent instantiation.
public enum VectorOps {
    // MARK: - Element-wise arithmetic

    /// Compute the element-wise sum of two vectors.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] + b[i]
    ///
    /// - Parameters:
    ///   - a:      The first input vector.
    ///   - b:      The second input vector.  Must have the same count as `a`.
    ///   - result: The output buffer.  Must have the same count as `a`.
    ///
    /// - Precondition: `a.count == b.count && a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vaddD(a, 1, b, 1, result, 1, N)`.
    /// Argument order is straightforward — no reversal needed.
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

    /// Compute the element-wise difference of two vectors.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] - b[i]
    ///
    /// - Parameters:
    ///   - a:      The minuend vector (values to subtract *from*).
    ///   - b:      The subtrahend vector (values to subtract).  Same count as `a`.
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == b.count && a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vsubD(b, 1, a, 1, result, 1, N)`.
    /// Note the **reversed argument order**: `vDSP_vsubD` computes
    /// `result = secondArg - firstArg`, so we pass `b` first and `a` second
    /// to achieve `result = a - b`.
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

    /// Compute the element-wise product of two vectors.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] * b[i]
    ///
    /// - Parameters:
    ///   - a:      The first input vector.
    ///   - b:      The second input vector.  Same count as `a`.
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == b.count && a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vmulD(a, 1, b, 1, result, 1, N)`.
    /// Argument order is straightforward (multiplication is commutative).
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

    /// Compute the element-wise quotient of two vectors.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] / b[i]
    ///
    /// - Parameters:
    ///   - a:      The dividend vector (numerators).
    ///   - b:      The divisor vector (denominators).  Same count as `a`.
    ///             Division by zero follows IEEE 754 semantics (produces +/-inf
    ///             or NaN).
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == b.count && a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vdivD(b, 1, a, 1, result, 1, N)`.
    /// Note the **reversed argument order**: `vDSP_vdivD` computes
    /// `result = secondArg / firstArg`, so we pass `b` (divisor) first and
    /// `a` (dividend) second to achieve `result = a / b`.
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

    /// Compute the sum of all elements in a vector.
    ///
    /// - Parameter a: The input vector.
    /// - Returns: The scalar sum of every element.
    ///
    /// **Accelerate path:** Calls `vDSP_sveD(a, 1, &result, N)` which uses a
    /// pairwise summation algorithm internally, providing better numerical
    /// accuracy than a naive sequential accumulation on large vectors.
    ///
    /// **Scalar fallback:** Simple left-to-right accumulation.
    ///
    /// - Complexity: O(n).
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

    /// Compute the arithmetic mean of all elements in a vector.
    ///
    /// - Parameter a: The input vector.
    /// - Returns: The mean value.  Returns `NaN` if the vector is empty (scalar
    ///   fallback only; the Accelerate path assumes non-empty input).
    ///
    /// **Accelerate path:** Calls `vDSP_meanvD(a, 1, &result, N)` which
    /// computes the mean in a single pass with compensated summation.
    ///
    /// **Scalar fallback:** Delegates to `sum(_:)` and divides by `count`.
    ///
    /// - Complexity: O(n).
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

    /// Find the maximum value in a vector.
    ///
    /// - Parameter a: The input vector.
    /// - Returns: The largest element.  The scalar fallback returns `-.infinity`
    ///   for an empty vector.
    ///
    /// **Accelerate path:** Calls `vDSP_maxvD(a, 1, &result, N)`.
    ///
    /// - Complexity: O(n).
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

    /// Find the minimum value in a vector.
    ///
    /// - Parameter a: The input vector.
    /// - Returns: The smallest element.  The scalar fallback returns `+.infinity`
    ///   for an empty vector.
    ///
    /// **Accelerate path:** Calls `vDSP_minvD(a, 1, &result, N)`.
    ///
    /// - Complexity: O(n).
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

    /// Multiply every element of a vector by a scalar constant.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] * scalar
    ///
    /// - Parameters:
    ///   - a:      The input vector.
    ///   - scalar: The scalar multiplicand.
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vsmulD(a, 1, &scalar, result, 1, N)`.
    /// The scalar must be passed by reference (`&s`) per the vDSP C API
    /// convention.
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

    /// Add a scalar constant to every element of a vector.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] + scalar
    ///
    /// - Parameters:
    ///   - a:      The input vector.
    ///   - scalar: The scalar addend.
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vsaddD(a, 1, &scalar, result, 1, N)`.
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

    /// Subtract a scalar constant from every element of a vector.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] - scalar
    ///
    /// - Parameters:
    ///   - a:      The input vector.
    ///   - scalar: The scalar subtrahend.
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == result.count`.
    ///
    /// **Accelerate path:** There is no dedicated `vDSP_vssubD`. Instead this
    /// method negates the scalar and calls `vDSP_vsaddD(a, 1, &(-scalar),
    /// result, 1, N)`, which adds `(-scalar)` — effectively subtracting the
    /// original scalar from every element.
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

    /// Divide every element of a vector by a scalar constant.
    ///
    /// For each index `i` in `0 ..< a.count`:
    ///
    ///     result[i] = a[i] / scalar
    ///
    /// - Parameters:
    ///   - a:      The input vector (dividends).
    ///   - scalar: The scalar divisor.  Division by zero follows IEEE 754
    ///             semantics.
    ///   - result: The output buffer.  Same count as `a`.
    ///
    /// - Precondition: `a.count == result.count`.
    ///
    /// **Accelerate path:** Calls `vDSP_vsdivD(a, 1, &scalar, result, 1, N)`.
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

    /// Compute the sum of squared deviations from a given mean value.
    ///
    /// This is the core building block for variance and standard deviation:
    ///
    ///     result = Σ (a[i] - mean)²    for i in 0 ..< a.count
    ///
    /// Callers typically divide the result by `n` (population variance) or
    /// `n - 1` (sample variance / Bessel's correction) afterward.
    ///
    /// - Parameters:
    ///   - a:    The input vector of observations.
    ///   - mean: The pre-computed mean of the observations.  Passing a
    ///           pre-computed mean allows the caller to choose between
    ///           population mean and sample mean, or to reuse a cached value.
    /// - Returns: The scalar sum of squared deviations.
    ///
    /// ## Accelerate Two-Pass Algorithm
    ///
    /// The Accelerate path performs two vectorized passes over the data:
    ///
    /// 1. **Subtract mean** — `vDSP_vsaddD` adds `(-mean)` to every element,
    ///    producing a temporary `[Double]` array of deviations.
    /// 2. **Sum of squares** — `vDSP_svesqD` computes the sum of squares of
    ///    the deviation array in a single pass.
    ///
    /// This two-pass approach is numerically more stable than the naive
    /// single-pass formula `Σ(x²) - n*(mean²)`, which suffers from
    /// catastrophic cancellation when the mean is large relative to the
    /// variance.
    ///
    /// The temporary array allocation (`result`) is the one extra cost
    /// compared to a fused kernel, but it keeps the implementation simple
    /// and the vDSP calls individually optimal.
    ///
    /// **Scalar fallback:** A single-pass loop that computes each
    /// `(a[i] - mean)` difference and accumulates `diff * diff`.
    ///
    /// - Complexity: O(n) time, O(n) auxiliary space (Accelerate path) or
    ///   O(1) auxiliary space (scalar fallback).
    public static func sumOfSquaredDifferences(
        _ a: UnsafeBufferPointer<Double>,
        mean: Double
    ) -> Double {
        #if ACCELERATE_AVAILABLE
        // Pass 1: subtract the mean from every element.
        // We negate `mean` and use vDSP_vsaddD (vector + scalar add) so that
        // result[i] = a[i] + (-mean) = a[i] - mean.
        var m = -mean
        var result = [Double](repeating: 0, count: a.count)
        vDSP_vsaddD(a.baseAddress!, 1, &m, &result, 1, vDSP_Length(a.count))
        // Pass 2: compute the sum of the squares of the deviation vector.
        // vDSP_svesqD computes Σ(result[i]²).
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

    /// Sort a mutable vector of doubles in place.
    ///
    /// - Parameters:
    ///   - a:         The mutable buffer to sort.  Modified in place.
    ///   - ascending: Sort direction.  `true` (default) for ascending order,
    ///                `false` for descending.
    ///
    /// If the buffer contains zero or one element, the method returns
    /// immediately (no work to do).
    ///
    /// **Accelerate path:** Calls `vDSP_vsortD(a, N, order)` where `order` is
    /// `1` for ascending or `-1` for descending.  `vDSP_vsortD` performs a
    /// highly optimised in-place sort (typically a hybrid radix / introsort
    /// tuned for IEEE 754 doubles) with no auxiliary heap allocation.
    ///
    /// **Scalar fallback:** Copies the buffer into a Swift `Array`, sorts it
    /// using the standard library's `sorted()` (Timsort-based, O(n log n)),
    /// then writes the sorted values back into the mutable buffer via
    /// `update(from:)`.  This requires O(n) temporary memory.
    ///
    /// - Complexity: O(n log n) time for both paths.
    public static func sort(_ a: UnsafeMutableBufferPointer<Double>, ascending: Bool = true) {
        guard a.count > 1 else { return }
        #if ACCELERATE_AVAILABLE
        // vDSP_vsortD expects an Int32 flag: 1 = ascending, -1 = descending.
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
