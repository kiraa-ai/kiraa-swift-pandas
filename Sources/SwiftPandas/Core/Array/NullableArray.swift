// ===----------------------------------------------------------------------===//
//
// NullableArray.swift
// SwiftPandas
//
// This file defines ``NullableArray<T>``, a nullable array type that combines
// a ``NativeArray<T>`` for contiguous data storage with a ``BitVector`` for
// validity tracking. This design follows the Apache Arrow columnar memory
// layout, where a separate validity bitmap (one bit per element) indicates
// which positions hold meaningful values and which are "NA" (not available /
// missing).
//
// ## Why a validity bitmap instead of Optional<T>?
//
// Using `[T?]` (array of optionals) would add 1-8 bytes of tag overhead per
// element (depending on T) and destroy contiguous memory layout, because
// Swift's Optional enum wraps each element individually. The bitmap approach
// adds only 1 bit per element (packed into UInt64 words) and keeps the data
// array (`NativeArray<T>`) fully contiguous, enabling:
//
//   - Direct pointer access to the data buffer for Accelerate / vDSP calls
//   - Cache-friendly sequential scans during aggregation
//   - Efficient bulk operations (bitwise AND/OR on validity masks)
//
// Values at NA positions in the data array are "garbage" / meaningless -- they
// exist only because the data array must be the same length as the validity
// bitmap. The zero-placeholder convention (using `0` or a caller-supplied
// `naPlaceholder`) keeps the data array valid for pointer-based operations
// even at NA positions.
//
// ## Fast-path / slow-path pattern
//
// Many operations in this file (take, arithmetic, aggregation) follow a
// two-tier pattern:
//
//   1. **Fast path** (`mask.allValid`): When the validity bitmap is all-ones
//      (no NAs), the operation can delegate directly to the underlying
//      ``NativeArray``'s implementation, which may itself be Accelerate-
//      optimized. No per-element validity checking is needed.
//
//   2. **Slow path**: When NAs are present, the operation must inspect the
//      validity bitmap at each position, skip or propagate NAs as appropriate,
//      and construct a new validity bitmap for the result.
//
// This pattern is critical for performance: the common case in many datasets
// is that columns have zero or very few NAs, so the fast path avoids the
// overhead of bitmap manipulation entirely.
//
// ## Accelerate-optimized Double overloads
//
// For ``T == Double``, specialized overloads of arithmetic operators and
// aggregation functions are provided. These shadow the generic ``Numeric`` and
// ``FloatingPoint`` versions. On the fast path (``allValid``), they delegate to
// ``VectorOps`` (Accelerate/vDSP) for SIMD-vectorized computation. On the slow
// path, they either compact valid values via ``dropNA()`` and then use
// Accelerate on the compacted buffer, or fall back to the generic loop.
//
// ===----------------------------------------------------------------------===//

/// A nullable array combining contiguous data storage with an Arrow-style
/// validity bitmap.
///
/// ``NullableArray<T>`` pairs a ``NativeArray<T>`` (the data buffer) with a
/// ``BitVector`` (the validity mask). Bit `i` of the mask is `1` if position
/// `i` holds a valid value and `0` if it is NA (missing). This design keeps
/// the data buffer contiguous and enables Accelerate-optimized operations on
/// the valid portions.
///
/// ## Invariants
///
/// - `data.count == mask.bitCount` at all times.
/// - Values at NA positions (`mask[i] == false`) are meaningless and must not
///   be read as data. They exist solely to maintain alignment between the data
///   buffer and the bitmap.
///
/// ## Memory layout
///
/// Total memory usage is approximately:
///
///     data.count * MemoryLayout<T>.stride  +  ceil(data.count / 64) * 8
///
/// For a million-element Double column, this is ~8 MB for data + ~16 KB for
/// the bitmap -- the bitmap overhead is negligible.
public struct NullableArray<T> {
    /// The underlying contiguous data buffer.
    ///
    /// Values at positions where ``mask`` is `false` (NA) are placeholder
    /// values (typically zero) and must not be interpreted as data. The buffer
    /// is always the same length as ``mask.bitCount``.
    internal var data: NativeArray<T>

