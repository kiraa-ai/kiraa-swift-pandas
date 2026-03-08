// ============================================================================
// BitVector.swift — Compact Validity Bitmap for Missing-Value Tracking
// ============================================================================
//
// This file implements `BitVector`, a densely packed bitmap that tracks which
// elements in a NullableArray are valid (non-NA) versus missing (NA). Using
// one bit per element instead of one byte (or one Bool) per element reduces
// the validity mask's memory footprint by 8x and enables bulk bitwise
// operations that process 64 elements at a time.
//
// ## Memory Layout
//
// Bits are stored in an array of `UInt64` "words". Each word holds 64
// validity bits. The mapping from element index to bit position is:
//
//     word index = elementIndex / 64
//     bit  index = elementIndex % 64
//
// Within each word, bits are ordered **LSB-first** (least significant bit
// first): bit 0 of word 0 corresponds to element 0, bit 1 of word 0
// corresponds to element 1, and so on up to bit 63 of word 0 for element 63.
// Element 64 starts at bit 0 of word 1.
//
//     Word 0:  [ bit0  bit1  bit2  ...  bit63 ]   (elements 0–63)
//     Word 1:  [ bit0  bit1  bit2  ...  bit63 ]   (elements 64–127)
//     ...
//
// When the total number of elements is not a multiple of 64, the **trailing
// bits** in the last word (those beyond `bitCount`) are kept cleared (zero).
// This invariant is maintained by the initializer and the NOT (`~`) operator,
// ensuring that `popcount` always reflects the true number of valid elements.
//
// ## Bit Semantics
//
//   - **1** = valid (the element at this position holds a meaningful value)
//   - **0** = NA / missing (the element is absent or null)
//
// This convention matches Apache Arrow's validity bitmap format and allows
// "all valid" vectors to be represented as words filled with `~0` (all ones).
//
// ## Performance Considerations
//
// - **Popcount** uses `UInt64.nonzeroBitCount`, which compiles to a single
//   hardware `POPCNT` instruction on x86-64 and `CNT` on ARM64.
// - **Bitwise AND / OR / NOT** operate on entire 64-bit words, processing
//   64 elements per CPU instruction.
// - **`_knownAllValid`** is a cached flag that short-circuits `allValid`
//   checks without scanning the words array. It is conservatively set to
//   `false` whenever a mutation *might* introduce a zero bit; it is only
//   set to `true` when the vector is known to be all-ones at construction
//   time.
//
// ============================================================================

/// A compact, fixed-size validity bitmap that stores one bit per element.
///
/// `BitVector` is the core data structure behind SwiftPandas' missing-value
/// support. Every ``NullableArray`` holds a `BitVector` of the same length as
/// its data buffer, where a set bit (`1`) means the corresponding element is
/// **valid** and a cleared bit (`0`) means it is **NA** (missing).
///
/// ## Usage Example
///
/// ```swift
/// // Create a validity mask: elements 0 and 2 are valid, element 1 is NA.
/// var mask = BitVector([true, false, true])
/// assert(mask.popcount == 2)
/// assert(mask.naCount == 1)
/// assert(mask[0] == true)
/// assert(mask[1] == false)
/// ```
///
/// ## Value Semantics
///
/// `BitVector` is a value type (struct). Copies are independent — mutating one
/// does not affect the other. The underlying `words` array benefits from
/// Swift's standard copy-on-write optimization for `Array`.
public struct BitVector: Sendable, Equatable {
    /// Packed storage: each `UInt64` holds 64 validity bits in LSB-first order.
    ///
    /// The number of words is always `(bitCount + 63) / 64`, i.e., the minimum
    /// number of 64-bit integers required to hold `bitCount` bits. Any trailing
    /// bits in the last word (beyond position `bitCount % 64`) are guaranteed
    /// to be zero.
    internal var words: [UInt64]

    /// The total number of bits (elements) this vector tracks.
    ///
    /// This may be less than `words.count * 64` when the element count is not
    /// a multiple of 64. The difference consists of zero-padded trailing bits
    /// in the last word.
    public private(set) var bitCount: Int

