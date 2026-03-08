/// Contiguous, typed 1D array with copy-on-write semantics.
///
/// This is the Swift replacement for NumPy's ndarray for numeric types.
/// It stores elements contiguously in memory and uses reference counting
/// with CoW for efficient value-type semantics.
public struct NativeArray<T> {
    internal var buffer: ArrayBuffer<T>

    /// Ensures exclusive ownership of the buffer, copying if shared.
    internal mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&buffer) {
            buffer = ArrayBuffer(buffer.storage)
        }
    }

    // MARK: - Initializers

    /// Create from a Swift array.
    public init(_ elements: [T]) {
        self.buffer = ArrayBuffer(ContiguousArray(elements))
    }

    /// Create from a ContiguousArray.
    public init(_ elements: ContiguousArray<T>) {
        self.buffer = ArrayBuffer(elements)
    }

    /// Create an array filled with a repeated value.
    public init(repeating value: T, count: Int) {
        self.buffer = ArrayBuffer(repeating: value, count: count)
    }

    // MARK: - Access

    /// Number of elements.
    public var count: Int { buffer.count }

    /// Total memory usage in bytes.
    public var nbytes: Int { count * MemoryLayout<T>.stride }

    /// Whether the array is empty.
    public var isEmpty: Bool { count == 0 }

    /// Access element at position.
    public subscript(index: Int) -> T {
        get {
            precondition(index >= 0 && index < count, "Index \(index) out of range [0, \(count))")
            return buffer.storage[index]
        }
        set {
            precondition(index >= 0 && index < count, "Index \(index) out of range [0, \(count))")
            ensureUnique()
            buffer.storage[index] = newValue
        }
    }

    /// Access a slice as a new NativeArray.
    public subscript(range: Range<Int>) -> NativeArray<T> {
        let slice = buffer.storage[range]
        return NativeArray(ContiguousArray(slice))
    }

    /// Return the underlying data as a Swift Array.
    public var array: [T] {
        Array(buffer.storage)
    }

    /// Perform an operation with direct pointer access to the underlying storage.
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<T>) throws -> R) rethrows -> R {
        try buffer.storage.withUnsafeBufferPointer(body)
    }

    /// Perform a mutating operation with direct pointer access.
    public mutating func withUnsafeMutableBufferPointer<R>(
        _ body: (inout UnsafeMutableBufferPointer<T>) throws -> R
    ) rethrows -> R {
        ensureUnique()
        return try buffer.storage.withUnsafeMutableBufferPointer(body)
    }

    // MARK: - Copying

    /// Return a deep copy.
    public func copy() -> NativeArray<T> {
        NativeArray(buffer.storage)
    }

    // MARK: - Take

    /// Take elements at specified indices, creating a new array.
    public func take(indices: [Int]) -> NativeArray<T> where T: ExpressibleByIntegerLiteral {
        let n = indices.count
        let srcCount = count
        var result = ContiguousArray<T>(repeating: 0, count: n)
        buffer.storage.withUnsafeBufferPointer { src in
            indices.withUnsafeBufferPointer { idx in
                result.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<n {
                        let j = idx[i]
                        if j >= 0 && j < srcCount { dst[i] = src[j] }
                    }
                }
            }
        }
        return NativeArray(result)
    }

    /// Take elements where mask is true. `trueCount` must equal mask.filter({$0}).count.
    public func take(mask: [Bool], trueCount: Int) -> NativeArray<T> {
        // Use unsafeUninitializedCapacity to avoid per-element append overhead
        let arr = [T](unsafeUninitializedCapacity: trueCount) { dst, initializedCount in
            buffer.storage.withUnsafeBufferPointer { src in
                mask.withUnsafeBufferPointer { m in
                    var j = 0
                    for i in 0..<m.count {
                        if m[i] {
                            (dst.baseAddress! + j).initialize(to: src[i])
                            j += 1
                        }
                    }
                    initializedCount = j
                }
            }
        }
        return NativeArray(arr)
    }

    // MARK: - Append

    /// Append an element to the array.
    public mutating func append(_ value: T) {
        ensureUnique()
        buffer.storage.append(value)
    }

    /// Append contents of another NativeArray.
    public mutating func append(contentsOf other: NativeArray<T>) {
        ensureUnique()
        buffer.storage.append(contentsOf: other.buffer.storage)
    }
}