    /// The validity bitmap: bit `i` is `1` for valid values, `0` for NA.
    ///
    /// Backed by a ``BitVector`` which stores bits packed into `UInt64` words.
    /// Operations like ``popcount`` (number of set bits) and ``allValid``
    /// (whether all bits are set) are computed efficiently over the word array.
    internal var mask: BitVector

    // MARK: - Initializers

    /// Create a ``NullableArray`` from explicit data and mask components.
    ///
    /// - Parameters:
    ///   - data: The contiguous data buffer.
    ///   - mask: The validity bitmap. Must have the same logical length
    ///     (`bitCount`) as `data.count`.
    /// - Precondition: `data.count == mask.bitCount`
    public init(data: NativeArray<T>, mask: BitVector) {
        precondition(data.count == mask.bitCount, "Data and mask must have same length")
        self.data = data
        self.mask = mask
    }

    /// Create a fully-valid ``NullableArray`` from a ``NativeArray`` (no NAs).
    ///
    /// - Parameter data: The contiguous data buffer. All positions will be
    ///   marked as valid (the mask is initialized to all-ones).
    ///
    /// This is the most common initializer for columns known to have no missing
    /// data. The resulting ``mask.allValid`` property will return `true`,
    /// enabling fast-path optimizations in all subsequent operations.
    public init(_ data: NativeArray<T>) {
        self.data = data
        self.mask = BitVector(repeating: true, count: data.count)
    }

    /// Create a ``NullableArray`` from an array of optionals.
    ///
    /// - Parameter elements: An array of `T?`. `nil` entries become NA
    ///   positions; non-nil entries become valid data. NA positions in the
    ///   data buffer are filled with `0` as a placeholder.
    /// - Requires: `T: ExpressibleByIntegerLiteral` so that `0` can be used
    ///   as the NA placeholder value.
    ///
    /// This initializer iterates the input once, building both the data buffer
    /// and the validity mask in a single pass.
    public init(_ elements: [T?]) where T: ExpressibleByIntegerLiteral {
        var values = ContiguousArray<T>()
        values.reserveCapacity(elements.count)
        var bools = [Bool]()
        bools.reserveCapacity(elements.count)
        for elem in elements {
            if let v = elem {
                values.append(v)
                bools.append(true)
            } else {
                values.append(0) // placeholder for NA slot
                bools.append(false)
            }
        }
        self.data = NativeArray(values)
        self.mask = BitVector(bools)
    }

    /// Create a ``NullableArray`` from an array of optionals with a custom
    /// NA placeholder value.
    ///
    /// - Parameters:
    ///   - elements: An array of `T?`. `nil` entries become NA positions.
    ///   - naPlaceholder: The value to store in the data buffer at NA positions.
    ///     This is useful for types that do not conform to
    ///     ``ExpressibleByIntegerLiteral`` (e.g., custom value types).
    ///
    /// The placeholder value is never read as meaningful data; it exists only
    /// to fill the data buffer so that its length matches the mask.
    public init(_ elements: [T?], naPlaceholder: T) {
        var values = ContiguousArray<T>()
        values.reserveCapacity(elements.count)
        var bools = [Bool]()
        bools.reserveCapacity(elements.count)
        for elem in elements {
            if let v = elem {
                values.append(v)
                bools.append(true)
            } else {
                values.append(naPlaceholder)
                bools.append(false)
            }
        }
        self.data = NativeArray(values)
        self.mask = BitVector(bools)
    }

    // MARK: - Access

    /// The total number of elements (including NA positions).
    ///
    /// This is the logical length of the column and always equals
    /// ``data.count`` and ``mask.bitCount``.
    public var count: Int { data.count }

    /// The number of valid (non-NA) values.
    ///
    /// Delegates to ``BitVector.popcount``, which computes the number of set
    /// bits using efficient word-level population count operations. This is
    /// O(words) where words = ceil(count / 64), effectively O(1) for typical
    /// column sizes.
    public var validCount: Int { mask.popcount }

    /// The number of NA (missing) values.
    ///
    /// Computed as ``count - validCount`` to avoid a separate pass over the
    /// bitmap.
    public var naCount: Int { mask.naCount }