    /// A cached optimization flag indicating whether all bits are known to be
    /// set (all valid).
    ///
    /// When `true`, callers can skip scanning the `words` array entirely.
    /// This flag is set to `true` only during construction with
    /// `repeating: true`; it is conservatively reset to `false` by any
    /// operation that might introduce a zero bit (e.g., subscript set,
    /// `append(contentsOf:)`). The flag is **not** automatically re-derived
    /// after mutations — it is a one-way latch toward `false`.
    internal var _knownAllValid: Bool

    // MARK: - Initializers

    /// Creates a `BitVector` with all bits set to the given value.
    ///
    /// - Parameters:
    ///   - value: If `true`, all bits are set (all elements valid). If `false`,
    ///     all bits are cleared (all elements NA).
    ///   - count: The number of elements (bits) to track. Must be non-negative.
    ///
    /// When `value` is `true`, the trailing bits in the last word are cleared
    /// to maintain the invariant that bits beyond `bitCount` are always zero.
    ///
    /// - Complexity: O(*n* / 64) where *n* is `count`, since the words array
    ///   is allocated and filled in bulk.
    public init(repeating value: Bool, count: Int) {
        self.bitCount = count
        self._knownAllValid = value
        let wordCount = (count + 63) / 64
        self.words = [UInt64](repeating: value ? ~0 : 0, count: wordCount)
        // Clear trailing bits in the last word if not perfectly aligned
        if value && count % 64 != 0 {
            let trailingBits = count % 64
            words[wordCount - 1] = (1 << trailingBits) - 1
        }
    }

    /// Creates a `BitVector` from an array of boolean values.
    ///
    /// Each `true` in the input sets the corresponding bit to 1 (valid);
    /// each `false` leaves it at 0 (NA).
    ///
    /// - Parameter bools: An array of boolean values. The resulting
    ///   `BitVector` will have `bitCount == bools.count`.
    ///
    /// - Complexity: O(*n*) where *n* is `bools.count`, since each boolean
    ///   must be individually mapped to its bit position.
    ///
    /// - Note: The `_knownAllValid` flag is set to `false` regardless of
    ///   input, because scanning for all-true would cost the same as the
    ///   construction itself. Use `init(repeating:count:)` when you know
    ///   all elements are valid.
    public init(_ bools: [Bool]) {
        self.bitCount = bools.count
        self._knownAllValid = false
        let wordCount = (bools.count + 63) / 64
        self.words = [UInt64](repeating: 0, count: wordCount)
        for (i, b) in bools.enumerated() where b {
            let wordIndex = i / 64
            let bitIndex = i % 64
            words[wordIndex] |= 1 << bitIndex
        }
    }

    // MARK: - Element Access

    /// Accesses the validity bit at the given element index.
    ///
    /// - Parameter index: The zero-based element index. Must satisfy
    ///   `0 <= index < bitCount`; a precondition failure is triggered
    ///   otherwise.
    ///
    /// - Returns (get): `true` if the element is valid, `false` if NA.
    ///
    /// - Behavior (set): Setting to `false` clears the bit and
    ///   conservatively resets `_knownAllValid` to `false`. Setting to
    ///   `true` sets the bit but does **not** re-derive `_knownAllValid`
    ///   (doing so would require an O(*n*) scan).
    ///
    /// - Complexity: O(1) for both get and set.
    public subscript(index: Int) -> Bool {
        get {
            precondition(index >= 0 && index < bitCount, "Index \(index) out of range")
            let wordIndex = index / 64
            let bitIndex = index % 64
            return (words[wordIndex] >> bitIndex) & 1 == 1
        }
        set {
            precondition(index >= 0 && index < bitCount, "Index \(index) out of range")
            if !newValue { _knownAllValid = false }
            let wordIndex = index / 64
            let bitIndex = index % 64
            if newValue {
                words[wordIndex] |= 1 << bitIndex
            } else {
                words[wordIndex] &= ~(1 << bitIndex)
            }
        }
    }

    // MARK: - Counts and Queries

