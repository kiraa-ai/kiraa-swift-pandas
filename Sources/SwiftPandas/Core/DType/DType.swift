// ============================================================================
// DType.swift — SwiftPandas Data Type Protocol Hierarchy
// ============================================================================
//
// This file defines the core type system for SwiftPandas, mirroring the role
// of `pandas.api.types.CategoricalDtype` / `ExtensionDtype` in Python pandas.
//
// ## Protocol Hierarchy
//
//     PandasDType              (root — any column type: numeric, bool, string, etc.)
//       ├── NumericDType       (Scalar: Numeric & Comparable)
//       │     ├── SignedIntegerDType    (Scalar: SignedInteger & FixedWidthInteger)
//       │     ├── UnsignedIntegerDType (Scalar: UnsignedInteger & FixedWidthInteger)
//       │     └── FloatingPointDType   (Scalar: FloatingPoint)
//       ├── BoolDType          (defined in OtherDTypes.swift)
//       └── StringDType        (defined in OtherDTypes.swift)
//
// The split into separate signed/unsigned/floating-point protocols exists so
// that generic algorithms can constrain to exactly the set of types they
// support (e.g., bitwise operations only on integer dtypes, IEEE-754
// rounding only on floating-point dtypes) while still sharing common
// numeric code through `NumericDType`.
//
// ## Compile-Time vs. Run-Time Typing
//
// `PandasDType` and its refinements provide **compile-time** type safety
// through Swift generics. When a column's element type is known statically,
// the concrete dtype struct (e.g., `Int64DType`) carries the `Scalar`
// associated type, enabling zero-cost generic specialization.
//
// `DTypeEnum` at the bottom of this file provides a **run-time** type tag
// for situations where the element type is erased (e.g., heterogeneous
// DataFrame columns, CSV parsing, user-supplied column specifications).
//
// ============================================================================

/// Represents a data type in SwiftPandas, analogous to pandas' `ExtensionDtype`.
///
/// Every column (``Series``) in a ``DataFrame`` has exactly one dtype that
/// determines:
/// - **Storage format** — how scalar values are laid out in memory (e.g.,
///   contiguous 8-byte IEEE 754 doubles for `float64`).
/// - **NA semantics** — how missing values are represented. SwiftPandas uses a
///   separate ``BitVector`` validity mask rather than sentinel values, so any
///   `Scalar` type can be nullable without reserving a special value.
/// - **Supported operations** — arithmetic, comparison, string manipulation,
///   etc. The `isNumeric`, `isBoolean`, and related flags let generic code
///   dispatch to the correct implementation at compile time or run time.
///
/// Conforming types are expected to be lightweight, zero-stored-property structs
/// (essentially type tags) so they can be created, compared, and hashed at
/// negligible cost. All concrete dtype structs live in `NumericDTypes.swift` and
/// `OtherDTypes.swift`.
///
/// ## Conformance Requirements
///
/// | Requirement        | Purpose                                               |
/// |--------------------|-------------------------------------------------------|
/// | `Scalar`           | The Swift type stored in the underlying buffer.       |
/// | `name`             | A pandas-compatible string such as `"int64"`.         |
/// | `isNumeric`        | `true` for any dtype that supports `+`, `-`, `*`, `/`.|
/// | `isBoolean`        | `true` only for ``BoolDType``.                        |
/// | `isSignedInteger`  | `true` for `Int8` … `Int64` dtypes.                   |
/// | `isUnsignedInteger`| `true` for `UInt8` … `UInt64` dtypes.                 |
/// | `isFloat`          | `true` for `Float32` and `Float64` dtypes.            |
///
/// Default implementations are provided for the boolean flags so that most
/// conforming types only need to supply `Scalar` and `name`.
public protocol PandasDType: Hashable, CustomStringConvertible {
    /// The Swift scalar type this dtype represents.
    ///
    /// For example, `Int64DType.Scalar` is `Int64` and `Float64DType.Scalar`
    /// is `Double`. This associated type flows through the generic system so
    /// that ``Series`` and ``NativeArray`` can store and return correctly-typed
    /// values without boxing or dynamic casts.
    associatedtype Scalar

