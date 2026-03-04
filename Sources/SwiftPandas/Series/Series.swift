/// 1D labeled array — the Swift equivalent of pandas.Series.
///
/// A Series holds a single Column of data plus an index for label-based access.
/// All numeric data defaults to Double. Uses value semantics with copy-on-write.
public struct Series: CustomStringConvertible, Sendable {
    /// The name of this Series (optional, like pandas).
    public var name: String?

    /// The underlying data column.
    public var data: Column

    /// Integer positions of labels. We store labels as strings for flexibility.
    internal var indexLabels: [String]

    // MARK: - Initializers

    /// Create from an array of Doubles with default integer index.
    public init(_ values: [Double], name: String? = nil) {
        self.data = .fromDoubles(values)
        self.name = name
        self.indexLabels = (0..<values.count).map { "\($0)" }
    }

    /// Create from an array of optional Doubles.
    public init(_ values: [Double?], name: String? = nil) {
        self.data = .fromOptionalDoubles(values)
        self.name = name
        self.indexLabels = (0..<values.count).map { "\($0)" }
    }

    /// Create from an array of Strings.
    public init(_ values: [String], name: String? = nil) {
        self.data = .fromStrings(values)
        self.name = name
        self.indexLabels = (0..<values.count).map { "\($0)" }
    }

    /// Create from an array of optional Strings.
    public init(_ values: [String?], name: String? = nil) {
        self.data = .fromOptionalStrings(values)
        self.name = name
        self.indexLabels = (0..<values.count).map { "\($0)" }
    }

    /// Create from an array of Ints (converted to Double).
    public init(_ values: [Int], name: String? = nil) {
        self.data = .fromDoubles(values.map { Double($0) })
        self.name = name
        self.indexLabels = (0..<values.count).map { "\($0)" }
    }

    /// Create from a Column with explicit index labels.
    public init(data: Column, index: [String], name: String? = nil) {
        precondition(data.count == index.count, "Data and index must have same length")
        self.data = data
        self.indexLabels = index
        self.name = name
    }

    /// Create from a Column with default integer index.
    public init(data: Column, name: String? = nil) {
        self.data = data
        self.name = name
        self.indexLabels = (0..<data.count).map { "\($0)" }
    }

    /// Create from a dictionary.
    public init(_ dict: [String: Double], name: String? = nil) {
        let sorted = dict.sorted { $0.key < $1.key }
        self.indexLabels = sorted.map { $0.key }
        self.data = .fromDoubles(sorted.map { $0.value })
        self.name = name
    }

    // MARK: - Properties

    /// Number of elements.
    public var count: Int { data.count }

    /// The dtype of the underlying data.
    public var dtype: DTypeEnum { data.dtype }

    /// Whether this series holds numeric data.
    public var isNumeric: Bool { data.isNumeric }

    /// Number of valid (non-NA) values.
    public var validCount: Int { data.validCount }

    /// Number of NA values.
    public var naCount: Int { data.naCount }

    /// The index labels.
    public var index: [String] { indexLabels }

    /// The values as an array of Double (nil if not numeric).
    public var doubleValues: [Double?]? {
        guard let arr = data.asDouble() else { return nil }
        return (0..<arr.count).map { arr[$0] }
    }

    // MARK: - Access by position

    /// Access value at integer position.
    public subscript(position: Int) -> Any? {
        data.value(at: position)
    }

    /// Integer-location based indexing (like .iloc).
    public func iloc(_ position: Int) -> Any? {
        precondition(position >= 0 && position < count, "Position \(position) out of range")
        return data.value(at: position)
    }

    /// Integer-location based slicing.
    public func iloc(_ range: Range<Int>) -> Series {
        let indices = Array(range)
        return Series(
            data: data.take(indices: indices),
            index: indices.map { indexLabels[$0] },
            name: name
        )
    }

    // MARK: - Access by label

    /// Label-based indexing (like .loc).
    public func loc(_ label: String) -> Any? {
        guard let pos = indexLabels.firstIndex(of: label) else { return nil }
        return data.value(at: pos)
    }

    // MARK: - Head / Tail

    public func head(_ n: Int = 5) -> Series {
        let end = Swift.min(n, count)
        return iloc(0..<end)
    }

    public func tail(_ n: Int = 5) -> Series {
        let start = Swift.max(0, count - n)
        return iloc(start..<count)
    }

    // MARK: - NA handling

    /// Boolean mask: true where value is NA.
    public func isNA() -> [Bool] { data.isNA() }

    /// Drop NA values.
    public func dropNA() -> Series {
        let mask = data.isNA()
        let validIndices = mask.enumerated().compactMap { !$1 ? $0 : nil }
        return Series(
            data: data.take(indices: validIndices),
            index: validIndices.map { indexLabels[$0] },
            name: name
        )
    }