    /// Whether this array has any NA values.
    ///
    /// Equivalent to `naCount > 0` but may short-circuit earlier by checking
    /// ``BitVector.naCount``.
    public var hasNAs: Bool { mask.naCount > 0 }

    /// Total memory usage in bytes: data buffer + validity bitmap words.
    ///
    /// The data buffer contributes `count * MemoryLayout<T>.stride` bytes.
    /// The bitmap contributes `ceil(count / 64) * 8` bytes (one UInt64 word
    /// per 64 elements).
    public var nbytes: Int { data.nbytes + (mask.words.count * 8) }

    /// Access the element at the given position, returning `nil` for NA.
    ///
    /// - Getter: Returns `data[index]` if `mask[index]` is true (valid),
    ///   otherwise returns `nil`.
    /// - Setter: If the new value is non-nil, stores it in `data[index]` and
    ///   sets `mask[index] = true`. If nil, sets `mask[index] = false` (the
    ///   data value at that position becomes meaningless).
    ///
    /// - Precondition: `index` must be in `0..<count`.
    public subscript(index: Int) -> T? {
        get {
            precondition(index >= 0 && index < count, "Index \(index) out of range")
            return mask[index] ? data[index] : nil
        }
        set {
            precondition(index >= 0 && index < count, "Index \(index) out of range")
            if let v = newValue {
                data[index] = v
                mask[index] = true
            } else {
                mask[index] = false
            }
        }
    }

    /// Produce a Boolean mask where `true` indicates an NA (missing) position.
    ///
    /// This is the inverse of the validity bitmap and is used by downstream
    /// operations like ``Series.isna()`` and ``DataFrame.dropna()``.
    ///
    /// - Returns: An array of length ``count`` where `result[i] == true` iff
    ///   position `i` is NA.
    public func isNA() -> [Bool] {
        (~mask).boolArray
    }

    /// Produce a Boolean mask where `true` indicates a valid (non-NA) position.
    ///
    /// This is the direct Boolean expansion of the validity bitmap.
    ///
    /// - Returns: An array of length ``count`` where `result[i] == true` iff
    ///   position `i` is valid.
    public func notNA() -> [Bool] {
        mask.boolArray
    }

    // MARK: - Fill

    /// Replace all NA positions with a constant value, returning a dense
    /// ``NativeArray`` with no missing data.
    ///
    /// - Parameter value: The fill value for every NA position.
    /// - Returns: A ``NativeArray<T>`` (not nullable) where every position has
    ///   a meaningful value.
    ///
    /// Iterates only over NA positions (using the bitmap), leaving valid
    /// positions unchanged. The returned array is a deep copy, so the original
    /// is not modified.
    public func fillNA(value: T) -> NativeArray<T> {
        var result = data.copy()
        for i in 0..<count where !mask[i] {
            result[i] = value
        }
        return result
    }

    /// Replace all NA positions with a constant value, returning another
    /// ``NullableArray`` with an all-valid mask.
    ///
    /// - Parameter value: The fill value for every NA position.
    /// - Returns: A ``NullableArray`` where ``hasNAs`` is `false`.
    ///
    /// Unlike ``fillNA(value:)`` which returns a ``NativeArray``, this variant
    /// preserves the nullable wrapper so that the result can be used in
    /// contexts that expect ``NullableArray`` (e.g., as a column in a
    /// DataFrame).
    public func fillNANullable(value: T) -> NullableArray<T> {
        NullableArray(data: fillNA(value: value), mask: BitVector(repeating: true, count: count))
    }

    /// Extract only the valid (non-NA) values into a dense ``NativeArray``.
    ///
    /// - Returns: A ``NativeArray<T>`` of length ``validCount`` containing
    ///   only the elements at valid positions, in their original order.
    ///
    /// This is used by the Accelerate-optimized aggregation slow path: when
    /// NAs are present, valid values are compacted into a dense buffer so that
    /// vDSP functions (which require contiguous input) can operate on them.
    public func dropNA() -> NativeArray<T> {
        var result = ContiguousArray<T>()
        result.reserveCapacity(validCount)
        for i in 0..<count where mask[i] {
            result.append(data[i])
        }
        return NativeArray(result)
    }

    // MARK: - Copy