    /// A pandas-compatible, human-readable name for this dtype.
    ///
    /// Examples: `"int8"`, `"int64"`, `"float32"`, `"float64"`, `"bool"`,
    /// `"string"`, `"datetime64[ns]"`. The name is used in `describe()` output,
    /// CSV headers, and debug descriptions.
    var name: String { get }

    /// Whether this dtype supports arithmetic operations (`+`, `-`, `*`, `/`).
    ///
    /// Returns `true` for all signed integer, unsigned integer, and
    /// floating-point dtypes. The default implementation derives this from
    /// `isSignedInteger || isUnsignedInteger || isFloat`.
    var isNumeric: Bool { get }

    /// Whether this dtype represents boolean (`true` / `false`) values.
    ///
    /// Only ``BoolDType`` returns `true`. The default implementation returns
    /// `false`.
    var isBoolean: Bool { get }

    /// Whether this dtype represents signed integer values (`Int8` … `Int64`).
    ///
    /// The default implementation returns `false`. Overridden to `true` by
    /// ``SignedIntegerDType`` conformances.
    var isSignedInteger: Bool { get }

    /// Whether this dtype represents unsigned integer values (`UInt8` … `UInt64`).
    ///
    /// The default implementation returns `false`. Overridden to `true` by
    /// ``UnsignedIntegerDType`` conformances.
    var isUnsignedInteger: Bool { get }

    /// Whether this dtype represents IEEE 754 floating-point values.
    ///
    /// Returns `true` for `Float32` and `Float64` dtypes. The default
    /// implementation returns `false`. Overridden to `true` by
    /// ``FloatingPointDType`` conformances.
    var isFloat: Bool { get }
}

// MARK: - Default implementations

/// Default flag values for ``PandasDType``.
///
/// Every boolean flag defaults to `false` except `isNumeric`, which is derived
/// from the three sub-category flags. Concrete refinement protocols
/// (``SignedIntegerDType``, ``UnsignedIntegerDType``, ``FloatingPointDType``)
/// override exactly the flag that applies to them, so individual dtype structs
/// never need to touch these properties.
public extension PandasDType {
    var isBoolean: Bool { false }
    var isSignedInteger: Bool { false }
    var isUnsignedInteger: Bool { false }
    var isFloat: Bool { false }
    var isNumeric: Bool { isSignedInteger || isUnsignedInteger || isFloat }

    /// Convenience: `true` when the dtype is any integer type (signed **or**
    /// unsigned). Not part of the protocol requirements — provided purely as
    /// a derived helper.
    var isInteger: Bool { isSignedInteger || isUnsignedInteger }
}

// MARK: - Numeric DType Protocols

/// A dtype whose scalar type conforms to both `Numeric` and `Comparable`.
///
/// This is the base refinement for all numeric dtypes. It adds no new
/// requirements beyond constraining the `Scalar` associated type, which
/// enables generic algorithms to use arithmetic operators (`+`, `-`, `*`)
/// and relational comparisons (`<`, `>`, etc.) on the underlying values.
///
/// Three further refinements exist below — ``SignedIntegerDType``,
/// ``UnsignedIntegerDType``, and ``FloatingPointDType`` — which tighten the
/// constraint on `Scalar` and set the appropriate classification flag.
public protocol NumericDType: PandasDType where Scalar: Numeric & Comparable {}

/// A dtype whose scalar type is a **signed**, fixed-width integer
/// (`Int8`, `Int16`, `Int32`, or `Int64`).
///
/// The `FixedWidthInteger` constraint guarantees bitwise operations, overflow
/// reporting, and a known `bitWidth`. Conforming types automatically get
/// `isSignedInteger == true` through the extension below, which also causes
/// `isNumeric` and `isInteger` to return `true`.
public protocol SignedIntegerDType: NumericDType where Scalar: SignedInteger & FixedWidthInteger {
}

public extension SignedIntegerDType {
    /// Always `true` for signed integer dtypes.
    var isSignedInteger: Bool { true }
}

