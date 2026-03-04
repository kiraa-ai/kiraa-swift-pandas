/// Protocol for axis labels in Series and DataFrame.
///
/// An index provides O(1) label-to-position lookup and supports
/// set operations (union, intersection, difference).
public protocol PandasIndex: CustomStringConvertible, Sendable {
    associatedtype Label: Hashable & Sendable

    /// The labels as an array.
    var values: [Label] { get }

    /// Number of labels.
    var count: Int { get }

    /// Look up the integer position of a label. Returns nil if not found.
    func getLocation(of label: Label) -> Int?

    /// Whether the index contains a label.
    func contains(_ label: Label) -> Bool

    /// Whether all labels are unique.
    var isUnique: Bool { get }
}

// MARK: - RangeIndex

/// Memory-efficient index for a range of integers.
/// Only stores start, stop, step — no array allocation for the labels.
public struct RangeIndex: PandasIndex, Sendable {
    public typealias Label = Int

    public let start: Int
    public let stop: Int
    public let step: Int

    public init(start: Int = 0, stop: Int, step: Int = 1) {
        precondition(step != 0, "Step cannot be zero")
        self.start = start
        self.stop = stop
        self.step = step
    }

    /// Create a RangeIndex from 0..<count.
    public init(_ count: Int) {
        self.start = 0
        self.stop = count
        self.step = 1
    }

    public var count: Int {
        guard step > 0 ? start < stop : start > stop else { return 0 }
        return (stop - start + step - (step > 0 ? 1 : -1)) / step
    }

    public var values: [Int] {
        stride(from: start, to: stop, by: step).map { $0 }
    }

    public func getLocation(of label: Int) -> Int? {
        guard (label - start) % step == 0 else { return nil }
        let pos = (label - start) / step
        guard pos >= 0 && pos < count else { return nil }
        return pos
    }

    public func contains(_ label: Int) -> Bool {
        getLocation(of: label) != nil
    }

    public var isUnique: Bool { true } // Always unique for a range

    /// Get the label at position i.
    public subscript(position: Int) -> Int {
        precondition(position >= 0 && position < count, "Position \(position) out of range")
        return start + position * step
    }

    public var description: String {
        "RangeIndex(start=\(start), stop=\(stop), step=\(step))"
    }
}

// MARK: - StringIndex

/// Index with string labels and hash-based O(1) lookup.
public struct StringIndex: PandasIndex, Sendable {
    public typealias Label = String

    public let values: [String]
    private let lookup: [String: Int]

    public init(_ labels: [String]) {
        self.values = labels
        var lookup = [String: Int](minimumCapacity: labels.count)
        for (i, label) in labels.enumerated() {
            if lookup[label] == nil {
                lookup[label] = i
            }
        }
        self.lookup = lookup
    }

    public var count: Int { values.count }

    public func getLocation(of label: String) -> Int? {
        lookup[label]
    }

    public func contains(_ label: String) -> Bool {
        lookup[label] != nil
    }

    public var isUnique: Bool {
        lookup.count == values.count
    }

    public var description: String {
        let labels = values.prefix(5).map { "'\($0)'" }.joined(separator: ", ")
        if count > 5 {
            return "Index([\(labels), ...], length=\(count))"
        }
        return "Index([\(labels)])"
    }
}

// MARK: - Int64Index

/// Index with Int64 labels and hash-based O(1) lookup.
public struct Int64Index: PandasIndex, Sendable {
    public typealias Label = Int64

    public let values: [Int64]
    private let lookup: [Int64: Int]

    public init(_ labels: [Int64]) {
        self.values = labels
        var lookup = [Int64: Int](minimumCapacity: labels.count)
        for (i, label) in labels.enumerated() {
            if lookup[label] == nil {
                lookup[label] = i
            }
        }
        self.lookup = lookup
    }

    /// Convenience initializer from [Int].
    public init(ints labels: [Int]) {
        self.init(labels.map { Int64($0) })
    }

    public var count: Int { values.count }

    public func getLocation(of label: Int64) -> Int? {
        lookup[label]
    }

    public func contains(_ label: Int64) -> Bool {
        lookup[label] != nil
    }

    public var isUnique: Bool {
        lookup.count == values.count
    }

    public var description: String {
        let labels = values.prefix(5).map { "\($0)" }.joined(separator: ", ")
        if count > 5 {
            return "Int64Index([\(labels), ...], length=\(count))"
        }
        return "Int64Index([\(labels)])"
    }
}
