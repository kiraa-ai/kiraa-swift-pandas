// MARK: - Signed Integer DTypes

public struct Int8DType: SignedIntegerDType {
    public typealias Scalar = Int8
    public let name = "int8"
    public var description: String { name }
    public init() {}
}

public struct Int16DType: SignedIntegerDType {
    public typealias Scalar = Int16
    public let name = "int16"
    public var description: String { name }
    public init() {}
}

public struct Int32DType: SignedIntegerDType {
    public typealias Scalar = Int32
    public let name = "int32"
    public var description: String { name }
    public init() {}
}

public struct Int64DType: SignedIntegerDType {
    public typealias Scalar = Int64
    public let name = "int64"
    public var description: String { name }
    public init() {}
}

// MARK: - Unsigned Integer DTypes

public struct UInt8DType: UnsignedIntegerDType {
    public typealias Scalar = UInt8
    public let name = "uint8"
    public var description: String { name }
    public init() {}
}

public struct UInt16DType: UnsignedIntegerDType {
    public typealias Scalar = UInt16
    public let name = "uint16"
    public var description: String { name }
    public init() {}
}

public struct UInt32DType: UnsignedIntegerDType {
    public typealias Scalar = UInt32
    public let name = "uint32"
    public var description: String { name }
    public init() {}
}

public struct UInt64DType: UnsignedIntegerDType {
    public typealias Scalar = UInt64
    public let name = "uint64"
    public var description: String { name }
    public init() {}
}

// MARK: - Floating Point DTypes

public struct Float32DType: FloatingPointDType {
    public typealias Scalar = Float
    public let name = "float32"
    public var description: String { name }
    public init() {}
}

public struct Float64DType: FloatingPointDType {
    public typealias Scalar = Double
    public let name = "float64"
    public var description: String { name }
    public init() {}
}
