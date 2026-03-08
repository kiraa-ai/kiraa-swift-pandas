// ===----------------------------------------------------------------------===//
//
// Column.swift
// SwiftPandas
//
// This file defines ``Column``, the type-erased wrapper that ``DataFrame`` uses
// to store heterogeneous columns in a single homogeneous dictionary. Because a
// DataFrame can contain Double, Int64, String, and Bool columns side by side,
// we need a sum type (enum) that can hold any of them while still exposing a
// uniform API for count, dtype, take, aggregation, and display.
//
// ## Design choice: defaulting all numerics to Double
//
// Following pandas convention, SwiftPandas normalizes most numeric input to
// ``Double`` (float64). This simplifies arithmetic, aggregation, and join logic
// because there is only one "default" numeric representation to handle. When
// integer precision is specifically required (e.g., ID columns that must not
// lose precision through floating-point rounding), callers can use the
// ``.int64`` case explicitly. The ``asDouble()`` promotion method handles
// transparent Int64 -> Double widening when aggregation functions need it.
//
// ## Sendable conformance
//
// ``Column`` is ``Sendable`` because every case wraps a ``Sendable``-conforming
// type (``NullableArray`` and ``StringArray`` are conditionally or
// unconditionally Sendable). This allows columns to be safely shared across
// concurrency domains (e.g., parallel GroupBy aggregation).
//
// ===----------------------------------------------------------------------===//

/// Type-erased column storage for ``DataFrame``.
///
/// A ``Column`` wraps one of several concrete array types behind an enum so
/// that a ``DataFrame`` can hold columns of different element types in a single
/// `[String: Column]` dictionary. Each case corresponds to a supported dtype:
///
/// | Case      | Underlying storage          | DType tag   |
/// |-----------|-----------------------------|-------------|
/// | `.double` | `NullableArray<Double>`     | `.float64`  |
/// | `.string` | `StringArray`               | `.string`   |
/// | `.bool`   | `NullableArray<Bool>`       | `.bool`     |
/// | `.int64`  | `NullableArray<Int64>`      | `.int64`    |
///
/// All property and method dispatches (count, dtype, take, sum, etc.) switch
/// over the four cases and forward to the concrete array. This approach trades
/// a small per-call overhead (enum switch) for the ability to store fully typed,
/// contiguous arrays under a uniform interface.
public enum Column: CustomStringConvertible, Sendable {
    /// A numeric column stored as a nullable Double array.
    ///
    /// This is the **default representation for all numeric data** in
    /// SwiftPandas, mirroring pandas' behavior of representing numeric columns
    /// as float64. Using Double universally avoids the combinatorial explosion
    /// of mixed-type arithmetic (Int + Float, Int32 + Int64, etc.) and ensures
    /// that NA handling is consistent (NaN is a natural sentinel in IEEE 754
    /// floats, though SwiftPandas uses a separate bitmap instead).
    case double(NullableArray<Double>)

    /// A string column backed by ``StringArray``.
    ///
    /// String data uses ``StringArray`` (which wraps `[String?]`) rather than
    /// ``NullableArray`` because strings are variable-length and cannot be
    /// stored in a fixed-stride contiguous buffer. NA is represented via
    /// Swift's native `Optional<String>.none`.
    case string(StringArray)

    /// A Boolean column stored as a nullable Bool array.
    ///
    /// Boolean columns use ``NullableArray<Bool>`` with a separate validity
    /// bitmap. This means the underlying ``NativeArray<Bool>`` stores raw Bool
    /// values contiguously (1 byte each), while a ``BitVector`` tracks which
    /// positions are NA. Note that Bool does *not* conform to
    /// ``ExpressibleByIntegerLiteral``, so several take/fill operations require
    /// special-case handling (see ``take(indices:)`` below).
    case bool(NullableArray<Bool>)

    /// An integer column stored as a nullable Int64 array.
    ///
    /// This case exists for columns where integer precision is critical (e.g.,
    /// primary key / foreign key columns, row counts, or categorical codes).
    /// Most numeric columns should prefer ``.double`` unless there is a specific
    /// reason to preserve exact integer semantics. The ``asDouble()`` method
    /// can promote Int64 columns to Double when floating-point aggregation is
    /// needed.
    case int64(NullableArray<Int64>)

