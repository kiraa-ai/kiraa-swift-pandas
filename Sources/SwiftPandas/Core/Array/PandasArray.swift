// ===----------------------------------------------------------------------===//
//
// PandasArray.swift
// SwiftPandas
//
// This file defines the protocol hierarchy for one-dimensional array containers
// in SwiftPandas. It mirrors the role of pandas' ``ExtensionArray`` ABC but is
// expressed as a Swift protocol stack so that concrete types (``NativeArray``,
// ``NullableArray``, ``StringArray``) can each provide their own optimized
// storage while sharing a uniform API surface.
//
// Protocol hierarchy:
//
//     PandasArray                       (base: element access, NA handling,
//      |                                 copy, take, unique, argsort, factorize)
//      |
//      +-- NumericPandasArray            (adds sum/min/max for Numeric & Comparable)
//           |
//           +-- FloatingPointPandasArray  (adds mean/std/variance for FloatingPoint)
//
// ``PandasArray`` is generic over an associated ``Element`` type and defines the
// minimal contract every 1-D container must satisfy so that higher-level
// constructs (``Series``, ``DataFrame``, ``Column``) can operate on columns
// without knowing the concrete storage backend.
//
// ``NumericPandasArray`` refines ``PandasArray`` by constraining ``Element`` to
// ``Numeric & Comparable`` and requiring basic aggregation operations. This
// allows code that needs arithmetic reductions to accept any numeric container
// generically.
//
// ``FloatingPointPandasArray`` further refines ``NumericPandasArray`` for
// ``FloatingPoint`` elements, adding statistical operations (mean, standard
// deviation, variance) that require division and square roots.
//
// ===----------------------------------------------------------------------===//

/// The fundamental 1-D data container protocol in SwiftPandas.
///
/// Every array backend in the library conforms to ``PandasArray``. It
/// serves the same architectural role as Python pandas' ``ExtensionArray``
/// abstract base class: it defines the minimal set of operations that any
/// columnar storage type must support so that ``Series``, ``DataFrame``, and
/// other higher-level abstractions can work uniformly with heterogeneous data.
///
/// Conforming types include:
/// - ``NativeArray<T>`` -- contiguous, non-nullable, typed storage (analogous to
///   a raw NumPy ndarray).
/// - ``NullableArray<T>`` -- contiguous typed storage with a separate Arrow-style
///   validity bitmap for NA support.
/// - ``StringArray`` -- variable-length string storage backed by `[String?]`.
///
/// ## Design Notes
///
/// The protocol uses an associated type rather than a generic parameter so that
/// conforming types can specialize behavior (e.g., Accelerate-optimized paths
/// for ``Double``) without requiring callers to know the concrete type at every
/// call site. The ``DTypeEnum`` tag exposed via ``dtype`` allows runtime type
/// queries when the concrete type has been erased (e.g., inside ``Column``).
public protocol PandasArray: CustomStringConvertible {
    /// The element type stored in this array.
    ///
    /// For nullable arrays this is the *unwrapped* element type. For example,
    /// ``NullableArray<Double>`` has `Element == Double`, not `Double?`. Missing
    /// values are represented externally via the validity bitmap, not via
    /// Swift optionals at the storage level.
    associatedtype Element

    /// The runtime dtype tag for this array.
    ///
    /// Returns a ``DTypeEnum`` value that identifies the logical data type of
    /// the column at runtime. This is used by ``Column`` and ``DataFrame`` to
    /// make type-based decisions (e.g., which aggregation path to follow)
    /// without down-casting the array to a concrete type.
    var dtype: DTypeEnum { get }

    /// The number of elements in this array, including any positions marked as NA.
    ///
    /// This is the logical length of the column and is guaranteed to equal the
    /// length of the validity mask (if one exists).
    var count: Int { get }

    /// Total memory usage in bytes, including both data storage and any
    /// auxiliary structures (e.g., validity bitmaps).
    ///
    /// This is an approximation intended for memory profiling and display
    /// (similar to ``pandas.DataFrame.memory_usage``). Overhead from Swift
    /// object headers or allocator metadata is not included.
    var nbytes: Int { get }

    /// Access the element at the given position.
    ///
    /// - Parameter index: A zero-based position. Must be in `0..<count`.
    /// - Returns: The element at that position, or `nil` if the position is
    ///   marked as NA / missing.
    ///
    /// This is the primary random-access read API. For bulk access, prefer
    /// ``take(indices:)`` or ``withUnsafeBufferPointer(_:)`` (on concrete types)
    /// to avoid per-element overhead.
    func get(_ index: Int) -> Element?

    /// Produce a Boolean mask indicating which positions are missing (NA).
    ///
    /// - Returns: An array of length ``count`` where `true` at position *i*
    ///   means the element at *i* is NA.
    ///
    /// This is the inverse of a validity mask and is useful for downstream
    /// filtering operations (e.g., ``dropna()`` on a Series).
    func isNA() -> [Bool]

    /// The number of non-NA (valid) values in this array.
    ///
    /// Default implementation iterates ``isNA()`` and counts `false` entries.
    /// Concrete types that maintain a precomputed popcount (e.g.,
    /// ``NullableArray`` via its ``BitVector``) override this for O(1) access.
    var validCount: Int { get }

    /// Return a deep (independent) copy of this array.
    ///
    /// After calling `copy()`, mutations to the original will not affect the
    /// copy and vice versa. This is primarily useful when you need to guarantee
    /// isolation before performing in-place mutations (e.g., ``nthElement``
    /// on ``NativeArray``).
    func copy() -> Self

