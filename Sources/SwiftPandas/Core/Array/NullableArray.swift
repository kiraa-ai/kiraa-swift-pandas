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
        let n = indices.count
        let srcCount = count

        // Fast path: allValid + all indices in range → pure gather
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

    /// Take elements where mask is true. `trueCount` must equal mask.filter({$0}).count.
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

// MARK: - Accelerate-optimized Double arithmetic on NullableArray

public extension NullableArray where T == Double {
    /// Accelerate-optimized element-wise addition with NA propagation.
    static func + (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data + rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Accelerate-optimized element-wise subtraction with NA propagation.
    static func - (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data - rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Accelerate-optimized element-wise multiplication with NA propagation.
    static func * (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data * rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }

    /// Accelerate-optimized element-wise division with NA propagation.
    static func / (lhs: NullableArray<Double>, rhs: NullableArray<Double>) -> NullableArray<Double> {
        precondition(lhs.count == rhs.count)
        let combinedMask = lhs.mask & rhs.mask
        let resultData: NativeArray<Double> = lhs.data / rhs.data
        return NullableArray(data: resultData, mask: combinedMask)
    }
}

// MARK: - Accelerate-optimized Double aggregations on NullableArray

public extension NullableArray where T == Double {
    /// Accelerate-optimized sum. Fast-path when no NAs.
    func sum() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.sum($0) }
        }
        // Masked path: compact valid values then sum
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.sum($0) }
    }

    /// Accelerate-optimized min. Fast-path when no NAs.
    func min() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.min($0) }
        }
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.min($0) }
    }

    /// Accelerate-optimized max. Fast-path when no NAs.
    func max() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.max($0) }
        }
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.max($0) }
    }

    /// Accelerate-optimized mean. Fast-path when no NAs.
    func mean() -> Double? {
        guard validCount > 0 else { return nil }
        if mask.allValid {
            return data.withUnsafeBufferPointer { VectorOps.mean($0) }
        }
        let valid = dropNA()
        return valid.withUnsafeBufferPointer { VectorOps.mean($0) }
    }

    /// Accelerate-optimized variance. Fast-path when no NAs.
    func variance(ddof: Int = 1) -> Double? {
        guard validCount > ddof else { return nil }
        if mask.allValid {
            return data.variance(ddof: ddof)
        }
        let valid = dropNA()
        return valid.variance(ddof: ddof)
    }

    /// Accelerate-optimized standard deviation.
    func std(ddof: Int = 1) -> Double? {
        variance(ddof: ddof)?.squareRoot()
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
