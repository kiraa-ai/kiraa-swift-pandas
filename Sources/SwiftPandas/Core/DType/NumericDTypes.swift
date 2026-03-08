// ============================================================================
// NumericDTypes.swift — Concrete DType Structs for All Numeric Types
// ============================================================================
//
// This file provides the concrete dtype structs for every numeric scalar type
// supported by SwiftPandas, covering the full matrix of:
//
//   Signed integers:   Int8DType, Int16DType, Int32DType, Int64DType
//   Unsigned integers: UInt8DType, UInt16DType, UInt32DType, UInt64DType
//   Floating-point:    Float32DType, Float64DType
//
// Each struct is a zero-stored-property, value-type tag that conforms to the
// appropriate protocol from DType.swift (SignedIntegerDType,
// UnsignedIntegerDType, or FloatingPointDType). Because they carry no state,
// they are trivially Hashable, Equatable, and Sendable, and can be created
// with `init()` at essentially zero cost.
//
// The naming convention follows pandas exactly: the `name` property returns
// lowercase strings like "int64" and "float32", ensuring compatibility with
// pandas-style describe() output and CSV metadata.
//
// ============================================================================

// MARK: - Signed Integer DTypes

/// 8-bit signed integer dtype.
///
/// Wraps Swift's `Int8` scalar type. Represents values in the range
/// **-128 ... 127** (2^7 on each side of zero). This is the smallest integer
/// dtype and is useful for memory-constrained scenarios such as encoding
/// categorical labels or small counters.
///
/// Corresponds to pandas' `int8` / NumPy's `numpy.int8`.
public struct Int8DType: SignedIntegerDType {
    public typealias Scalar = Int8
    public let name = "int8"
    public var description: String { name }
    public init() {}
}

/// 16-bit signed integer dtype.
///
/// Wraps Swift's `Int16` scalar type. Represents values in the range
/// **-32,768 ... 32,767**. Useful when 8 bits is insufficient but 32 bits
/// would waste memory — for example, audio samples or small identifiers.
///
/// Corresponds to pandas' `int16` / NumPy's `numpy.int16`.
public struct Int16DType: SignedIntegerDType {
    public typealias Scalar = Int16
    public let name = "int16"
    public var description: String { name }
    public init() {}
}

/// 32-bit signed integer dtype.
///
/// Wraps Swift's `Int32` scalar type. Represents values in the range
/// **-2,147,483,648 ... 2,147,483,647** (approximately +/- 2.1 billion).
/// A common choice for database primary keys and medium-range counters.
///
/// Corresponds to pandas' `int32` / NumPy's `numpy.int32`.
public struct Int32DType: SignedIntegerDType {
    public typealias Scalar = Int32
    public let name = "int32"
    public var description: String { name }
    public init() {}
}

/// 64-bit signed integer dtype — the **default** integer dtype in SwiftPandas.
///
/// Wraps Swift's `Int64` scalar type. Represents values in the range
/// **-9,223,372,036,854,775,808 ... 9,223,372,036,854,775,807** (approximately
/// +/- 9.2 quintillion). This is the widest signed integer type and the
/// default when no explicit dtype is specified, matching pandas' behavior
/// where `int64` is the standard integer dtype.
///
/// Corresponds to pandas' `int64` / NumPy's `numpy.int64`.
public struct Int64DType: SignedIntegerDType {
    public typealias Scalar = Int64
    public let name = "int64"
    public var description: String { name }
    public init() {}
}

// MARK: - Unsigned Integer DTypes

/// 8-bit unsigned integer dtype.
///
/// Wraps Swift's `UInt8` scalar type. Represents values in the range
/// **0 ... 255**. Commonly used for raw byte data, pixel intensities
/// (grayscale images), and small non-negative counts.
///
/// Corresponds to pandas' `uint8` / NumPy's `numpy.uint8`.
public struct UInt8DType: UnsignedIntegerDType {
    public typealias Scalar = UInt8
    public let name = "uint8"
    public var description: String { name }
    public init() {}
}

/// 16-bit unsigned integer dtype.
///
/// Wraps Swift's `UInt16` scalar type. Represents values in the range
/// **0 ... 65,535**. Useful for Unicode code units (UTF-16), network ports,
/// and medium-range non-negative values.
///
/// Corresponds to pandas' `uint16` / NumPy's `numpy.uint16`.
public struct UInt16DType: UnsignedIntegerDType {
    public typealias Scalar = UInt16
    public let name = "uint16"
    public var description: String { name }
    public init() {}
}

/// 32-bit unsigned integer dtype.
///
/// Wraps Swift's `UInt32` scalar type. Represents values in the range
/// **0 ... 4,294,967,295** (approximately 4.3 billion). Suitable for IPv4
/// addresses, large non-negative counts, and hash values.
///
/// Corresponds to pandas' `uint32` / NumPy's `numpy.uint32`.
public struct UInt32DType: UnsignedIntegerDType {
    public typealias Scalar = UInt32
    public let name = "uint32"
    public var description: String { name }
    public init() {}
}

/// 64-bit unsigned integer dtype.
///
/// Wraps Swift's `UInt64` scalar type. Represents values in the range
/// **0 ... 18,446,744,073,709,551,615** (approximately 18.4 quintillion).
/// The widest unsigned integer type, useful for large identifiers, memory
/// addresses, and bit-packed data.
///
/// Corresponds to pandas' `uint64` / NumPy's `numpy.uint64`.
public struct UInt64DType: UnsignedIntegerDType {
    public typealias Scalar = UInt64
    public let name = "uint64"
    public var description: String { name }
    public init() {}
}

// MARK: - Floating Point DTypes

/// 32-bit (single-precision) IEEE 754 floating-point dtype.
///
/// Wraps Swift's `Float` scalar type. Provides approximately **7 decimal
/// digits** of precision with a range of roughly **1.2e-38 ... 3.4e+38**.
/// Half the memory footprint of `Float64`, making it a good choice for
/// large datasets where full double precision is unnecessary (e.g., GPU
/// interop, image processing, machine learning weights).
///
/// Corresponds to pandas' `float32` / NumPy's `numpy.float32`.
public struct Float32DType: FloatingPointDType {
    public typealias Scalar = Float
    public let name = "float32"
    public var description: String { name }
    public init() {}
}

/// 64-bit (double-precision) IEEE 754 floating-point dtype — the **default**
/// floating-point dtype in SwiftPandas.
///
/// Wraps Swift's `Double` scalar type. Provides approximately **15–17 decimal
/// digits** of precision with a range of roughly **2.2e-308 ... 1.8e+308**.
/// This is the default floating-point type used by SwiftPandas for arithmetic
/// results and type promotion, matching pandas' convention where `float64` is
/// the standard float dtype.
///
/// Corresponds to pandas' `float64` / NumPy's `numpy.float64`.
public struct Float64DType: FloatingPointDType {
    public typealias Scalar = Double
    public let name = "float64"
    public var description: String { name }
    public init() {}
}