    // MARK: - Properties

    /// The number of elements in this column (including NAs).
    public var count: Int {
        switch self {
        case .double(let a): return a.count
        case .string(let a): return a.count
        case .bool(let a): return a.count
        case .int64(let a): return a.count
        }
    }

    /// The runtime dtype tag for this column.
    ///
    /// Returns a ``DTypeEnum`` value that can be used for runtime type checks
    /// without pattern-matching on the enum directly. Useful in generic code
    /// that needs to branch on dtype (e.g., CSV writing, display formatting).
    public var dtype: DTypeEnum {
        switch self {
        case .double: return .float64
        case .string: return .string
        case .bool: return .bool
        case .int64: return .int64
        }
    }

    /// Whether this column holds numeric data (Double or Int64).
    ///
    /// Delegates to ``DTypeEnum.isNumeric``. String and Bool columns return
    /// `false`. This property is used by ``DataFrame.describe()`` and other
    /// methods that should only operate on numeric columns.
    public var isNumeric: Bool {
        dtype.isNumeric
    }

    /// The number of valid (non-NA) values in this column.
    ///
    /// Dispatches to the underlying array's ``validCount`` property, which is
    /// typically O(1) for bitmap-backed arrays (``NullableArray``) and O(n) for
    /// ``StringArray``.
    public var validCount: Int {
        switch self {
        case .double(let a): return a.validCount
        case .string(let a): return a.validCount
        case .bool(let a): return a.validCount
        case .int64(let a): return a.validCount
        }
    }

    /// The number of NA (missing) values in this column.
    ///
    /// Computed as ``count`` minus ``validCount`` for efficiency rather than
    /// iterating the NA mask.
    public var naCount: Int {
        count - validCount
    }

    /// Produce a Boolean mask indicating which positions are missing (NA).
    ///
    /// - Returns: An array of length ``count`` where `true` at position *i*
    ///   means the value at *i* is NA / missing.
    public func isNA() -> [Bool] {
        switch self {
        case .double(let a): return a.isNA()
        case .string(let a): return a.isNA()
        case .bool(let a): return a.isNA()
        case .int64(let a): return a.isNA()
        }
    }

    /// Total memory usage in bytes for the underlying array storage.
    ///
    /// Includes both the data buffer and any auxiliary structures (e.g.,
    /// validity bitmap words). Does not include the overhead of the ``Column``
    /// enum wrapper itself.
    public var nbytes: Int {
        switch self {
        case .double(let a): return a.nbytes
        case .string(let a): return a.nbytes
        case .bool(let a): return a.nbytes
        case .int64(let a): return a.nbytes
        }
    }

    // MARK: - Value access