/// A dtype whose scalar type is an **unsigned**, fixed-width integer
/// (`UInt8`, `UInt16`, `UInt32`, or `UInt64`).
///
/// Unsigned dtypes are particularly useful for representing raw byte data,
/// memory addresses, or non-negative counts. The `FixedWidthInteger`
/// constraint provides the same bit-manipulation capabilities as signed
/// integers. Conforming types automatically get `isUnsignedInteger == true`.
public protocol UnsignedIntegerDType: NumericDType where Scalar: UnsignedInteger & FixedWidthInteger {
}

public extension UnsignedIntegerDType {
    /// Always `true` for unsigned integer dtypes.
    var isUnsignedInteger: Bool { true }
}

/// A dtype whose scalar type conforms to Swift's `FloatingPoint` protocol.
///
/// In practice this covers `Float` (32-bit, IEEE 754 single precision) and
/// `Double` (64-bit, IEEE 754 double precision). Floating-point dtypes
/// support fractional values, `NaN`, `±infinity`, and subnormal numbers.
/// Conforming types automatically get `isFloat == true`.
public protocol FloatingPointDType: NumericDType where Scalar: FloatingPoint {}

public extension FloatingPointDType {
    /// Always `true` for floating-point dtypes.
    var isFloat: Bool { true }
}

// MARK: - DTypeEnum (runtime type tag)

/// A run-time type tag used when the element type of a column is not known at
/// compile time.
///
/// While the ``PandasDType`` protocol hierarchy provides static (generic) type
/// safety, many real-world operations need to inspect or switch on a column's
/// type dynamically — for example:
///
/// - **CSV parsing**: the inferred dtype is determined at run time from the data.
/// - **DataFrame column iteration**: columns may have heterogeneous dtypes.
/// - **Serialization / deserialization**: type information must be stored as a
///   simple value (not a generic parameter).
///
/// `DTypeEnum` covers every dtype supported by SwiftPandas, including the two
/// temporal types (`datetime`, `timedelta`) that use nanosecond resolution to
/// match pandas' `datetime64[ns]` and `timedelta64[ns]`.
///
/// The `description` property returns the pandas-compatible string
/// representation (e.g., `"int64"`, `"datetime64[ns]"`), making it suitable
/// for display and interop.
public enum DTypeEnum: Hashable, CustomStringConvertible, Sendable {
    case int8, int16, int32, int64
    case uint8, uint16, uint32, uint64
    case float32, float64
    case bool
    case string
    case datetime
    case timedelta

    /// A pandas-compatible string representation of this dtype.
    ///
    /// Temporal types include their resolution suffix — `"datetime64[ns]"` and
    /// `"timedelta64[ns]"` — to match pandas conventions.
    public var description: String {
        switch self {
        case .int8: return "int8"
        case .int16: return "int16"
        case .int32: return "int32"
        case .int64: return "int64"
        case .uint8: return "uint8"
        case .uint16: return "uint16"
        case .uint32: return "uint32"
        case .uint64: return "uint64"
        case .float32: return "float32"
        case .float64: return "float64"
        case .bool: return "bool"
        case .string: return "string"
        case .datetime: return "datetime64[ns]"
        case .timedelta: return "timedelta64[ns]"
        }
    }

    /// Whether this type tag represents a numeric dtype (any integer or
    /// floating-point type). Boolean and string types are **not** numeric.
    public var isNumeric: Bool {
        switch self {
        case .int8, .int16, .int32, .int64,
             .uint8, .uint16, .uint32, .uint64,
             .float32, .float64:
            return true
        default:
            return false
        }
    }

    /// Whether this type tag represents any integer dtype (signed or unsigned).
    public var isInteger: Bool {
        switch self {
        case .int8, .int16, .int32, .int64,
             .uint8, .uint16, .uint32, .uint64:
            return true
        default:
            return false
        }
    }

    /// Whether this type tag represents a floating-point dtype (`float32` or
    /// `float64`).
    public var isFloat: Bool {
        self == .float32 || self == .float64
    }
}