// MARK: - Sendable

extension NativeArray: Sendable where T: Sendable {}

// MARK: - Equatable

extension NativeArray: Equatable where T: Equatable {
    public static func == (lhs: NativeArray<T>, rhs: NativeArray<T>) -> Bool {
        lhs.buffer.storage == rhs.buffer.storage
    }
}

// MARK: - CustomStringConvertible

extension NativeArray: CustomStringConvertible {
    public var description: String {
        let elements = buffer.storage.prefix(10).map { "\($0)" }.joined(separator: ", ")
        if count > 10 {
            return "[\(elements), ... (\(count) elements)]"
        }
        return "[\(elements)]"
    }
}

// MARK: - Sequence & Collection

extension NativeArray: Sequence {
    public func makeIterator() -> IndexingIterator<ContiguousArray<T>> {
        buffer.storage.makeIterator()
    }
}

extension NativeArray: Collection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { count }
    public func index(after i: Int) -> Int { i + 1 }
}

extension NativeArray: RandomAccessCollection {}

// MARK: - Numeric operations

public extension NativeArray where T: Numeric & Comparable {
    /// Element-wise addition.
    static func + (lhs: NativeArray<T>, rhs: NativeArray<T>) -> NativeArray<T> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        var result = ContiguousArray<T>()
        result.reserveCapacity(lhs.count)
        for i in 0..<lhs.count {
            result.append(lhs.buffer.storage[i] + rhs.buffer.storage[i])
        }
        return NativeArray(result)
    }

    /// Element-wise subtraction.
    static func - (lhs: NativeArray<T>, rhs: NativeArray<T>) -> NativeArray<T> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        var result = ContiguousArray<T>()
        result.reserveCapacity(lhs.count)
        for i in 0..<lhs.count {
            result.append(lhs.buffer.storage[i] - rhs.buffer.storage[i])
        }
        return NativeArray(result)
    }

    /// Element-wise multiplication.
    static func * (lhs: NativeArray<T>, rhs: NativeArray<T>) -> NativeArray<T> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        var result = ContiguousArray<T>()
        result.reserveCapacity(lhs.count)
        for i in 0..<lhs.count {
            result.append(lhs.buffer.storage[i] * rhs.buffer.storage[i])
        }
        return NativeArray(result)
    }

    /// Sum of all elements.
    func sum() -> T {
        buffer.storage.reduce(0, +)
    }

    /// Minimum element.
    func min() -> T? {
        buffer.storage.min()
    }

    /// Maximum element.
    func max() -> T? {
        buffer.storage.max()
    }

    /// Argsort: return indices that would sort the array.
    func argsort(ascending: Bool = true) -> [Int] {
        var indices = Array(0..<count)
        let storage = buffer.storage
        if ascending {
            indices.sort { storage[$0] < storage[$1] }
        } else {
            indices.sort { storage[$0] > storage[$1] }
        }
        return indices
    }
}

// MARK: - Floating-point operations

public extension NativeArray where T: FloatingPoint {
    /// Arithmetic mean.
    func mean() -> T {
        guard count > 0 else { return .nan }
        return sum() / T(count)
    }

    /// Variance with specified degrees of freedom correction.
    func variance(ddof: Int = 1) -> T {
        guard count > ddof else { return .nan }
        let m = mean()
        var sumSq: T = 0
        for v in buffer.storage {
            let diff = v - m
            sumSq += diff * diff
        }
        return sumSq / T(count - ddof)
    }

    /// Standard deviation.
    func std(ddof: Int = 1) -> T {
        variance(ddof: ddof).squareRoot()
    }

    /// Element-wise division.
    static func / (lhs: NativeArray<T>, rhs: NativeArray<T>) -> NativeArray<T> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        var result = ContiguousArray<T>()
        result.reserveCapacity(lhs.count)
        for i in 0..<lhs.count {
            result.append(lhs.buffer.storage[i] / rhs.buffer.storage[i])
        }
        return NativeArray(result)
    }

    /// Scalar division.
    static func / (lhs: NativeArray<T>, rhs: T) -> NativeArray<T> {
        var result = ContiguousArray<T>()
        result.reserveCapacity(lhs.count)
        for v in lhs.buffer.storage {
            result.append(v / rhs)
        }
        return NativeArray(result)
    }
}