    /// The number of set bits (valid elements) in this vector.
    ///
    /// Computed by summing the hardware-accelerated popcount of each word.
    /// On modern CPUs this compiles to a single `POPCNT` (x86-64) or `CNT`
    /// (ARM64 NEON) instruction per word.
    ///
    /// - Complexity: O(*n* / 64) where *n* is `bitCount`.
    public var popcount: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// The number of cleared bits (NA / missing elements) in this vector.
    ///
    /// Equivalent to `bitCount - popcount`.
    ///
    /// - Complexity: O(*n* / 64) where *n* is `bitCount`.
    public var naCount: Int {
        bitCount - popcount
    }

    /// Whether every element is valid (no NAs present).
    ///
    /// Returns `true` immediately if the `_knownAllValid` cache flag is set;
    /// otherwise falls back to comparing `popcount == bitCount`.
    ///
    /// - Complexity: O(1) when cached, O(*n* / 64) otherwise.
    public var allValid: Bool {
        if _knownAllValid { return true }
        return popcount == bitCount
    }

    /// Whether every element is NA (all bits cleared).
    ///
    /// - Complexity: O(*n* / 64) where *n* is `bitCount`.
    public var allNA: Bool {
        popcount == 0
    }

    /// Converts the bitmap to a flat array of `Bool` values.
    ///
    /// Each element in the returned array corresponds to one bit: `true` for
    /// valid, `false` for NA. This is useful for interop with APIs that
    /// expect `[Bool]`, but incurs an 8x memory expansion compared to the
    /// packed representation.
    ///
    /// - Complexity: O(*n*) where *n* is `bitCount`.
    public var boolArray: [Bool] {
        (0..<bitCount).map { self[$0] }
    }

    // MARK: - Bitwise Operations

    /// Bitwise AND: produces a vector where a bit is set only if it is set in
    /// **both** operands.
    ///
    /// In validity-mask terms, the result marks an element as valid only when
    /// it is valid in both `lhs` and `rhs`. This is the correct mask for
    /// element-wise binary operations (e.g., `series1 + series2`): if either
    /// operand is NA, the result should also be NA.
    ///
    /// - Precondition: `lhs.bitCount == rhs.bitCount`.
    /// - Complexity: O(*n* / 64) where *n* is `bitCount`.
    public static func & (lhs: BitVector, rhs: BitVector) -> BitVector {
        precondition(lhs.bitCount == rhs.bitCount)
        var result = lhs
        for i in 0..<result.words.count {
            result.words[i] &= rhs.words[i]
        }
        return result
    }

    /// Bitwise OR: produces a vector where a bit is set if it is set in
    /// **either** (or both) operands.
    ///
    /// In validity-mask terms, the result marks an element as valid when it
    /// is valid in at least one of `lhs` or `rhs`. This is useful for
    /// coalesce-style operations where a fallback value fills in NAs.
    ///
    /// - Precondition: `lhs.bitCount == rhs.bitCount`.
    /// - Complexity: O(*n* / 64) where *n* is `bitCount`.
    public static func | (lhs: BitVector, rhs: BitVector) -> BitVector {
        precondition(lhs.bitCount == rhs.bitCount)
        var result = lhs
        for i in 0..<result.words.count {
            result.words[i] |= rhs.words[i]
        }
        return result
    }

    /// Bitwise NOT: inverts every bit in the vector.
    ///
    /// Valid elements become NA and vice versa. After inversion, trailing bits
    /// in the last word are cleared to maintain the invariant that bits beyond
    /// `bitCount` are always zero.
    ///
    /// This is useful for selecting the complement of a boolean mask — for
    /// example, `~mask` selects all elements that were previously NA.
    ///
    /// - Complexity: O(*n* / 64) where *n* is `bitCount`.
    public prefix static func ~ (bv: BitVector) -> BitVector {
        var result = bv
        for i in 0..<result.words.count {
            result.words[i] = ~result.words[i]
        }
        // Clear trailing bits to maintain the zero-padding invariant
        if result.bitCount % 64 != 0 {
            let trailingBits = result.bitCount % 64
            result.words[result.words.count - 1] &= (1 << trailingBits) - 1
        }
        return result
    }

    // MARK: - Concatenation

