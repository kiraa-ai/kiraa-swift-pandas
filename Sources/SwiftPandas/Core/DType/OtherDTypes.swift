// MARK: - Boolean DType

public struct BoolDType: PandasDType {
    public typealias Scalar = Bool
    public let name = "bool"
    public var isBoolean: Bool { true }
    public var description: String { name }
    public init() {}
}

// MARK: - String DType

public struct StringDType: PandasDType {
    public typealias Scalar = String
    public let name = "string"
    public var description: String { name }
    public init() {}
}