    /// Return a deep (independent) copy of this nullable array.
    ///
    /// Both the data buffer and the validity bitmap are copied, so mutations
    /// to the original will not affect the copy and vice versa.
    public func copy() -> NullableArray<T> {
        NullableArray(data: data.copy(), mask: mask)
    }

    // MARK: - Sendable (conditional)
    // NullableArray: Sendable conformance declared below via extension

    // MARK: - Take

    /// Gather elements at the specified integer positions into a new nullable
    /// array.
    ///
    /// - Parameter indices: An array of zero-based positions. An index of `-1`
    ///   or any out-of-range value produces an NA in the output.
    /// - Returns: A new ``NullableArray`` of length `indices.count`.
    ///
    /// ## Fast path (`mask.allValid`)
    ///
    /// When the source array has no NAs, this method delegates the data gather
    /// to ``NativeArray.take(indices:)`` and only needs to check whether each
    /// index is in range to build the output mask. If *all* indices are in
    /// range (the common case for non-join operations), the output mask is
    /// simply all-ones -- no per-element bitmap manipulation at all.
    ///
    /// ## Slow path (source has NAs)
    ///
    /// When the source has NAs, each gathered position must be checked against
    /// both the index bounds *and* the source validity bitmap. The output mask
    /// bit is set only if the index is in range AND the source position is
    /// valid.
    ///
    /// - Requires: `T: ExpressibleByIntegerLiteral` (for zero-filling the data
    ///   buffer at NA output positions via ``NativeArray.take(indices:)``).
    public func take(indices: [Int]) -> NullableArray<T> where T: ExpressibleByIntegerLiteral {
        let n = indices.count
        let srcCount = count

        // Fast path: allValid + all indices in range -> pure gather
        if mask.allValid {
            let newData = data.take(indices: indices)
            var allInRange = true
            indices.withUnsafeBufferPointer { idx in
                for i in 0..<n where idx[i] < 0 || idx[i] >= srcCount {
                    allInRange = false; break
                }
            }
            if allInRange {
                return NullableArray(data: newData, mask: BitVector(repeating: true, count: n))
            }
            var resultMask = BitVector(repeating: true, count: n)
            indices.withUnsafeBufferPointer { idx in
                for i in 0..<n {
                    if idx[i] < 0 || idx[i] >= srcCount { resultMask[i] = false }
                }
            }
            return NullableArray(data: newData, mask: resultMask)
        }

        // Slow path: source has NAs, build mask per element
        let newData = data.take(indices: indices)
        var resultMask = BitVector(repeating: false, count: n)
        indices.withUnsafeBufferPointer { idx in
            for i in 0..<n {
                let j = idx[i]
                if j >= 0 && j < srcCount && mask[j] {
                    resultMask[i] = true
                }
            }
        }
        return NullableArray(data: newData, mask: resultMask)
    }

    /// Gather elements where a Boolean mask is `true` into a new nullable array.
    ///
    /// - Parameters:
    ///   - filterMask: A Boolean array of the same length as this array.
    ///     Positions where `filterMask[i]` is `true` are included in the output.
    ///   - trueCount: The precomputed number of `true` values in `filterMask`.
    ///     Must exactly equal `filterMask.filter { $0 }.count`.
    /// - Returns: A new ``NullableArray`` of length `trueCount`.
    ///
    /// ## Fast path (`self.mask.allValid`)
    ///
    /// When the source has no NAs, the output is also fully valid. The data
    /// gather delegates to ``NativeArray.take(mask:trueCount:)`` and the output
    /// mask is all-ones.
    ///
    /// ## Slow path (source has NAs)
    ///
    /// When the source has NAs, each selected position must propagate its
    /// validity from the source bitmap to the output bitmap. The data is
    /// gathered via a manual loop that also builds the output ``BitVector``.
    public func take(mask filterMask: [Bool], trueCount: Int) -> NullableArray<T> {
        if self.mask.allValid {
            // Fast path: no NAs in source, just take data values
            return NullableArray(data: data.take(mask: filterMask, trueCount: trueCount),
                               mask: BitVector(repeating: true, count: trueCount))
        }
        // Slow path: source has NAs, copy both data and validity
        var values = ContiguousArray<T>()
        values.reserveCapacity(trueCount)
        var resultMask = BitVector(repeating: false, count: trueCount)
        var j = 0
        data.withUnsafeBufferPointer { src in
            filterMask.withUnsafeBufferPointer { m in
                for i in 0..<m.count {
                    if m[i] {
                        values.append(src[i])
                        resultMask[j] = self.mask[i]
                        j += 1
                    }
                }
            }
        }
        return NullableArray(data: NativeArray(values), mask: resultMask)
    }
}

