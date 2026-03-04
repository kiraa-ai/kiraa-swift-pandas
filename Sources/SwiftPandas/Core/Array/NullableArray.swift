/// Array with a separate validity bitmap supporting NA values.
///
/// Combines a NativeArray<T> for data with a BitVector for validity,
/// using only 1 extra bit per element rather than wrapping each element
/// in Optional<T>. This matches Apache Arrow's validity bitmap approach.
public struct NullableArray<T> {
    /// The underlying data. Values at NA positions are meaningless.
    internal var data: NativeArray<T>

    /// Validity bitmap: 1 = valid, 0 = NA.
    internal var mask: BitVector

    // MARK: - Initializers

    /// Create from data and mask arrays.
    public init(data: NativeArray<T>, mask: BitVector) {
        precondition(data.count == mask.bitCount, "Data and mask must have same length")
        self.data = data
        self.mask = mask
    }

    /// Create from a NativeArray with no NAs (all valid).
    public init(_ data: NativeArray<T>) {
        self.data = data
        self.mask = BitVector(repeating: true, count: data.count)
    }

    /// Create from an array of optionals.
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

    /// Create from an array of optional strings.
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

    /// Number of elements (including NAs).
    public var count: Int { data.count }

    /// Number of valid (non-NA) values.
    public var validCount: Int { mask.popcount }

    /// Number of NA values.
    public var naCount: Int { mask.naCount }

    /// Whether the array has any NA values.
    public var hasNAs: Bool { mask.naCount > 0 }

    /// Total memory usage in bytes.
    public var nbytes: Int { data.nbytes + (mask.words.count * 8) }

    /// Access element at position. Returns nil for NA.
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

    /// Boolean mask: true where value is NA.
    public func isNA() -> [Bool] {
        (~mask).boolArray
    }

    /// Boolean mask: true where value is valid (not NA).
    public func notNA() -> [Bool] {
        mask.boolArray
    }

    // MARK: - Fill

    /// Fill NA values with a constant, returning a NativeArray (no more NAs).
    public func fillNA(value: T) -> NativeArray<T> {
        var result = data.copy()
        for i in 0..<count where !mask[i] {
            result[i] = value
        }
        return result
    }

    /// Fill NA values, returning another NullableArray (still potentially nullable).
    public func fillNANullable(value: T) -> NullableArray<T> {
        NullableArray(data: fillNA(value: value), mask: BitVector(repeating: true, count: count))
    }

    /// Drop NA values, returning a NativeArray of only valid values.
    public func dropNA() -> NativeArray<T> {
        var result = ContiguousArray<T>()
        result.reserveCapacity(validCount)
        for i in 0..<count where mask[i] {
            result.append(data[i])
        }
        return NativeArray(result)
    }

    // MARK: - Copy

    /// Deep copy.
    public func copy() -> NullableArray<T> {
        NullableArray(data: data.copy(), mask: mask)
    }

    // MARK: - Sendable (conditional)
    // NullableArray: Sendable conformance declared below via extension

    // MARK: - Take

    /// Take elements at specified indices. Indices of -1 produce NA.
    public func take(indices: [Int]) -> NullableArray<T> where T: ExpressibleByIntegerLiteral {
        var values = ContiguousArray<T>()
        values.reserveCapacity(indices.count)
        var bools = [Bool]()
        bools.reserveCapacity(indices.count)

        for i in indices {
            if i >= 0 && i < count && mask[i] {
                values.append(data[i])
                bools.append(true)
            } else {
                values.append(0)
                bools.append(false)
            }
        }
        return NullableArray(data: NativeArray(values), mask: BitVector(bools))
    }
}

// MARK: - Sendable

extension NullableArray: Sendable where T: Sendable {}

// MARK: - Equatable

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

// MARK: - Numeric operations on NullableArray

public extension NullableArray where T: Numeric & Comparable {
    /// Sum of valid values. Returns nil if no valid values.
    func sum() -> T? {
        guard validCount > 0 else { return nil }
        var total: T = 0
        for i in 0..<count where mask[i] {
            total += data[i]
        }
        return total
    }

    /// Minimum of valid values.
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

    /// Maximum of valid values.
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
    static func + (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data + rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Element-wise subtraction with NA propagation.
    static func - (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data - rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Element-wise multiplication with NA propagation.
    static func * (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data * rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }
}

// MARK: - Floating-point operations

public extension NullableArray where T: FloatingPoint {
    /// Mean of valid values.
    func mean() -> T? {
        guard validCount > 0 else { return nil }
        return sum()! / T(validCount)
    }

    /// Variance of valid values.
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

    /// Standard deviation of valid values.
    func std(ddof: Int = 1) -> T? {
        variance(ddof: ddof)?.squareRoot()
    }

    /// Element-wise division with NA propagation.
    static func / (lhs: NullableArray<T>, rhs: NullableArray<T>) -> NullableArray<T> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData = lhs.data / rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }
}

// MARK: - Hashable element operations

public extension NullableArray where T: Hashable & ExpressibleByIntegerLiteral {
    /// Return unique non-NA values.
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

    /// Factorize: encode values as integer codes + uniques. NA gets code -1.
    func factorize() -> (codes: [Int], uniques: NativeArray<T>) {
        var mapping = [T: Int]()
        var uniques = ContiguousArray<T>()
        var codes = [Int]()
        codes.reserveCapacity(count)

        for i in 0..<count {
            if mask[i] {
                let v = data[i]
                if let code = mapping[v] {
                    codes.append(code)
                } else {
                    let code = uniques.count
                    mapping[v] = code
                    uniques.append(v)
                    codes.append(code)
                }
            } else {
                codes.append(-1)
            }
        }
        return (codes, NativeArray(uniques))
    }
}
