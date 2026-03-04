/// Type-erased column storage for DataFrame.
///
/// Since a DataFrame holds heterogeneous columns, we need runtime type erasure.
/// Per design, numeric columns default to Double for simplicity and consistency.
/// String columns use StringArray. Boolean columns use NullableArray<Bool>.
public enum Column: CustomStringConvertible, Sendable {
    /// Numeric column stored as nullable Double array (the default for all numeric data).
    case double(NullableArray<Double>)

    /// String column.
    case string(StringArray)

    /// Boolean column.
    case bool(NullableArray<Bool>)

    /// Integer column stored as nullable Int64 (for when integer precision matters).
    case int64(NullableArray<Int64>)

    // MARK: - Properties

    /// Number of elements.
    public var count: Int {
        switch self {
        case .double(let a): return a.count
        case .string(let a): return a.count
        case .bool(let a): return a.count
        case .int64(let a): return a.count
        }
    }

    /// The runtime dtype.
    public var dtype: DTypeEnum {
        switch self {
        case .double: return .float64
        case .string: return .string
        case .bool: return .bool
        case .int64: return .int64
        }
    }

    /// Whether this is a numeric column.
    public var isNumeric: Bool {
        dtype.isNumeric
    }

    /// Number of valid (non-NA) values.
    public var validCount: Int {
        switch self {
        case .double(let a): return a.validCount
        case .string(let a): return a.validCount
        case .bool(let a): return a.validCount
        case .int64(let a): return a.validCount
        }
    }

    /// Number of NA values.
    public var naCount: Int {
        count - validCount
    }

    /// Boolean mask: true where value is NA.
    public func isNA() -> [Bool] {
        switch self {
        case .double(let a): return a.isNA()
        case .string(let a): return a.isNA()
        case .bool(let a): return a.isNA()
        case .int64(let a): return a.isNA()
        }
    }

    /// Total memory usage in bytes.
    public var nbytes: Int {
        switch self {
        case .double(let a): return a.nbytes
        case .string(let a): return a.nbytes
        case .bool(let a): return a.nbytes
        case .int64(let a): return a.nbytes
        }
    }

    // MARK: - Value access

    /// Get value at index as a formatted string for display.
    public func formattedValue(at index: Int) -> String {
        switch self {
        case .double(let a):
            guard let v = a[index] else { return "NA" }
            return v.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.1f", v) : "\(v)"
        case .string(let a):
            return a[index] ?? "NA"
        case .bool(let a):
            guard let v = a[index] else { return "NA" }
            return v ? "True" : "False"
        case .int64(let a):
            guard let v = a[index] else { return "NA" }
            return "\(v)"
        }
    }

    /// Get value at index as Any? for generic access.
    public func value(at index: Int) -> Any? {
        switch self {
        case .double(let a): return a[index]
        case .string(let a): return a[index]
        case .bool(let a): return a[index]
        case .int64(let a): return a[index]
        }
    }

    // MARK: - Conversions

    /// Try to get as a Double NullableArray. Int64 columns are promoted.
    public func asDouble() -> NullableArray<Double>? {
        switch self {
        case .double(let a): return a
        case .int64(let a):
            let doubleData = NativeArray<Double>(a.data.array.map { Double($0) })
            return NullableArray(data: doubleData, mask: a.mask)
        default: return nil
        }
    }

    // MARK: - Construction helpers

    /// Create a Double column from an array of Double values (no NAs).
    public static func fromDoubles(_ values: [Double]) -> Column {
        .double(NullableArray(NativeArray(values)))
    }

    /// Create a Double column from an array of optional Doubles.
    public static func fromOptionalDoubles(_ values: [Double?]) -> Column {
        .double(NullableArray(values))
    }

    /// Create a String column.
    public static func fromStrings(_ values: [String]) -> Column {
        .string(StringArray(values))
    }

    /// Create a String column with NAs.
    public static func fromOptionalStrings(_ values: [String?]) -> Column {
        .string(StringArray(values))
    }

    /// Create an Int64 column.
    public static func fromInts(_ values: [Int]) -> Column {
        .int64(NullableArray(NativeArray(values.map { Int64($0) })))
    }

    /// Create a Bool column.
    public static func fromBools(_ values: [Bool]) -> Column {
        let nullable = NullableArray(data: NativeArray(values), mask: BitVector(repeating: true, count: values.count))
        return .bool(nullable)
    }

    // MARK: - Take

    /// Take elements at specified indices.
    public func take(indices: [Int]) -> Column {
        switch self {
        case .double(let a): return .double(a.take(indices: indices))
        case .string(let a): return .string(a.take(indices: indices))
        case .bool(let a):
            // Bool doesn't conform to ExpressibleByIntegerLiteral, handle manually
            var values = ContiguousArray<Bool>()
            var bools = [Bool]()
            values.reserveCapacity(indices.count)
            bools.reserveCapacity(indices.count)
            for i in indices {
                if i >= 0 && i < a.count && a.mask[i] {
                    values.append(a.data[i])
                    bools.append(true)
                } else {
                    values.append(false)
                    bools.append(false)
                }
            }
            return .bool(NullableArray(data: NativeArray(values), mask: BitVector(bools)))
        case .int64(let a): return .int64(a.take(indices: indices))
        }
    }

    // MARK: - Copy

    public func copy() -> Column {
        switch self {
        case .double(let a): return .double(a.copy())
        case .string(let a): return .string(a.copy())
        case .bool(let a): return .bool(a.copy())
        case .int64(let a): return .int64(a.copy())
        }
    }

    // MARK: - Aggregations

    /// Sum (for numeric columns only, returns nil for non-numeric).
    public func sum() -> Double? {
        asDouble()?.sum()
    }

    /// Mean (for numeric columns only).
    public func mean() -> Double? {
        asDouble()?.mean()
    }

    /// Std (for numeric columns only).
    public func std(ddof: Int = 1) -> Double? {
        asDouble()?.std(ddof: ddof)
    }

    /// Min (for numeric columns only).
    public func min() -> Double? {
        asDouble()?.min()
    }

    /// Max (for numeric columns only).
    public func max() -> Double? {
        asDouble()?.max()
    }

    // MARK: - Description

    public var description: String {
        switch self {
        case .double(let a): return a.description
        case .string(let a): return a.description
        case .bool(let a): return a.description
        case .int64(let a): return a.description
        }
    }
}