    /// Gather elements at the specified integer positions into a new array.
    ///
    /// - Parameter indices: An array of zero-based positions. An index of `-1`
    ///   is treated as "fill with NA" (the resulting position will be missing).
    ///   Out-of-range positive indices are also treated as NA.
    /// - Returns: A new array of length `indices.count` containing the gathered
    ///   elements.
    ///
    /// This is the primary reindexing primitive and is used extensively by
    /// join, merge, and GroupBy operations.
    func take(indices: [Int]) -> Self

    /// Return the unique values in this array, preserving the order of first
    /// occurrence.
    ///
    /// NA values are represented at most once in the output (if present in the
    /// input). The returned array has no duplicates.
    func unique() -> Self

    /// Return the indices that would sort this array.
    ///
    /// - Parameter ascending: If `true` (the default), sort in ascending order;
    ///   otherwise sort in descending order.
    /// - Returns: An array of indices of length ``count`` such that
    ///   `self.take(indices: result)` is sorted.
    ///
    /// NA values are conventionally placed at the end for ascending sorts and
    /// at the beginning for descending sorts, matching pandas' default
    /// ``na_position="last"`` behavior.
    func argsort(ascending: Bool) -> [Int]

    /// Fill all missing (NA) positions with the given constant value.
    ///
    /// - Parameter value: The replacement value for every NA position.
    /// - Returns: A new array of the same length with no remaining NAs.
    func fillNA(value: Element) -> Self

    /// Encode each element as an integer code referencing a table of unique values.
    ///
    /// - Returns: A tuple `(codes, uniques)` where:
    ///   - `codes` is an `[Int]` of length ``count``. Each entry is the index
    ///     into `uniques` for the corresponding element, or `-1` if the element
    ///     is NA.
    ///   - `uniques` is a new array containing only the distinct non-NA values,
    ///     in order of first occurrence.
    ///
    /// Factorization is the backbone of GroupBy: it converts arbitrary element
    /// types into dense integer labels suitable for bucket-based aggregation.
    func factorize() -> (codes: [Int], uniques: Self)
}

// MARK: - Default implementations

public extension PandasArray {
    /// Default implementation: counts the number of `false` entries in ``isNA()``.
    ///
    /// Concrete types that maintain a precomputed validity count (such as
    /// ``NullableArray``, which delegates to ``BitVector.popcount``) shadow
    /// this default with an O(1) property.
    var validCount: Int {
        isNA().filter { !$0 }.count
    }
}

/// A refinement of ``PandasArray`` for arrays whose elements support arithmetic.
///
/// ``NumericPandasArray`` constrains ``Element`` to `Numeric & Comparable` and
/// adds the three core numeric aggregations: ``sum()``, ``min()``, and
/// ``max()``. These operate only on non-NA values and return `nil` when the
/// array contains no valid elements.
///
/// Both ``NativeArray`` (for dense, non-nullable numeric data) and
/// ``NullableArray`` (for numeric data with potential NAs) conform to this
/// protocol when their element type is numeric.
///
/// ## Why a separate protocol?
///
/// Splitting numeric capabilities into their own protocol allows generic code
/// to express "I need an array I can sum" without also requiring floating-point
/// operations. This mirrors the split between pandas' integer and float dtypes.
public protocol NumericPandasArray: PandasArray where Element: Numeric & Comparable {
    /// The sum of all non-NA values.
    ///
    /// - Returns: The sum, or `nil` if the array has zero valid elements.
    ///
    /// For ``Double`` arrays, concrete types typically delegate to an
    /// Accelerate/vDSP-optimized implementation for SIMD-level throughput.
    func sum() -> Element?

    /// The minimum of all non-NA values.
    ///
    /// - Returns: The minimum value, or `nil` if the array has zero valid
    ///   elements.
    func min() -> Element?

    /// The maximum of all non-NA values.
    ///
    /// - Returns: The maximum value, or `nil` if the array has zero valid
    ///   elements.
    func max() -> Element?
}

/// A refinement of ``NumericPandasArray`` for floating-point element types,
/// enabling statistical operations that require division and square roots.
///
/// ``FloatingPointPandasArray`` adds ``mean()``, ``std(ddof:)``, and
/// ``variance(ddof:)`` -- the three core descriptive statistics that only make
/// sense for real-valued (floating-point) data. Integer arrays can be promoted
/// to ``Double`` before these operations are needed (see ``Column.asDouble()``).
///
/// ## Degrees-of-freedom correction (`ddof`)
///
/// The `ddof` parameter in ``std(ddof:)`` and ``variance(ddof:)`` mirrors
/// NumPy/pandas convention: the divisor is `N - ddof` where N is the number
/// of valid values. The default `ddof = 1` produces Bessel's correction
/// (sample variance); `ddof = 0` produces the population variance.
public protocol FloatingPointPandasArray: NumericPandasArray where Element: FloatingPoint {
    /// The arithmetic mean of all non-NA values.
    ///
    /// - Returns: The mean, or `nil` if there are no valid elements.
    func mean() -> Element?

    /// The standard deviation of all non-NA values.
    ///
    /// - Parameter ddof: Delta degrees of freedom. The divisor used in the
    ///   calculation is `N - ddof`, where N is the count of valid values.
    ///   Defaults to 1 (Bessel's correction / sample std).
    /// - Returns: The standard deviation, or `nil` if valid count <= `ddof`.
    func std(ddof: Int) -> Element?

    /// The variance of all non-NA values.
    ///
    /// - Parameter ddof: Delta degrees of freedom. The divisor used in the
    ///   calculation is `N - ddof`. Defaults to 1 (sample variance).
    /// - Returns: The variance, or `nil` if valid count <= `ddof`.
    func variance(ddof: Int) -> Element?
}