// MARK: - Sendable

/// ``NullableArray`` is ``Sendable`` when its element type is ``Sendable``,
/// because both ``NativeArray<T>`` (conditionally Sendable) and ``BitVector``
/// (a value type composed of `[UInt64]`) are safe to transfer across
/// concurrency domains.
extension NullableArray: Sendable where T: Sendable {}

// MARK: - Equatable

/// Element-wise equality for nullable arrays.
///
/// Two ``NullableArray`` values are equal if and only if:
/// - They have the same count.
/// - For every position `i`, both are either both valid or both NA.
/// - For every valid position, the data values are equal.
///
/// Values at NA positions are *not* compared (they are meaningless).
extension NullableArray: Equatable where T: Equatable {
    public static func == (lhs: NullableArray<T>, rhs: NullableArray<T>) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in 0..<lhs.count {
            let lValid = lhs.mask[i]
            let rValid = rhs.mask[i]
            if lValid != rValid { return false }
            if lValid && lhs.data[i] != rhs.data[i] { return false }
        }
        return true
    }
}

// MARK: - CustomStringConvertible

/// Human-readable display: shows up to the first 10 elements (with "NA" for
/// missing positions), followed by an ellipsis, total count, and NA count if
/// the array is longer than 10 elements.
extension NullableArray: CustomStringConvertible {
    public var description: String {
        let elements = (0..<Swift.min(count, 10)).map { i -> String in
            if mask[i] {
                return "\(data[i])"
            } else {
                return "NA"
            }
        }.joined(separator: ", ")
        if count > 10 {
            return "[\(elements), ... (\(count) elements, \(naCount) NAs)]"
        }
        return "[\(elements)]"
    }
}

// MARK: - Generic Numeric operations on NullableArray

/// Numeric aggregation and element-wise arithmetic for nullable arrays with
/// ``Numeric & Comparable`` elements.
///
/// All aggregation functions (``sum()``, ``min()``, ``max()``) skip NA
/// positions and return `nil` if there are no valid values. Element-wise
/// arithmetic operators propagate NAs: if *either* operand is NA at position
/// `i`, the result is NA at position `i` (the combined mask is a bitwise AND
/// of the two input masks).
///
/// For ``T == Double``, the Accelerate-optimized overloads defined later in
/// this file shadow these generic versions.
public extension NullableArray where T: Numeric & Comparable {
    /// The sum of all valid (non-NA) values.
    ///
    /// - Returns: The sum, or `nil` if there are no valid values.
    /// - Complexity: O(n), single pass with bitmap check per element.
    func sum() -> T? {
        guard validCount > 0 else { return nil }
        var total: T = 0
        for i in 0..<count where mask[i] {
            total += data[i]
        }
        return total
    }

    /// The minimum of all valid (non-NA) values.
    ///
    /// - Returns: The minimum, or `nil` if there are no valid values.
    /// - Complexity: O(n), single pass.
    func min() -> T? {
        guard validCount > 0 else { return nil }
        var result: T?
        for i in 0..<count where mask[i] {
            if let r = result {
                if data[i] < r { result = data[i] }
            } else {
                result = data[i]
            }
        }
        return result
    }

    /// The maximum of all valid (non-NA) values.
    ///
    /// - Returns: The maximum, or `nil` if there are no valid values.
    /// - Complexity: O(n), single pass.
    func max() -> T? {
        guard validCount > 0 else { return nil }
        var result: T?
        for i in 0..<count where mask[i] {
            if let r = result {
                if data[i] > r { result = data[i] }
            } else {
                result = data[i]
            }
        }
        return result
    }