    /// Appends the bits of another `BitVector` after the last bit of this one.
    ///
    /// The resulting vector has `bitCount == self.bitCount + other.bitCount`.
    /// The `words` array is extended as needed, and bits from `other` are
    /// shifted into position.
    ///
    /// Two code paths handle the copy:
    /// - **Aligned (fast path)**: when `self.bitCount` is a multiple of 64,
    ///   whole words from `other` can be copied directly without shifting.
    /// - **Unaligned (general path)**: when there is a bit offset within the
    ///   last word, each word from `other` is split across two destination
    ///   words using left/right shifts.
    ///
    /// - Parameter other: The `BitVector` whose bits will be appended.
    /// - Complexity: O(*m* / 64) where *m* is `other.bitCount`.
    public mutating func append(contentsOf other: BitVector) {
        _knownAllValid = false
        let oldCount = bitCount
        let newCount = oldCount + other.bitCount
        let newWordCount = (newCount + 63) / 64

        // Extend words array if needed
        while words.count < newWordCount {
            words.append(0)
        }

        // Copy bits from other — fast path when aligned on word boundary
        let bitOffset = oldCount % 64
        if bitOffset == 0 {
            let startWord = oldCount / 64
            for i in 0..<other.words.count {
                words[startWord + i] = other.words[i]
            }
        } else {
            let startWord = oldCount / 64
            for i in 0..<other.words.count {
                words[startWord + i] |= other.words[i] << bitOffset
                if startWord + i + 1 < newWordCount {
                    words[startWord + i + 1] |= other.words[i] >> (64 - bitOffset)
                }
            }
        }
        bitCount = newCount
    }

    /// Creates a new `BitVector` by concatenating multiple vectors end-to-end.
    ///
    /// This is a convenience factory method that repeatedly calls
    /// ``append(contentsOf:)`` to join all vectors in order.
    ///
    /// **Fast path**: if every input vector has `allValid == true`, the result
    /// is constructed directly with `init(repeating: true, count:)`, avoiding
    /// per-word iteration entirely.
    ///
    /// - Parameter vectors: An array of `BitVector` instances to concatenate.
    ///   An empty array produces an empty (zero-length) `BitVector`.
    /// - Returns: A single `BitVector` whose bits are the ordered union of all
    ///   input vectors.
    /// - Complexity: O(*N* / 64) where *N* is the total number of bits across
    ///   all input vectors.
    public static func concat(_ vectors: [BitVector]) -> BitVector {
        let totalBits = vectors.reduce(0) { $0 + $1.bitCount }
        guard totalBits > 0 else { return BitVector(repeating: false, count: 0) }

        // Fast path: all are allValid
        if vectors.allSatisfy({ $0.allValid }) {
            return BitVector(repeating: true, count: totalBits)
        }

        var result = vectors[0]
        for i in 1..<vectors.count {
            result.append(contentsOf: vectors[i])
        }
        return result
    }

    // MARK: - Take (Gather)

    /// Creates a new `BitVector` by gathering bits at the specified indices.
    ///
    /// This is the bitmap equivalent of a "take" or "gather" operation: given
    /// an array of source indices, the resulting vector contains the bits from
    /// those positions in the original vector, in the order specified.
    ///
    /// Out-of-range indices (negative or `>= bitCount`) produce a `false`
    /// (NA) bit in the result, providing safe behavior for outer joins and
    /// other operations that may reference non-existent rows.
    ///
    /// - Parameter indices: An array of source indices. The result will have
    ///   `bitCount == indices.count`.
    /// - Returns: A new `BitVector` with bits gathered from the specified
    ///   positions.
    /// - Complexity: O(*k*) where *k* is `indices.count`, since each index
    ///   requires a single bit lookup.
    public func take(indices: [Int]) -> BitVector {
        var result = BitVector(repeating: false, count: indices.count)
        for (newIndex, oldIndex) in indices.enumerated() {
            if oldIndex >= 0 && oldIndex < bitCount {
                result[newIndex] = self[oldIndex]
            }
        }
        return result
    }
}

// MARK: - CustomStringConvertible

extension BitVector: CustomStringConvertible {
    /// A human-readable summary showing the number of valid bits out of the
    /// total, e.g., `"BitVector(42/50 valid)"`.
    public var description: String {
        "BitVector(\(popcount)/\(bitCount) valid)"
    }
}
