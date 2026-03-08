/// Compact validity bitmap using 1 bit per element.
///
/// Used by NullableArray to track which elements are valid (non-NA).
/// Bit 1 = valid, bit 0 = NA. Stored in UInt64 words for efficiency.
public struct BitVector: Sendable, Equatable {
    /// Packed storage: each UInt64 holds 64 validity bits.
    internal var words: [UInt64]

    /// The number of bits (elements) this vector tracks.
    public private(set) var bitCount: Int

    /// Cached flag: true means all bits are known to be set. False means unknown.
    internal var _knownAllValid: Bool

    // MARK: - Initializers

    /// Create a BitVector with all bits set to the given value.
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

    /// Create from an array of booleans.
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

    // MARK: - Access

    /// Get or set the validity of element at position.
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

    /// Count of set bits (valid elements).
    public var popcount: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Count of unset bits (NA elements).
    public var naCount: Int {
        bitCount - popcount
    }

    /// Whether all bits are set (no NAs).
    public var allValid: Bool {
        if _knownAllValid { return true }
        return popcount == bitCount
    }

    /// Whether all bits are unset (all NAs).
    public var allNA: Bool {
        popcount == 0
    }

    /// Convert to array of booleans.
    public var boolArray: [Bool] {
        (0..<bitCount).map { self[$0] }
    }

    // MARK: - Bitwise operations

    /// AND: both must be valid.
    public static func & (lhs: BitVector, rhs: BitVector) -> BitVector {
        precondition(lhs.bitCount == rhs.bitCount)
        var result = lhs
        for i in 0..<result.words.count {
            result.words[i] &= rhs.words[i]
        }
        return result
    }

    /// OR: either is valid.
    public static func | (lhs: BitVector, rhs: BitVector) -> BitVector {
        precondition(lhs.bitCount == rhs.bitCount)
        var result = lhs
        for i in 0..<result.words.count {
            result.words[i] |= rhs.words[i]
        }
        return result
    }

    /// NOT: invert validity.
    public prefix static func ~ (bv: BitVector) -> BitVector {
        var result = bv
        for i in 0..<result.words.count {
            result.words[i] = ~result.words[i]
        }
        // Clear trailing bits
        if result.bitCount % 64 != 0 {
            let trailingBits = result.bitCount % 64
            result.words[result.words.count - 1] &= (1 << trailingBits) - 1
        }
        return result
    }

    // MARK: - Concatenation

    /// Concatenate another BitVector, appending its bits after this one.
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

    /// Create a BitVector by concatenating multiple BitVectors.
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

    // MARK: - Take

    /// Take bits at specified indices.
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

extension BitVector: CustomStringConvertible {
    public var description: String {
        "BitVector(\(popcount)/\(bitCount) valid)"
    }
}