    /// Element-wise addition with NA propagation.
    ///
    /// The result is NA at position `i` if *either* `lhs` or `rhs` is NA at
    /// `i`. The combined validity mask is `lhs.mask & rhs.mask` (bitwise AND).
    /// The data addition delegates to ``NativeArray``'s `+` operator, which
    /// operates on all positions (including NA ones, whose results are
    /// meaningless but harmless).
    ///
    /// - Precondition: `lhs.count == rhs.count`
    static func + (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data + rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Element-wise subtraction with NA propagation.
    ///
    /// - Precondition: `lhs.count == rhs.count`
    /// - See: ``+`` for NA propagation semantics.
    static func - (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data - rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Element-wise multiplication with NA propagation.
    ///
    /// - Precondition: `lhs.count == rhs.count`
    /// - See: ``+`` for NA propagation semantics.
    static func * (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data * rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }
}

// MARK: - Generic Floating-point operations

/// Statistical operations and division for nullable arrays with
/// ``FloatingPoint`` elements.
///
/// These are the generic fallbacks; the ``T == Double`` overloads below shadow
/// them with Accelerate-optimized implementations.
public extension NullableArray where T: FloatingPoint {
    /// The arithmetic mean of all valid (non-NA) values.
    ///
    /// - Returns: The mean, or `nil` if there are no valid values.
    /// - Complexity: O(n)
    func mean() -> T? {
        guard validCount > 0 else { return nil }
        return sum()! / T(validCount)
    }

    /// The variance of all valid (non-NA) values.
    ///
    /// Uses a two-pass algorithm: first computes the mean, then computes the
    /// sum of squared differences from the mean.
    ///
    /// - Parameter ddof: Delta degrees of freedom. The divisor is
    ///   `validCount - ddof`. Defaults to 1 (sample variance).
    /// - Returns: The variance, or `nil` if `validCount <= ddof`.
    func variance(ddof: Int = 1) -> T? {
        guard validCount > ddof else { return nil }
        let m = mean()!
        var sumSq: T = 0
        for i in 0..<count where mask[i] {
            let diff = data[i] - m
            sumSq += diff * diff
        }
        return sumSq / T(validCount - ddof)
    }

    /// The standard deviation of all valid (non-NA) values.
    ///
    /// - Parameter ddof: Delta degrees of freedom. Defaults to 1.
    /// - Returns: Square root of ``variance(ddof:)``, or `nil` if
    ///   `validCount <= ddof`.
    func std(ddof: Int = 1) -> T? {
        variance(ddof: ddof)?.squareRoot()
    }

    /// Element-wise division with NA propagation.
    ///
    /// Division by zero at valid positions follows IEEE 754 semantics
    /// (produces infinity or NaN).
    ///
    /// - Precondition: `lhs.count == rhs.count`
    static func / (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data / rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }
}

// MARK: - Accelerate-optimized Double arithmetic on NullableArray

/// Accelerate/vDSP-optimized element-wise arithmetic for ``NullableArray<Double>``.
///
/// These overloads shadow the generic ``Numeric & Comparable`` arithmetic
/// operators above. Each operator implements a two-tier strategy:
///
/// 1. **Fast path** (`lhs.mask.allValid && rhs.mask.allValid`): Both operands
///    have no NAs, so the operation delegates directly to ``VectorOps``
///    (Accelerate/vDSP) for SIMD-vectorized computation. The output mask is
///    simply the input mask (all-valid).
///
/// 2. **Slow path**: At least one operand has NAs. The combined mask is
///    `lhs.mask & rhs.mask` (bitwise AND), and the data arithmetic uses the
///    ``NativeArray<Double>`` operators (which are themselves Accelerate-
///    optimized). This means the data computation is still fast; only the mask
///    combination adds overhead.
public extension NullableArray where T == Double {
    /// Accelerate-optimized element-wise addition with NA propagation.
    ///
    /// Fast path when both operands are fully valid; slow path computes
    /// `lhs.mask & rhs.mask` for the output validity.
    ///
    /// - Precondition: `lhs.count == rhs.count`
    static func + (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        if lhs.mask.allValid && rhs.mask.allValid {
            let n = lhs.count
            let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                lhs.data.withUnsafeBufferPointer { l in
                    rhs.data.withUnsafeBufferPointer { r in
                        VectorOps.add(l, r, result: buf)
                    }
                }
                count = n
            }
            return NullableArray(data: NativeArray(result), mask: lhs.mask)
        }
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data + rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Accelerate-optimized element-wise subtraction with NA propagation.
    ///
    /// - Precondition: `lhs.count == rhs.count`
    /// - See: ``+`` for fast-path / slow-path description.
    static func - (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        if lhs.mask.allValid && rhs.mask.allValid {
            let n = lhs.count
            let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                lhs.data.withUnsafeBufferPointer { l in
                    rhs.data.withUnsafeBufferPointer { r in
                        VectorOps.subtract(l, r, result: buf)
                    }
                }
                count = n
            }
            return NullableArray(data: NativeArray(result), mask: lhs.mask)
        }
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data - rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Accelerate-optimized element-wise multiplication with NA propagation.
    ///
    /// - Precondition: `lhs.count == rhs.count`
    /// - See: ``+`` for fast-path / slow-path description.
    static func * (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        if lhs.mask.allValid && rhs.mask.allValid {
            let n = lhs.count
            let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                lhs.data.withUnsafeBufferPointer { l in
                    rhs.data.withUnsafeBufferPointer { r in
                        VectorOps.multiply(l, r, result: buf)
                    }
                }
                count = n
            }
            return NullableArray(data: NativeArray(result), mask: lhs.mask)
        }
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data * rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Accelerate-optimized element-wise division with NA propagation.
    ///
    /// - Precondition: `lhs.count == rhs.count`
    /// - See: ``+`` for fast-path / slow-path description.
    static func / (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        if lhs.mask.allValid && rhs.mask.allValid {
            let n = lhs.count
            let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                lhs.data.withUnsafeBufferPointer { l in
                    rhs.data.withUnsafeBufferPointer { r in
                        VectorOps.divide(l, r, result: buf)
                    }
                }
                count = n
            }
            return NullableArray(data: NativeArray(result), mask: lhs.mask)
        }
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data / rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }
}

// MARK: - Accelerate-optimized Double aggregations on NullableArray

/// Accelerate/vDSP-optimized aggregation for ``NullableArray<Double>``.
///
/// These overloads shadow the generic ``FloatingPoint`` aggregation methods.
/// Each follows the same two-tier strategy:
///
/// 1. **Fast path** (`mask.allValid`): Delegates directly to the underlying
///    ``NativeArray<Double>``'s Accelerate-optimized method (which itself uses
///    vDSP). No NA checking overhead at all.
///
/// 2. **Slow path**: Calls ``dropNA()`` to compact valid values into a dense
///    ``NativeArray<Double>``, then runs the Accelerate-optimized aggregation
///    on the compacted buffer. This incurs one O(n) allocation + copy, but the
///    subsequent aggregation is still SIMD-vectorized.
///
/// The slow path's ``dropNA()`` allocation is acceptable because:
/// - Columns with NAs are less common than fully-valid columns.
/// - The compacted buffer is typically much smaller than the original.
/// - The alternative (per-element bitmap check in a scalar loop) would be
///   slower for large arrays than the allocate-compact-vDSP approach.
public extension NullableArray where T == Double {
    /// Accelerate-optimized sum. Fast-path when no NAs; slow-path compacts
    /// valid values via ``dropNA()`` then sums with vDSP.
    ///
    /// - Returns: The sum of valid values, or `nil` if there are no valid
    ///   values.
    func sum() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.sum($0) }
        }
        // Masked path: compact valid values then sum
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.sum($0) }
    }

    /// Accelerate-optimized minimum. Fast-path when no NAs; slow-path compacts
    /// valid values via ``dropNA()`` then finds min with vDSP.
    ///
    /// - Returns: The minimum valid value, or `nil` if there are no valid
    ///   values.
    func min() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.min($0) }
        }
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.min($0) }
    }

    /// Accelerate-optimized maximum. Fast-path when no NAs; slow-path compacts
    /// valid values via ``dropNA()`` then finds max with vDSP.
    ///
    /// - Returns: The maximum valid value, or `nil` if there are no valid
    ///   values.
    func max() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.max($0) }
        }
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.max($0) }
    }

    /// Accelerate-optimized arithmetic mean. Fast-path when no NAs; slow-path
    /// compacts valid values via ``dropNA()`` then computes mean with vDSP.
    ///
    /// - Returns: The mean of valid values, or `nil` if there are no valid
    ///   values.
    func mean() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.mean($0) }
        }
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.mean($0) }
    }

    /// Accelerate-optimized variance. Fast-path delegates to
    /// ``NativeArray<Double>.variance(ddof:)``; slow-path compacts via
    /// ``dropNA()`` then computes variance on the compacted buffer.
    ///
    /// - Parameter ddof: Delta degrees of freedom. Defaults to 1.
    /// - Returns: The variance, or `nil` if `validCount <= ddof`.
    func variance(ddof: Int = 1) -> Double? {
        guard validCount > ddof else { return nil }
        if mask.allValid {
            return data.variance(ddof: ddof)
        }
        let valid = dropNA()
        return valid.variance(ddof: ddof)
    }

    /// Accelerate-optimized standard deviation.
    ///
    /// - Parameter ddof: Delta degrees of freedom. Defaults to 1.
    /// - Returns: Square root of ``variance(ddof:)``, or `nil` if
    ///   `validCount <= ddof`.
    func std(ddof: Int = 1) -> Double? {
        variance(ddof: ddof)?.squareRoot()
    }
}

