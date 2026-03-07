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
        if a.mask.allValid {
            // Fast path: no NAs, use Accelerate
            var resultData = ContiguousArray<Double>(repeating: 0, count: a.count)
            a.data.withUnsafeBufferPointer { src in
                resultData.withUnsafeMutableBufferPointer { dst in
                    VectorOps.scalarAdd(src, rhs, result: dst)
                }
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), index: lhs.indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] + rhs
        }
        return Series(data: .double(result), index: lhs.indexLabels, name: lhs.name)
    }

    public static func - (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            var resultData = ContiguousArray<Double>(repeating: 0, count: a.count)
            a.data.withUnsafeBufferPointer { src in
                resultData.withUnsafeMutableBufferPointer { dst in
                    VectorOps.scalarSubtract(src, rhs, result: dst)
                }
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), index: lhs.indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] - rhs
        }
        return Series(data: .double(result), index: lhs.indexLabels, name: lhs.name)
    }

    public static func * (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            var resultData = ContiguousArray<Double>(repeating: 0, count: a.count)
            a.data.withUnsafeBufferPointer { src in
                resultData.withUnsafeMutableBufferPointer { dst in
                    VectorOps.scalarMultiply(src, rhs, result: dst)
                }
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), index: lhs.indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] * rhs
        }
        return Series(data: .double(result), index: lhs.indexLabels, name: lhs.name)
    }

    public static func / (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            var resultData = ContiguousArray<Double>(repeating: 0, count: a.count)
            a.data.withUnsafeBufferPointer { src in
                resultData.withUnsafeMutableBufferPointer { dst in
                    VectorOps.scalarDivide(src, rhs, result: dst)
                }
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), index: lhs.indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] / rhs
        }
        return Series(data: .double(result), index: lhs.indexLabels, name: lhs.name)
    }

    // MARK: - Comparison operators (return Bool masks like pandas)

    /// Element-wise greater than. NA values produce false.
    public static func > (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] > rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] > rhs }
            }
        }
        return result
    }

    /// Element-wise greater than or equal. NA values produce false.
    public static func >= (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] >= rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] >= rhs }
            }
        }
        return result
    }

    /// Element-wise less than. NA values produce false.
    public static func < (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] < rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] < rhs }
            }
        }
        return result
    }

    /// Element-wise less than or equal. NA values produce false.
    public static func <= (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] <= rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] <= rhs }
            }
        }
        return result
    }

    /// Element-wise equality. NA values produce false.
    public func eq(_ value: Double) -> [Bool] {
        guard case .double(let a) = data else { return [Bool](repeating: false, count: count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] == value }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] == value }
            }
        }
        return result
    }

    /// Element-wise inequality. NA values produce false.
    public func ne(_ value: Double) -> [Bool] {
        guard case .double(let a) = data else { return [Bool](repeating: false, count: count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] != value }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] != value }
            }
        }
        return result
    }

    /// Element-wise string equality. NA values produce false.
    public func eq(_ value: String) -> [Bool] {
        guard case .string(let a) = data else { return [Bool](repeating: false, count: count) }
        return a.storage.map { $0 == value }
    }

    /// Element-wise string inequality. NA values produce false.
    public func ne(_ value: String) -> [Bool] {
        guard case .string(let a) = data else { return [Bool](repeating: false, count: count) }
        return a.storage.map { $0 != nil && $0 != value }
    }

    /// String contains check (like pandas .str.contains). NA values produce false.
    public func strContains(_ substring: String) -> [Bool] {
        guard case .string(let a) = data else { return [Bool](repeating: false, count: count) }
        return a.storage.map { $0?.contains(substring) ?? false }
    }

    // MARK: - Apply / Map

    /// Apply a function to each numeric element, returning a new Series.
    public func apply(_ transform: (Double) -> Double) -> Series {
        guard case .double(let a) = data else { return self }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = transform(result.data[i])
        }
        return Series(data: .double(result), index: indexLabels, name: name)
    }

    /// Map values using a dictionary. Unmapped values become NA.
    public func map(_ mapping: [Double: Double]) -> Series {
        guard case .double(let a) = data else { return self }
        var values = [Double?]()
        values.reserveCapacity(a.count)
        for i in 0..<a.count {
            if a.mask[i], let mapped = mapping[a.data[i]] {
                values.append(mapped)
            } else {
                values.append(nil)
            }
        }
        return Series(values, name: name)
    }

    /// Map string values using a dictionary. Unmapped values become NA.
    public func map(_ mapping: [String: String]) -> Series {
        guard case .string(let a) = data else { return self }
        let mapped: [String?] = a.storage.map { s in
            guard let s = s, let v = mapping[s] else { return nil }
            return v
        }
        return Series(mapped, name: name)
    }

    // MARK: - Cumulative operations

    /// Cumulative sum. NA values are skipped (not propagated).
    public func cumsum() -> Series {
        guard case .double(let a) = data else { return self }
        var cumValues = [Double?]()
        cumValues.reserveCapacity(a.count)
        var running = 0.0
        for i in 0..<a.count {
            if a.mask[i] {
                running += a.data[i]
                cumValues.append(running)
            } else {
                cumValues.append(nil)
            }
        }
        return Series(cumValues, name: name)
    }

    // MARK: - Additional aggregations

    /// Median of numeric values. Uses O(n) quickselect instead of O(n log n) sort.
    public func median() -> Double? {
        guard case .double(let a) = data else { return nil }
        // Fast-path: skip dropNA() when no NAs exist
        var arr: NativeArray<Double>
        if a.mask.allValid {
            arr = a.data.copy()
        } else {
            arr = a.dropNA()
        }
        let n = arr.count
        guard n > 0 else { return nil }
        let mid = n / 2
        arr.nthElement(mid)
        if n % 2 == 0 {
            let upper = arr[mid]
            // After nthElement(mid), elements [0..mid-1] are all ≤ arr[mid].
            // Max of left partition gives lower median — avoids second quickselect.
            let lower = arr.withUnsafeBufferPointer { buf in
                VectorOps.max(UnsafeBufferPointer(rebasing: buf[0..<mid]))
            }
            return (lower + upper) / 2.0
        }
        return arr[mid]
    }

    /// Quantile (0.0 to 1.0) using linear interpolation with O(n) selection.
    public func quantile(_ q: Double) -> Double? {
        precondition(q >= 0.0 && q <= 1.0, "Quantile must be between 0 and 1")
        guard case .double(let a) = data else { return nil }
        var arr: NativeArray<Double>
        if a.mask.allValid {
            arr = a.data.copy()
        } else {
            arr = a.dropNA()
        }
        guard arr.count > 0 else { return nil }
        if arr.count == 1 { return arr[0] }
        let pos = q * Double(arr.count - 1)
        let lower = Int(pos)
        let upper = Swift.min(lower + 1, arr.count - 1)
        let frac = pos - Double(lower)
        if lower == upper {
            arr.nthElement(lower)
            return arr[lower]
        }
        arr.nthElement(upper)
        let upperVal = arr[upper]
        // After nthElement(upper), elements [0..upper-1] are ≤ arr[upper].
        // Max of left partition gives arr[lower] without second quickselect.
        let lowerVal = arr.withUnsafeBufferPointer { buf in
            VectorOps.max(UnsafeBufferPointer(rebasing: buf[0..<upper]))
        }
        return lowerVal + frac * (upperVal - lowerVal)
    }

    // MARK: - Unique / duplicated

    /// Return unique values as a new Series.
    public func unique() -> Series {
        switch data {
        case .double(let a):
            let u = a.unique()
            return Series(data: .double(u), name: name)
        case .string(let a):
            let u = a.unique()
            return Series(data: .string(u), name: name)
        default:
            return self
        }
    }

    /// Number of unique non-NA values.
    public var nUnique: Int {
        switch data {
        case .double(let a): return a.unique().validCount
        case .string(let a): return a.unique().validCount
        default: return 0
        }
    }

    /// Boolean mask: true where the value is a duplicate (has appeared before).
    public func duplicated() -> [Bool] {
        switch data {
        case .double(let a):
            var seen = Set<Double>()
            return (0..<a.count).map { i in
                guard a.mask[i] else { return false }
                return !seen.insert(a.data[i]).inserted
            }
        case .string(let a):
            var seen = Set<String>()
            return a.storage.map { s in
                guard let s = s else { return false }
                return !seen.insert(s).inserted
            }
        default:
            return [Bool](repeating: false, count: count)
        }
    }

    /// Drop duplicate values, keeping first occurrence.
    public func dropDuplicates() -> Series {
        let dupes = duplicated()
        let keepIndices = dupes.enumerated().compactMap { !$1 ? $0 : nil }
        return Series(
            data: data.take(indices: keepIndices),
            index: keepIndices.map { indexLabels[$0] },
            name: name
        )
    }

    // MARK: - Description

    public var description: String {
        var lines = [String]()
        let maxDisplay = Swift.min(count, 20)
        let maxLabelWidth = Swift.max(indexLabels.prefix(maxDisplay).map { $0.count }.max() ?? 0, 1)

        // Calculate value width for right-aligning numeric values
        let maxValueWidth = (0..<maxDisplay).map { data.formattedValue(at: $0).count }.max() ?? 0

        for i in 0..<maxDisplay {
            let label = indexLabels[i].padding(toLength: maxLabelWidth, withPad: " ", startingAt: 0)
            let value = data.formattedValue(at: i)
            let aligned = isNumeric
                ? String(repeating: " ", count: Swift.max(0, maxValueWidth - value.count)) + value
                : value
            lines.append("\(label)  \(aligned)")
        }

        if count > maxDisplay {
            lines.append("... (\(count) rows)")
        }

        var meta = "dtype: \(dtype)"
        if let name = name {
            meta = "Name: \(name), " + meta
        }
        meta += ", length: \(count)"
        lines.append(meta)

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
            ("25%", quantile(0.25) ?? .nan),
            ("50%", median() ?? .nan),
            ("75%", quantile(0.75) ?? .nan),
            ("max", doubles.max() ?? .nan),
        ]
        return Series(
            data: .fromDoubles(stats.map { $0.1 }),
            index: stats.map { $0.0 },
            name: name
        )
    }
}
