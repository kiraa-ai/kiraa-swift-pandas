/// Represents a data type in SwiftPandas, analogous to pandas' ExtensionDtype.
///
/// Every column in a DataFrame has a dtype that determines its storage format,
/// NA sentinel, and supported operations.
public protocol PandasDType: Hashable, CustomStringConvertible {
    /// The Swift scalar type this dtype represents.
    associatedtype Scalar

    /// Human-readable name, e.g. "int64", "float64", "string".
    var name: String { get }

    /// Whether this dtype supports arithmetic operations.
    var isNumeric: Bool { get }

    /// Whether this dtype represents boolean values.
    var isBoolean: Bool { get }

    /// Whether this dtype represents signed integer values.
    var isSignedInteger: Bool { get }

    /// Whether this dtype represents unsigned integer values.
    var isUnsignedInteger: Bool { get }

    /// Whether this dtype represents floating-point values.
    var isFloat: Bool { get }
}

// MARK: - Default implementations

public extension PandasDType {
    var isBoolean: Bool { false }
    var isSignedInteger: Bool { false }
    var isUnsignedInteger: Bool { false }
    var isFloat: Bool { false }
    var isNumeric: Bool { isSignedInteger || isUnsignedInteger || isFloat }

    var isInteger: Bool { isSignedInteger || isUnsignedInteger }
}

// MARK: - Numeric DType Protocols

/// A dtype whose scalar type is numeric and comparable.
public protocol NumericDType: PandasDType where Scalar: Numeric & Comparable {}

/// A dtype whose scalar type is a signed integer.
public protocol SignedIntegerDType: NumericDType where Scalar: SignedInteger & FixedWidthInteger {
}

public extension SignedIntegerDType {
    var isSignedInteger: Bool { true }
}

/// A dtype whose scalar type is an unsigned integer.
public protocol UnsignedIntegerDType: NumericDType where Scalar: UnsignedInteger & FixedWidthInteger {
}

public extension UnsignedIntegerDType {
    var isUnsignedInteger: Bool { true }
}

/// A dtype whose scalar type is floating-point.
public protocol FloatingPointDType: NumericDType where Scalar: FloatingPoint {}

public extension FloatingPointDType {
    var isFloat: Bool { true }
}

// MARK: - DTypeEnum (runtime type tag)

/// Runtime type tag for dynamic dispatch when the dtype is not known at compile time.
public enum DTypeEnum: Hashable, CustomStringConvertible, Sendable {
    case int8, int16, int32, int64
    case uint8, uint16, uint32, uint64
    case float32, float64
    case bool
    case string
    case datetime
    case timedelta

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

    public var isInteger: Bool {
        switch self {
        case .int8, .int16, .int32, .int64,
             .uint8, .uint16, .uint32, .uint64:
            return true
        default:
            return false
        }
    }

    public var isFloat: Bool {
        self == .float32 || self == .float64
    }
}