    /// Format the value at the given index as a human-readable string.
    ///
    /// - Parameter index: A zero-based position in the column.
    /// - Returns: A display-friendly string representation. NA values return
    ///   the literal string `"NA"`. Doubles are formatted with up to 4 decimal
    ///   places (trailing zeros stripped); whole-number Doubles are displayed
    ///   without a decimal point. Booleans use Python-style `"True"` / `"False"`.
    ///
    /// This method is used by ``DataFrame``'s `description` and print routines.
    public func formattedValue(at index: Int) -> String {
        switch self {
        case .double(let a):
            guard let v = a[index] else { return "NA" }
            if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
                return String(format: "%.0f", v)
            }
            // Cap at 4 decimal places for readability
            let formatted = String(format: "%.4f", v)
            // Strip trailing zeros after decimal point
            if formatted.contains(".") {
                var trimmed = formatted
                while trimmed.hasSuffix("0") { trimmed.removeLast() }
                if trimmed.hasSuffix(".") { trimmed.removeLast() }
                return trimmed
            }
            return formatted
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

    /// Retrieve the value at the given index as a type-erased `Any?`.
    ///
    /// - Parameter index: A zero-based position in the column.
    /// - Returns: The unwrapped value (Double, String, Bool, or Int64), or
    ///   `nil` if the position is NA.
    ///
    /// This is the escape hatch for code that needs to inspect column values
    /// without knowing the dtype at compile time. Prefer typed access through
    /// ``asDouble()`` or pattern matching on the enum when possible.
    public func value(at index: Int) -> Any? {
        switch self {
        case .double(let a): return a[index]
        case .string(let a): return a[index]
        case .bool(let a): return a[index]
        case .int64(let a): return a[index]
        }
    }

    // MARK: - Conversions

    /// Attempt to obtain this column's data as a `NullableArray<Double>`.
    ///
    /// - For ``.double`` columns, returns the underlying array directly (zero-
    ///   copy).
    /// - For ``.int64`` columns, returns a newly allocated array where each
    ///   Int64 value has been widened to Double. The validity mask is shared.
    /// - For ``.string`` and ``.bool`` columns, returns `nil` because there is
    ///   no meaningful numeric promotion.
    ///
    /// This method is the gateway for all numeric aggregations on ``Column``:
    /// ``sum()``, ``mean()``, ``std(ddof:)``, ``min()``, and ``max()`` all call
    /// ``asDouble()`` first and then delegate to ``NullableArray<Double>``'s
    /// Accelerate-optimized implementations.
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

    /// Create a ``.double`` column from a dense (non-nullable) array of Doubles.
    ///
    /// - Parameter values: An array of Double values. All positions will be
    ///   marked as valid (no NAs).
    /// - Returns: A ``Column`` wrapping a ``NullableArray<Double>`` with an
    ///   all-ones validity mask.
    ///
    /// This is the most common factory for programmatic column construction.
    public static func fromDoubles(_ values: [Double]) -> Column {
        .double(NullableArray(NativeArray(values)))
    }

    /// Create a ``.double`` column from an array of optional Doubles.
    ///
    /// - Parameter values: An array of `Double?`. Positions with `nil` will be
    ///   marked as NA in the resulting validity bitmap.
    /// - Returns: A ``Column`` wrapping a ``NullableArray<Double>``.
    public static func fromOptionalDoubles(_ values: [Double?]) -> Column {
        .double(NullableArray(values))
    }

    /// Create a ``.string`` column from a dense (non-nullable) array of Strings.
    ///
    /// - Parameter values: An array of String values. The resulting
    ///   ``StringArray`` will contain no NA positions.
    /// - Returns: A ``Column`` wrapping a ``StringArray``.
    public static func fromStrings(_ values: [String]) -> Column {
        .string(StringArray(values))
    }

    /// Create a ``.string`` column from an array of optional Strings.
    ///
    /// - Parameter values: An array of `String?`. `nil` entries become NA.
    /// - Returns: A ``Column`` wrapping a ``StringArray``.
    public static func fromOptionalStrings(_ values: [String?]) -> Column {
        .string(StringArray(values))
    }

    /// Create an ``.int64`` column from a dense array of Swift `Int` values.
    ///
    /// - Parameter values: An array of `Int`. Each value is widened to `Int64`
    ///   for storage. All positions are marked valid.
    /// - Returns: A ``Column`` wrapping a ``NullableArray<Int64>``.
    ///
    /// Use this when you specifically need integer precision. For general
    /// numeric data, prefer ``fromDoubles(_:)`` to follow the library's
    /// convention of defaulting to Double.
    public static func fromInts(_ values: [Int]) -> Column {
        .int64(NullableArray(NativeArray(values.map { Int64($0) })))
    }

    /// Create a ``.bool`` column from a dense array of Bool values.
    ///
    /// - Parameter values: An array of `Bool`. All positions are marked valid.
    /// - Returns: A ``Column`` wrapping a ``NullableArray<Bool>`` with an
    ///   all-ones validity bitmap.
    public static func fromBools(_ values: [Bool]) -> Column {
        let nullable = NullableArray(data: NativeArray(values), mask: BitVector(repeating: true, count: values.count))
        return .bool(nullable)
    }

    // MARK: - Take

    /// Gather elements at the specified integer positions into a new column.
    ///
    /// - Parameter indices: An array of zero-based positions. An index of `-1`
    ///   or any out-of-range index produces an NA in the output.
    /// - Returns: A new ``Column`` of the same case (dtype) with length
    ///   `indices.count`.
    ///
    /// For the ``.bool`` case, a manual loop is required because `Bool` does
    /// not conform to ``ExpressibleByIntegerLiteral``, so it cannot use the
    /// generic ``NullableArray.take(indices:)`` which needs a zero-initializable
    /// element type.
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

    /// Gather elements where a Boolean mask is `true` into a new column.
    ///
    /// - Parameters:
    ///   - mask: A Boolean array of the same length as this column. Positions
    ///     where `mask[i]` is `true` are included in the output.
    ///   - trueCount: The precomputed number of `true` values in `mask`. This
    ///     must exactly equal `mask.filter { $0 }.count`; passing an incorrect
    ///     value leads to undefined behavior. Providing it avoids a redundant
    ///     counting pass inside each concrete array's take implementation.
    /// - Returns: A new ``Column`` of the same dtype with length `trueCount`.
    ///
    /// As with ``take(indices:)``, the ``.bool`` case requires manual handling.
    public func take(mask: [Bool], trueCount: Int) -> Column {
        switch self {
        case .double(let a): return .double(a.take(mask: mask, trueCount: trueCount))
        case .string(let a): return .string(a.take(mask: mask, trueCount: trueCount))
        case .bool(let a):
            var values = ContiguousArray<Bool>()
            var bools = [Bool]()
            values.reserveCapacity(trueCount)
            bools.reserveCapacity(trueCount)
            mask.withUnsafeBufferPointer { m in
                for i in 0..<m.count {
                    if m[i] {
                        if a.mask[i] {
                            values.append(a.data[i])
                            bools.append(true)
                        } else {
                            values.append(false)
                            bools.append(false)
                        }
                    }
                }
            }
            return .bool(NullableArray(data: NativeArray(values), mask: BitVector(bools)))
        case .int64(let a): return .int64(a.take(mask: mask, trueCount: trueCount))
        }
    }

    // MARK: - Copy

    /// Return a deep (independent) copy of this column.
    ///
    /// After copying, mutations to the original column will not affect the copy
    /// and vice versa. This is primarily used internally by ``DataFrame``'s
    /// copy-on-write machinery.
    public func copy() -> Column {
        switch self {
        case .double(let a): return .double(a.copy())
        case .string(let a): return .string(a.copy())
        case .bool(let a): return .bool(a.copy())
        case .int64(let a): return .int64(a.copy())
        }
    }

    // MARK: - Aggregations

    /// The sum of all valid values in this column, as a Double.
    ///
    /// Returns `nil` for non-numeric columns (``.string``, ``.bool``) or if
    /// there are no valid values. For ``.int64`` columns, values are first
    /// promoted to Double via ``asDouble()``.
    public func sum() -> Double? {
        asDouble()?.sum()
    }

    /// The arithmetic mean of all valid values, as a Double.
    ///
    /// Returns `nil` for non-numeric columns or if there are no valid values.
    public func mean() -> Double? {
        asDouble()?.mean()
    }

    /// The standard deviation of all valid values, as a Double.
    ///
    /// - Parameter ddof: Delta degrees of freedom. Defaults to 1 (sample std).
    /// - Returns: The standard deviation, or `nil` for non-numeric columns or
    ///   if valid count <= `ddof`.
    public func std(ddof: Int = 1) -> Double? {
        asDouble()?.std(ddof: ddof)
    }

    /// The minimum of all valid values, as a Double.
    ///
    /// Returns `nil` for non-numeric columns or if there are no valid values.
    public func min() -> Double? {
        asDouble()?.min()
    }

    /// The maximum of all valid values, as a Double.
    ///
    /// Returns `nil` for non-numeric columns or if there are no valid values.
    public func max() -> Double? {
        asDouble()?.max()
    }

    // MARK: - Description

    /// A textual representation of the column, delegated to the underlying
    /// array's `description`.
    public var description: String {
        switch self {
        case .double(let a): return a.description
        case .string(let a): return a.description
        case .bool(let a): return a.description
        case .int64(let a): return a.description
        }
    }
}