    /// Fill NA values with a constant Double.
    public func fillNA(_ value: Double) -> Series {
        guard case .double(let arr) = data else { return self }
        return Series(
            data: .double(arr.fillNANullable(value: value)),
            index: indexLabels,
            name: name
        )
    }

    // MARK: - Aggregations

    /// Sum of numeric values.
    public func sum() -> Double? { data.sum() }

    /// Mean of numeric values.
    public func mean() -> Double? { data.mean() }

    /// Standard deviation.
    public func std(ddof: Int = 1) -> Double? { data.std(ddof: ddof) }

    /// Minimum value.
    public func min() -> Double? { data.min() }

    /// Maximum value.
    public func max() -> Double? { data.max() }

    // MARK: - Sorting

    /// Sort by values.
    public func sortValues(ascending: Bool = true) -> Series {
        let indices: [Int]
        switch data {
        case .double(let a):
            let dropNAData = a.dropNA()
            let sortedIndices = dropNAData.argsort(ascending: ascending)
            // Map back to original indices accounting for NAs
            var validPositions = [Int]()
            var naPositions = [Int]()
            for i in 0..<a.count {
                if a.mask[i] {
                    validPositions.append(i)
                } else {
                    naPositions.append(i)
                }
            }
            indices = sortedIndices.map { validPositions[$0] } + naPositions
        case .string(let a):
            indices = a.argsort(ascending: ascending)
        default:
            return self
        }
        return Series(
            data: data.take(indices: indices),
            index: indices.map { indexLabels[$0] },
            name: name
        )
    }

    // MARK: - Value counts

    /// Count occurrences of each unique value.
    public func valueCounts() -> Series {
        switch data {
        case .double(let a):
            var counts = [Double: Int]()
            for i in 0..<a.count where a.mask[i] {
                counts[a.data[i], default: 0] += 1
            }
            let sorted = counts.sorted { $0.value > $1.value }
            return Series(
                data: .fromDoubles(sorted.map { Double($0.value) }),
                index: sorted.map { "\($0.key)" },
                name: name
            )
        case .string(let a):
            var counts = [String: Int]()
            for s in a.storage {
                if let s = s {
                    counts[s, default: 0] += 1
                }
            }
            let sorted = counts.sorted { $0.value > $1.value }
            return Series(
                data: .fromDoubles(sorted.map { Double($0.value) }),
                index: sorted.map { $0.key },
                name: name
            )
        default:
            return self
        }
    }

    // MARK: - Arithmetic (Double series only)

    public static func + (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la + ra), index: lhs.indexLabels, name: lhs.name)
    }

    public static func - (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la - ra), index: lhs.indexLabels, name: lhs.name)
    }

    public static func * (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la * ra), index: lhs.indexLabels, name: lhs.name)
    }

    public static func / (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la / ra), index: lhs.indexLabels, name: lhs.name)
    }

    // MARK: - Scalar arithmetic

    public static func + (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] + rhs
        }
        return Series(data: .double(result), index: lhs.indexLabels, name: lhs.name)
    }

    public static func * (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] * rhs
        }
        return Series(data: .double(result), index: lhs.indexLabels, name: lhs.name)
    }

    // MARK: - Description

    public var description: String {
        var lines = [String]()
        let maxDisplay = Swift.min(count, 20)
        let maxLabelWidth = indexLabels.prefix(maxDisplay).map { $0.count }.max() ?? 0

        for i in 0..<maxDisplay {
            let label = indexLabels[i].padding(toLength: maxLabelWidth, withPad: " ", startingAt: 0)
            let value = data.formattedValue(at: i)
            lines.append("\(label)    \(value)")
        }

        if count > maxDisplay {
            lines.append("... (\(count) rows)")
        }

        if let name = name {
            lines.append("Name: \(name), dtype: \(dtype)")
        } else {
            lines.append("dtype: \(dtype)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Describe

    /// Generate descriptive statistics (like pandas .describe()).
    public func describe() -> Series {
        guard let doubles = data.asDouble() else {
            return Series(
                data: .fromDoubles([Double(count), Double(validCount)]),
                index: ["count", "non-null"],
                name: name
            )
        }
        let stats: [(String, Double)] = [
            ("count", Double(doubles.validCount)),
            ("mean", doubles.mean() ?? .nan),
            ("std", doubles.std(ddof: 1) ?? .nan),
            ("min", doubles.min() ?? .nan),
            ("max", doubles.max() ?? .nan),
        ]
        return Series(
            data: .fromDoubles(stats.map { $0.1 }),
            index: stats.map { $0.0 },
            name: name
        )
    }
}