// MARK: - Accelerate-optimized Double operations

public extension NativeArray where T == Double {
    /// Accelerate-optimized element-wise addition.
    static func + (lhs: NativeArray<Double>, rhs: NativeArray<Double>) -> NativeArray<Double> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        let n = lhs.count
        let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
            lhs.withUnsafeBufferPointer { lBuf in
                rhs.withUnsafeBufferPointer { rBuf in
                    VectorOps.add(lBuf, rBuf, result: buf)
                }
            }
            count = n
        }
        return NativeArray(result)
    }

    /// Accelerate-optimized element-wise subtraction.
    static func - (lhs: NativeArray<Double>, rhs: NativeArray<Double>) -> NativeArray<Double> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        let n = lhs.count
        let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
            lhs.withUnsafeBufferPointer { lBuf in
                rhs.withUnsafeBufferPointer { rBuf in
                    VectorOps.subtract(lBuf, rBuf, result: buf)
                }
            }
            count = n
        }
        return NativeArray(result)
    }

    /// Accelerate-optimized element-wise multiplication.
    static func * (lhs: NativeArray<Double>, rhs: NativeArray<Double>) -> NativeArray<Double> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        let n = lhs.count
        let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
            lhs.withUnsafeBufferPointer { lBuf in
                rhs.withUnsafeBufferPointer { rBuf in
                    VectorOps.multiply(lBuf, rBuf, result: buf)
                }
            }
            count = n
        }
        return NativeArray(result)
    }

    /// Accelerate-optimized element-wise division.
    static func / (lhs: NativeArray<Double>, rhs: NativeArray<Double>) -> NativeArray<Double> {
        precondition(lhs.count == rhs.count, "Arrays must have same length")
        let n = lhs.count
        let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
            lhs.withUnsafeBufferPointer { lBuf in
                rhs.withUnsafeBufferPointer { rBuf in
                    VectorOps.divide(lBuf, rBuf, result: buf)
                }
            }
            count = n
        }
        return NativeArray(result)
    }

    /// Accelerate-optimized scalar division.
    static func / (lhs: NativeArray<Double>, rhs: Double) -> NativeArray<Double> {
        let n = lhs.count
        let result = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
            lhs.withUnsafeBufferPointer { lBuf in
                VectorOps.scalarDivide(lBuf, rhs, result: buf)
            }
            count = n
        }
        return NativeArray(result)
    }

    /// Accelerate-optimized sum.
    func sum() -> Double {
        withUnsafeBufferPointer { VectorOps.sum($0) }
    }

    /// Accelerate-optimized mean.
    func mean() -> Double {
        guard count > 0 else { return .nan }
        return withUnsafeBufferPointer { VectorOps.mean($0) }
    }

    /// Accelerate-optimized min.
    func min() -> Double? {
        guard count > 0 else { return nil }
        return withUnsafeBufferPointer { VectorOps.min($0) }
    }

    /// Accelerate-optimized max.
    func max() -> Double? {
        guard count > 0 else { return nil }
        return withUnsafeBufferPointer { VectorOps.max($0) }
    }

    /// Accelerate-optimized variance.
    func variance(ddof: Int = 1) -> Double {
        guard count > ddof else { return .nan }
        let m = mean()
        let sumSq = withUnsafeBufferPointer { VectorOps.sumOfSquaredDifferences($0, mean: m) }
        return sumSq / Double(count - ddof)
    }

    /// Accelerate-optimized standard deviation.
    func std(ddof: Int = 1) -> Double {
        variance(ddof: ddof).squareRoot()
    }
}

// MARK: - Selection algorithms

