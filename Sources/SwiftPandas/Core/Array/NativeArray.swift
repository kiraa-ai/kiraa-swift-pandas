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
        var result = ContiguousArray<T>()
        result.reserveCapacity(indices.count)
        for i in indices {
            if i >= 0 && i < count {
                result.append(buffer.storage[i])
            } else {
                result.append(0)
            }
        }
        return NativeArray(result)
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
        let indexed = buffer.storage.enumerated().map { ($0.offset, $0.element) }
        let sorted = ascending
            ? indexed.sorted { $0.1 < $1.1 }
            : indexed.sorted { $0.1 > $1.1 }
        return sorted.map { $0.0 }
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
