/// The fundamental 1D data container protocol in SwiftPandas.
///
/// Replaces Python pandas' ExtensionArray. All array backends (NativeArray,
/// NullableArray, StringArray, etc.) conform to this protocol.
public protocol PandasArray: CustomStringConvertible {
    /// The element type stored in this array.
    associatedtype Element

    /// The runtime dtype tag for this array.
    var dtype: DTypeEnum { get }

    /// Number of elements.
    var count: Int { get }

    /// Total memory usage in bytes.
    var nbytes: Int { get }

    /// Access element at position. Returns nil for NA values.
    func get(_ index: Int) -> Element?

    /// Boolean mask: true where value is missing/NA.
    func isNA() -> [Bool]

    /// Number of non-NA values.
    var validCount: Int { get }

    /// Return a deep copy.
    func copy() -> Self

    /// Take elements at given integer positions. -1 means fill with NA.
    func take(indices: [Int]) -> Self

    /// Return unique values (preserving order of first occurrence).
    func unique() -> Self

    /// Return argsort indices.
    func argsort(ascending: Bool) -> [Int]

    /// Fill missing values with a constant.
    func fillNA(value: Element) -> Self

    /// Factorize: return (codes, uniques) where codes map each element to
    /// its position in uniques. NA elements get code -1.
    func factorize() -> (codes: [Int], uniques: Self)
}

// MARK: - Default implementations

public extension PandasArray {
    var validCount: Int {
        isNA().filter { !$0 }.count
    }
}

/// Marker protocol for arrays whose elements support arithmetic.
public protocol NumericPandasArray: PandasArray where Element: Numeric & Comparable {
    /// Sum of all non-NA values. Returns nil if no valid values.
    func sum() -> Element?

    /// Minimum of all non-NA values.
    func min() -> Element?

    /// Maximum of all non-NA values.
    func max() -> Element?
}

/// Marker protocol for arrays whose elements are floating-point, enabling
/// operations like mean, std, var.
public protocol FloatingPointPandasArray: NumericPandasArray where Element: FloatingPoint {
    /// Arithmetic mean of all non-NA values.
    func mean() -> Element?

    /// Standard deviation of all non-NA values.
    func std(ddof: Int) -> Element?

    /// Variance of all non-NA values.
    func variance(ddof: Int) -> Element?
}