public extension NativeArray where T: Comparable {
    /// In-place quickselect (introselect). After calling, element at position k
    /// is what it would be in sorted order. Elements before k are ≤ arr[k],
    /// elements after are ≥ arr[k]. Average O(n).
    mutating func nthElement(_ k: Int) {
        guard count > 1 && k >= 0 && k < count else { return }
        ensureUnique()
        buffer.storage.withUnsafeMutableBufferPointer { buf in
            NativeArray.quickselect(&buf, left: 0, right: buf.count - 1, k: k)
        }
    }

    /// Quickselect on a raw mutable buffer. Public for use without NativeArray wrapper.
    static func rawNthElement(_ buf: inout UnsafeMutableBufferPointer<T>, k: Int) {
        guard buf.count > 1 && k >= 0 && k < buf.count else { return }
        quickselect(&buf, left: 0, right: buf.count - 1, k: k)
    }

    private static func quickselect(
        _ buf: inout UnsafeMutableBufferPointer<T>,
        left: Int, right: Int, k: Int
    ) {
        var lo = left
        var hi = right
        while lo < hi {
            // Median-of-three pivot
            let mid = lo + (hi - lo) / 2
            if buf[mid] < buf[lo] { buf.swapAt(lo, mid) }
            if buf[hi] < buf[lo] { buf.swapAt(lo, hi) }
            if buf[mid] < buf[hi] { buf.swapAt(mid, hi) }
            let pivot = buf[hi]

            // Partition
            var i = lo
            var j = hi - 1
            while true {
                while i <= j && buf[i] < pivot { i += 1 }
                while j >= i && buf[j] > pivot { j -= 1 }
                if i >= j { break }
                buf.swapAt(i, j)
                i += 1
                j -= 1
            }
            buf.swapAt(i, hi)

            if i == k { return }
            if k < i { hi = i - 1 } else { lo = i + 1 }
        }
    }
}

// MARK: - Optimized Double selection

public extension NativeArray where T == Double {
    /// Quickselect optimized for Double using raw pointer access (no bounds checks).
    mutating func nthElement(_ k: Int) {
        guard count > 1 && k >= 0 && k < count else { return }
        ensureUnique()
        buffer.storage.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            NativeArray.quickselectDouble(base, count: buf.count, k: k)
        }
    }

    private static func quickselectDouble(_ base: UnsafeMutablePointer<Double>, count: Int, k: Int) {
        var lo = 0
        var hi = count - 1
        while lo < hi {
            // Median-of-three pivot
            let mid = lo + (hi - lo) / 2
            let pLo = base + lo, pMid = base + mid, pHi = base + hi
            if pMid.pointee < pLo.pointee { swap(&pLo.pointee, &pMid.pointee) }
            if pHi.pointee < pLo.pointee { swap(&pLo.pointee, &pHi.pointee) }
            if pMid.pointee < pHi.pointee { swap(&pMid.pointee, &pHi.pointee) }
            let pivot = pHi.pointee

            // Lomuto-like partition with raw pointers
            var i = lo
            var j = hi - 1
            while true {
                while i <= j && (base + i).pointee < pivot { i += 1 }
                while j >= i && (base + j).pointee > pivot { j -= 1 }
                if i >= j { break }
                swap(&(base + i).pointee, &(base + j).pointee)
                i += 1
                j -= 1
            }
            swap(&(base + i).pointee, &pHi.pointee)

            if i == k { return }
            if k < i { hi = i - 1 } else { lo = i + 1 }
        }
    }
}

// MARK: - Hashable element operations

public extension NativeArray where T: Hashable {
    /// Return unique values preserving order of first occurrence.
    func unique() -> NativeArray<T> {
        var seen = Set<T>()
        var result = ContiguousArray<T>()
        for v in buffer.storage {
            if seen.insert(v).inserted {
                result.append(v)
            }
        }
        return NativeArray(result)
    }

    /// Factorize: encode values as integer codes + uniques array.
    func factorize() -> (codes: [Int], uniques: NativeArray<T>) {
        var mapping = [T: Int]()
        var uniques = ContiguousArray<T>()
        var codes = [Int]()
        codes.reserveCapacity(count)

        for v in buffer.storage {
            if let code = mapping[v] {
                codes.append(code)
            } else {
                let code = uniques.count
                mapping[v] = code
                uniques.append(v)
                codes.append(code)
            }
        }
        return (codes, NativeArray(uniques))
    }
}