// MARK: - Hashable element operations

/// Deduplication and factorization for nullable arrays with ``Hashable``
/// elements.
///
/// These operations handle NA values explicitly: ``unique()`` includes at most
/// one NA entry in the output, and ``factorize()`` assigns code `-1` to all
/// NA positions.
public extension NullableArray where T: Hashable & ExpressibleByIntegerLiteral {
    /// Return unique values, preserving order of first occurrence.
    ///
    /// - Non-NA values are deduplicated using a ``Set``.
    /// - If any NA positions exist, exactly one NA entry is included in the
    ///   output (at the position of the first NA encountered).
    ///
    /// - Returns: A new ``NullableArray`` with distinct values only.
    /// - Complexity: O(n) average.
    func unique() -> NullableArray<T> {
        var seen = Set<T>()
        var values = ContiguousArray<T>()
        var bools = [Bool]()
        var hasNA = false

        for i in 0..<count {
            if mask[i] {
                if seen.insert(data[i]).inserted {
                    values.append(data[i])
                    bools.append(true)
                }
            } else if !hasNA {
                hasNA = true
                values.append(0)
                bools.append(false)
            }
        }
        return NullableArray(data: NativeArray(values), mask: BitVector(bools))
    }

    /// Encode each element as an integer code referencing a table of unique
    /// values (factorization).
    ///
    /// - Returns: A tuple `(codes, uniques)` where:
    ///   - `codes` is an `[Int]` of length ``count``. For valid positions,
    ///     `codes[i]` is the index into `uniques` for element `i`. For NA
    ///     positions, `codes[i]` is `-1`.
    ///   - `uniques` is a ``NativeArray<T>`` of distinct non-NA values in
    ///     order of first occurrence.
    ///
    /// Uses a ``Dictionary`` for the value-to-code mapping. The dictionary and
    /// uniques array are pre-allocated with capacity 128 (a heuristic for the
    /// expected number of unique values in a typical GroupBy key column).
    ///
    /// - Complexity: O(n) average.
    func factorize() -> (codes: [Int], uniques: NativeArray<T>) {
        let n = count
        guard n > 0 else { return ([], NativeArray(ContiguousArray<T>())) }

        // Pre-allocate codes array (-1 = NA)
        var codes = [Int](repeating: -1, count: n)
        var uniqueValues = ContiguousArray<T>()
        uniqueValues.reserveCapacity(128)

        // Use Dictionary for correctness with generic Hashable types
        // but pre-allocate and use direct data access
        var mapping = [T: Int]()
        mapping.reserveCapacity(128)

        data.withUnsafeBufferPointer { dataBuf in
            for i in 0..<n {
                guard mask[i] else { continue }
                let v = dataBuf[i]
                if let code = mapping[v] {
                    codes[i] = code
                } else {
                    let code = uniqueValues.count
                    mapping[v] = code
                    uniqueValues.append(v)
                    codes[i] = code
                }
            }
        }
        return (codes, NativeArray(uniqueValues))
    }
}
