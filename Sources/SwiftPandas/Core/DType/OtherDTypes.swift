// ============================================================================
// OtherDTypes.swift — Non-Numeric DType Structs (Bool, String)
// ============================================================================
//
// This file defines the concrete dtype structs for non-numeric column types
// in SwiftPandas. These types conform directly to `PandasDType` rather than
// going through the `NumericDType` refinement hierarchy, because they do not
// support general arithmetic operations.
//
// Currently two non-numeric dtypes are provided:
//
//   - BoolDType:   Wraps Swift's `Bool`. Used for boolean columns, filter
//                  masks, and logical operations.
//   - StringDType: Wraps Swift's `String`. Used for text/categorical data.
//
// Like the numeric dtypes in NumericDTypes.swift, these are zero-stored-
// property value types that serve purely as compile-time type tags.
//
// ============================================================================

// MARK: - Boolean DType

/// Boolean dtype representing `true` / `false` values.
///
/// Wraps Swift's native `Bool` type. Boolean columns are used extensively for:
///
/// - **Filter masks**: the result of comparison operations like `series > 5`
///   is a boolean ``Series`` that can be used to index into a ``DataFrame``.
/// - **Logical operations**: element-wise AND (`&`), OR (`|`), and NOT (`~`)
///   operate on boolean columns.
/// - **Conditional aggregation**: `sum()` on a boolean column counts `true`
///   values (matching pandas behavior).
///
/// Despite being conceptually numeric in some contexts (pandas treats `True`
/// as 1 and `False` as 0 for aggregation), `BoolDType` does **not** conform
/// to ``NumericDType``. Instead it sets `isBoolean` to `true` and leaves
/// `isNumeric` at its default of `false`, matching pandas' `bool` dtype
/// classification.
///
/// Corresponds to pandas' `bool` / NumPy's `numpy.bool_`.
public struct BoolDType: PandasDType {
    public typealias Scalar = Bool
    public let name = "bool"

    /// Always returns `true`, identifying this dtype as boolean.
    public var isBoolean: Bool { true }

    public var description: String { name }
    public init() {}
}

// MARK: - String DType

/// Variable-length Unicode string dtype.
///
/// Wraps Swift's native `String` type, which uses UTF-8 storage internally.
/// String columns are used for:
///
/// - **Text data**: names, labels, descriptions, free-form text.
/// - **Categorical-like data**: when the number of distinct values is large
///   or not known ahead of time, strings provide a flexible representation.
/// - **Join keys**: string columns can serve as merge/join keys between
///   DataFrames.
///
/// `StringDType` is **not** numeric, so `isNumeric` returns `false`. No
/// arithmetic operations are defined on string columns; however, string-
/// specific operations (contains, startswith, split, etc.) can be provided
/// through extension methods on ``Series`` constrained to `StringDType`.
///
/// Unlike pandas, which distinguishes between `object` dtype (Python objects)
/// and the newer `StringDtype` (pandas 1.0+), SwiftPandas uses a single
/// `StringDType` backed by Swift's native `String`, avoiding the ambiguity
/// and performance pitfalls of Python's object dtype.
///
/// Corresponds to pandas' `StringDtype()` / `pd.StringDtype()`.
public struct StringDType: PandasDType {
    public typealias Scalar = String
    public let name = "string"
    public var description: String { name }
    public init() {}
}
