// MARK: - Series.swift
//
// A one-dimensional labeled array — the Swift equivalent of Python's
// ``pandas.Series``.
//
// ## Storage Model
//
// A Series wraps a single ``Column`` enum value (`.double`, `.int64`,
// `.string`, `.bool`) plus an optional string index for label-based access.
// Numeric data defaults to `Double` (IEEE 754 double-precision).  Missing
// values are represented through the ``NullableArray`` validity mask (a
// ``BitVector``), not through Swift optionals at the element level, which
// enables tight SIMD/Accelerate fast paths in the "all-valid" case.
//
// ## Value Semantics & Copy-on-Write
//
// `Series` is a value type (`struct`) and conforms to `Sendable`.  The
// underlying ``NativeArray`` buffers use Swift's standard CoW mechanism:
// buffers are shared across copies until mutation, at which point the
// mutating copy gets its own storage.
//
// ## Index
//
// Like ``DataFrame``, the index is **lazily generated** for the default
// range case (`0, 1, 2, …`).  The internal `_isDefaultIndex` flag prevents
// materialising `["0", "1", …]` until explicitly needed.
//
// ## Performance Highlights
//
// * **Scalar arithmetic** — When the ``BitVector`` mask has `allValid`,
//   scalar add/sub/mul/div use ``VectorOps`` (backed by Accelerate/vDSP)
//   operating on contiguous buffers, avoiding per-element mask checks.
// * **Comparison operators** — Return `[Bool]` masks suitable for
//   ``DataFrame.filter(mask:)``; NA values always produce `false`.
// * **valueCounts** — Hash-table-based frequency counting with a parallel-
//   array sort optimisation.  When every value is unique (count == 1 for
//   all entries), the sort step is skipped entirely.
// * **median / quantile** — Use O(n) quickselect (``NativeArray.nthElement``)
//   instead of O(n log n) sorting, with a max-of-left-partition trick to
//   obtain both bracketing values for linear interpolation without a second
//   selection call.
// * **cumsum** — Has an `allValid` fast path that runs a prefix-sum with
//   raw pointers, and a slow path that skips NA positions.

/// A one-dimensional labeled array holding a single ``Column`` of typed data
/// plus an optional string index — the Swift equivalent of
/// ``pandas.Series``.
///
/// `Series` uses value semantics with copy-on-write.  Numeric data defaults
/// to `Double`; missing values are tracked by a ``BitVector`` validity mask
/// inside ``NullableArray``, not by Swift optionals.
///
/// ## Topics
///
/// ### Creating a Series
/// - ``init(_:name:)-[Double]``
/// - ``init(_:name:)-[Double?]``
/// - ``init(_:name:)-[String]``
/// - ``init(_:name:)-[String?]``
/// - ``init(_:name:)-[Int]``
/// - ``init(data:index:name:)``
/// - ``init(data:name:)``
/// - ``init(_:name:)-dict``
///
/// ### Properties
/// - ``count``
/// - ``dtype``
/// - ``isNumeric``
/// - ``validCount``
/// - ``naCount``
/// - ``index``
/// - ``doubleValues``
///
/// ### Element Access
/// - ``subscript(position:)``
/// - ``iloc(_:)-Int``
/// - ``iloc(_:)-Range``
/// - ``loc(_:)``
/// - ``head(_:)``
/// - ``tail(_:)``
///
/// ### NA Handling
/// - ``isNA()``
/// - ``dropNA()``
/// - ``fillNA(_:)``
///
/// ### Aggregation
/// - ``sum()``
/// - ``mean()``
/// - ``std(ddof:)``
/// - ``min()``
/// - ``max()``
/// - ``median()``
/// - ``quantile(_:)``
/// - ``describe()``
///
/// ### Sorting & Counting
/// - ``sortValues(ascending:)``
/// - ``valueCounts()``
///
/// ### Arithmetic & Comparison
/// - ``+``, ``-``, ``*``, ``/`` (element-wise and scalar)
/// - ``>``, ``>=``, ``<``, ``<=``
/// - ``eq(_:)``, ``ne(_:)``
/// - ``strContains(_:)``
///
/// ### Transformation
/// - ``apply(_:)``
/// - ``map(_:)-Double``
/// - ``map(_:)-String``
/// - ``cumsum()``
///
/// ### Deduplication
/// - ``unique()``
/// - ``nUnique``
/// - ``duplicated()``
/// - ``dropDuplicates()``
public struct Series: CustomStringConvertible, Sendable {
    /// The optional name of this Series, analogous to ``pandas.Series.name``.
    ///
    /// Used as a column header when the Series is inserted into a DataFrame
    /// and displayed in the ``description`` output.
    public var name: String?

    /// The underlying data column holding the typed values and validity mask.
    ///
    /// Exposed as `public` so that advanced users and sibling modules can
    /// access the raw ``Column`` enum for zero-copy operations.
    public var data: Column

    /// Row index labels, lazily materialised for default range indices.
    ///
    /// When the Series uses a default range index (`_isDefaultIndex == true`)
    /// and `_indexLabels` is empty, the getter synthesises `["0", "1", …]` on
    /// the fly.  Setting this property marks the index as user-defined.
    ///
    /// - Complexity: O(n) on first access for default indices; O(1)
    ///   thereafter.
    internal var indexLabels: [String] {
        get {
            if _isDefaultIndex && _indexLabels.isEmpty && data.count > 0 {
                return (0..<data.count).map { "\($0)" }
            }
            return _indexLabels
        }
        set {
            _indexLabels = newValue
            _isDefaultIndex = false
        }
    }
    /// Raw backing store for index labels; empty when using a default range
    /// index.
    internal var _indexLabels: [String] = []

    /// `true` when this Series uses a default zero-based range index.
    internal var _isDefaultIndex: Bool = true

    // MARK: - Initializers

    /// Creates a Series from a contiguous array of `Double` values with a
    /// default range index (`0, 1, …, N-1`).
    ///
    /// All values are considered valid (non-NA).  The underlying
    /// ``NullableArray`` mask will have `allValid == true`, enabling fast
    /// paths in arithmetic, comparison, and aggregation operations.
    ///
    /// ```swift
    /// let s = Series([1.0, 2.0, 3.0], name: "x")
    /// ```
    ///
    /// - Parameters:
    ///   - values: The `Double` values.
    ///   - name: Optional series name.
    public init(_ values: [Double], name: String? = nil) {
        self.data = .fromDoubles(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of optional `Double` values, where
    /// `nil` entries represent missing data (NA).
    ///
    /// The resulting ``NullableArray`` mask will reflect which positions are
    /// valid vs. NA.
    ///
    /// - Parameters:
    ///   - values: The `Double?` values (`nil` = NA).
    ///   - name: Optional series name.
    public init(_ values: [Double?], name: String? = nil) {
        self.data = .fromOptionalDoubles(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of `String` values with a default
    /// range index.
    ///
    /// All values are considered valid (non-NA).
    ///
    /// - Parameters:
    ///   - values: The `String` values.
    ///   - name: Optional series name.
    public init(_ values: [String], name: String? = nil) {
        self.data = .fromStrings(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of optional `String` values, where
    /// `nil` entries represent missing data (NA).
    ///
    /// - Parameters:
    ///   - values: The `String?` values (`nil` = NA).
    ///   - name: Optional series name.
    public init(_ values: [String?], name: String? = nil) {
        self.data = .fromOptionalStrings(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of `Int` values, which are converted
    /// to `Double` for storage.
    ///
    /// This convenience initializer avoids requiring callers to manually
    /// map integer literals to `Double`.  Precision loss is possible for
    /// integers outside the range exactly representable by `Double`
    /// (|value| > 2^53).
    ///
    /// - Parameters:
    ///   - values: The `Int` values (converted to `Double`).
    ///   - name: Optional series name.
    public init(_ values: [Int], name: String? = nil) {
        self.data = .fromDoubles(values.map { Double($0) })
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of `Bool` values.
    ///
    /// - Parameters:
    ///   - values: The `Bool` values.
    ///   - name: Optional series name.
    public init(_ values: [Bool], name: String? = nil) {
        self.data = .fromBools(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of optional `Bool` values, where
    /// `nil` entries represent missing data (NA).
    ///
    /// - Parameters:
    ///   - values: The `Bool?` values (`nil` = NA).
    ///   - name: Optional series name.
    public init(_ values: [Bool?], name: String? = nil) {
        self.data = .fromOptionalBools(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from an array of optional `Int` values, where
    /// `nil` entries represent missing data (NA).
    ///
    /// - Parameters:
    ///   - values: The `Int?` values (`nil` = NA).
    ///   - name: Optional series name.
    public init(_ values: [Int?], name: String? = nil) {
        self.data = .fromOptionalInts(values)
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a Series from a pre-built ``Column`` with explicit index
    /// labels, analogous to `pd.Series(data, index=index)`.
    ///
    /// A precondition verifies that `data.count == index.count`.
    ///
    /// - Parameters:
    ///   - data: The ``Column`` holding the typed data.
    ///   - index: An array of string labels, one per element.
    ///   - name: Optional series name.
    public init(data: Column, index: [String], name: String? = nil) {
        precondition(data.count == index.count, "Data and index must have same length")
        self.data = data
        self._indexLabels = index
        self._isDefaultIndex = false
        self.name = name
    }

    /// Creates a Series from a pre-built ``Column`` with a default range
    /// index (`0, 1, …, N-1`).
    ///
    /// - Parameters:
    ///   - data: The ``Column`` holding the typed data.
    ///   - name: Optional series name.
    public init(data: Column, name: String? = nil) {
        self.data = data
        self.name = name
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Internal initializer that creates a Series from a ``Column`` while
    /// explicitly preserving (or overriding) the lazy-index flag from a
    /// parent DataFrame or Series.
    ///
    /// Used by DataFrame's column subscript getter and by arithmetic /
    /// transformation methods that want to propagate the parent's index
    /// state without triggering lazy materialisation.
    ///
    /// - Parameters:
    ///   - data: The ``Column`` holding the typed data.
    ///   - defaultIndex: Whether to treat the index as a default range.
    ///   - index: The raw index labels (ignored if `defaultIndex` is `true`).
    ///   - name: Optional series name.
    internal init(data: Column, defaultIndex: Bool, index: [String], name: String? = nil) {
        self.data = data
        self._isDefaultIndex = defaultIndex
        self._indexLabels = defaultIndex ? [] : index
        self.name = name
    }

    /// Creates a Series from a `[String: Double]` dictionary, analogous to
    /// `pd.Series({"a": 1.0, "b": 2.0})`.
    ///
    /// Dictionary keys become the index labels (sorted lexicographically for
    /// deterministic order).  All values are considered valid (non-NA).
    ///
    /// - Parameters:
    ///   - dict: A dictionary mapping label strings to `Double` values.
    ///   - name: Optional series name.
    public init(_ dict: [String: Double], name: String? = nil) {
        let sorted = dict.sorted { $0.key < $1.key }
        self._indexLabels = sorted.map { $0.key }
        self._isDefaultIndex = false
        self.data = .fromDoubles(sorted.map { $0.value })
        self.name = name
    }

    // MARK: - Properties

    /// The total number of elements (including NA) in the Series.
    ///
    /// - Complexity: O(1) — delegates to ``Column.count``.
    public var count: Int { data.count }

    /// The data type of the underlying storage, expressed as a ``DTypeEnum``
    /// value (`.float64`, `.int64`, `.string`, `.bool`).
    public var dtype: DTypeEnum { data.dtype }

    /// `true` if the Series holds numeric data (`.double` or `.int64`),
    /// meaning arithmetic and aggregation operations are supported.
    public var isNumeric: Bool { data.isNumeric }

    /// The number of valid (non-NA) elements.
    ///
    /// Equivalent to `count - naCount`.  Backed by
    /// ``NullableArray.validCount`` / ``StringArray.validCount``.
    public var validCount: Int { data.validCount }

    /// The number of missing (NA) elements.
    ///
    /// Equivalent to `count - validCount`.
    public var naCount: Int { data.naCount }

    /// The index labels of this Series.
    ///
    /// Returns the lazily-generated default range labels when applicable,
    /// or the user-supplied labels otherwise.
    public var index: [String] { indexLabels }

    /// The values as an array of `Double?`, or `nil` if the Series is not
    /// numeric.
    ///
    /// Each element is `nil` where the validity mask indicates NA.  Returns
    /// `nil` (not an empty array) when the underlying column is non-numeric.
    public var doubleValues: [Double?]? {
        guard let arr = data.asDouble() else { return nil }
        return (0..<arr.count).map { arr[$0] }
    }

    // MARK: - Access by Position

    /// Accesses the value at the given integer position.
    ///
    /// Returns the typed value (`Double`, `String`, `Int64`, `Bool`) or `nil`
    /// if the position holds an NA.  No bounds checking beyond what the
    /// underlying ``Column`` performs.
    ///
    /// - Parameter position: Zero-based element index.
    public subscript(position: Int) -> Any? {
        data.value(at: position)
    }

    /// Integer-location based indexing, analogous to ``pandas.Series.iloc``.
    ///
    /// Triggers a precondition failure if `position` is out of bounds.
    ///
    /// - Parameter position: Zero-based element index.
    /// - Returns: The typed value at `position`, or `nil` for NA.
    public func iloc(_ position: Int) -> Any? {
        precondition(position >= 0 && position < count, "Position \(position) out of range")
        return data.value(at: position)
    }

    /// Integer-location based slicing, analogous to
    /// ``pandas.Series.iloc[start:stop]``.
    ///
    /// Returns a new Series containing the elements at the positions in
    /// `range`.  The resulting Series inherits the receiver's index type
    /// (default or custom) and gathers the corresponding labels.
    ///
    /// - Parameter range: A half-open `Range<Int>` of positions.
    /// - Returns: A sliced ``Series``.
    public func iloc(_ range: Range<Int>) -> Series {
        let indices = Array(range)
        if _isDefaultIndex {
            return Series(data: data.take(indices: indices), name: name)
        }
        return Series(
            data: data.take(indices: indices),
            index: indices.map { _indexLabels[$0] },
            name: name
        )
    }

    // MARK: - Access by Label

    /// Label-based indexing, analogous to ``pandas.Series.loc``.
    ///
    /// Performs a linear scan of ``indexLabels`` for the first occurrence of
    /// `label`.  Returns `nil` if the label is not found; otherwise returns
    /// the typed value (or `nil` for NA) at the matching position.
    ///
    /// - Parameter label: The string index label to look up.
    /// - Returns: The value at the matching position, or `nil` if not found
    ///   or the value is NA.
    public func loc(_ label: String) -> Any? {
        guard let pos = indexLabels.firstIndex(of: label) else { return nil }
        return data.value(at: pos)
    }

    // MARK: - Head / Tail

    /// Returns the first `n` elements of the Series (default 5), analogous
    /// to ``pandas.Series.head()``.
    ///
    /// If `n` exceeds ``count``, the entire Series is returned.
    ///
    /// - Parameter n: Number of elements to return (default `5`).
    public func head(_ n: Int = 5) -> Series {
        let end = Swift.min(n, count)
        return iloc(0..<end)
    }

    /// Returns the last `n` elements of the Series (default 5), analogous to
    /// ``pandas.Series.tail()``.
    ///
    /// If `n` exceeds ``count``, the entire Series is returned.
    ///
    /// - Parameter n: Number of elements to return (default `5`).
    public func tail(_ n: Int = 5) -> Series {
        let start = Swift.max(0, count - n)
        return iloc(start..<count)
    }

    // MARK: - NA Handling

    /// Returns a `[Bool]` mask that is `true` at each position where the
    /// value is NA, analogous to ``pandas.Series.isna()``.
    ///
    /// - Returns: A boolean array of length ``count``.
    public func isNA() -> [Bool] { data.isNA() }

    /// Returns a new Series with all NA values removed, analogous to
    /// ``pandas.Series.dropna()``.
    ///
    /// Valid-only positions are gathered via ``Column.take(indices:)``.
    /// The resulting Series inherits the appropriate index labels (custom
    /// labels are gathered; default indices get a fresh range).
    ///
    /// - Returns: A ``Series`` containing only non-NA elements.
    public func dropNA() -> Series {
        let mask = data.isNA()
        let validIndices = mask.enumerated().compactMap { !$1 ? $0 : nil }
        if _isDefaultIndex {
            return Series(data: data.take(indices: validIndices), name: name)
        }
        return Series(
            data: data.take(indices: validIndices),
            index: validIndices.map { _indexLabels[$0] },
            name: name
        )
    }

    /// Returns a new Series with all NA values replaced by `value`,
    /// analogous to ``pandas.Series.fillna(value)``.
    ///
    /// Only operates on `.double` columns; non-numeric Series are returned
    /// unchanged.  Delegates to ``NullableArray.fillNANullable(value:)``
    /// which produces a new array with the mask updated to all-valid at
    /// previously-NA positions.
    ///
    /// - Parameter value: The `Double` constant to substitute for NA.
    /// - Returns: A new ``Series`` with NAs filled.
    public func fillNA(_ value: Double) -> Series {
        guard case .double(let arr) = data else { return self }
        return Series(
            data: .double(arr.fillNANullable(value: value)),
            defaultIndex: _isDefaultIndex,
            index: _indexLabels,
            name: name
        )
    }

    // MARK: - Aggregations

    /// Returns the sum of all valid (non-NA) numeric values, or `nil` if
    /// the Series is non-numeric.
    ///
    /// Delegates to ``Column.sum()`` which uses Accelerate/vDSP when the
    /// mask is all-valid.
    public func sum() -> Double? { data.sum() }

    /// Returns the arithmetic mean of all valid (non-NA) numeric values, or
    /// `nil` if the Series is non-numeric.
    ///
    /// Computed as `sum / validCount`.  Returns `nil` when there are no
    /// valid values.
    public func mean() -> Double? { data.mean() }

    /// Returns the sample standard deviation of all valid (non-NA) numeric
    /// values, or `nil` if the Series is non-numeric.
    ///
    /// Uses `ddof` (delta degrees of freedom) in the denominator
    /// (`N - ddof`), defaulting to `1` for Bessel's correction (matching
    /// pandas' default).
    ///
    /// - Parameter ddof: Delta degrees of freedom (default `1`).
    public func std(ddof: Int = 1) -> Double? { data.std(ddof: ddof) }

    /// Returns the minimum valid (non-NA) numeric value, or `nil` if the
    /// Series is non-numeric or has no valid values.
    public func min() -> Double? { data.min() }

    /// Returns the maximum valid (non-NA) numeric value, or `nil` if the
    /// Series is non-numeric or has no valid values.
    public func max() -> Double? { data.max() }

    // MARK: - Sorting

    /// Returns a new Series sorted by its values, analogous to
    /// ``pandas.Series.sort_values()``.
    ///
    /// For `.double` columns, valid (non-NA) values are sorted first and NA
    /// values are appended at the end (matching pandas' default
    /// `na_position="last"`).  The sort indices for valid elements are
    /// obtained via ``NativeArray.argsort(ascending:)`` on the NA-dropped
    /// sub-array, then mapped back to original positions.
    ///
    /// For `.string` columns, ``StringArray.argsort(ascending:)`` is used
    /// directly (NA strings sort to the end).
    ///
    /// - Parameter ascending: Sort order; `true` (default) for ascending.
    /// - Returns: A new sorted ``Series`` with index labels gathered
    ///   accordingly.
    public func sortValues(ascending: Bool = true) -> Series {
        let indices: [Int]
        switch data {
        case .double(let a):
            let dropNAData = a.dropNA()
            let sortedIndices = dropNAData.argsort(ascending: ascending)
            // Map back to original indices accounting for NAs
            var validPositions = [Int]()
            var naPositions = [Int]()
            for i in 0..<a.count {
                if a.mask[i] {
                    validPositions.append(i)
                } else {
                    naPositions.append(i)
                }
            }
            indices = sortedIndices.map { validPositions[$0] } + naPositions
        case .string(let a):
            indices = a.argsort(ascending: ascending)
        default:
            return self
        }
        if _isDefaultIndex {
            return Series(data: data.take(indices: indices), name: name)
        }
        return Series(
            data: data.take(indices: indices),
            index: indices.map { _indexLabels[$0] },
            name: name
        )
    }

    // MARK: - Value Counts

    /// Counts the occurrences of each unique value, returning a new Series
    /// indexed by the unique values and sorted by frequency (descending),
    /// analogous to ``pandas.Series.value_counts()``.
    ///
    /// ## Algorithm
    ///
    /// 1. **Build frequency table** — A `[KeyType: Int]` dictionary is
    ///    populated in a single pass.  For `.double` columns, the raw
    ///    `UnsafeBufferPointer` is iterated directly; when `allValid` the
    ///    mask check is skipped entirely.
    ///
    /// 2. **Extract into parallel arrays** — Keys and counts are copied into
    ///    separate `ContiguousArray` buffers.  This avoids tuple-copy
    ///    overhead during the subsequent sort step.
    ///
    /// 3. **Skip-sort optimisation** — If every count is `1` (i.e. the
    ///    number of unique values equals the number of valid values), every
    ///    entry has the same frequency and sorting is unnecessary.  This
    ///    "all-unique" case is detected with a simple `n != a.validCount`
    ///    check and the sort is skipped, saving O(n log n) work.
    ///
    /// 4. **Sort by count (descending)** — When counts are not uniform, an
    ///    indirect sort (`order.sort { cts[$0] > cts[$1] }`) is used so
    ///    that the key and count arrays are reordered via a single
    ///    permutation pass.
    ///
    /// NA values are excluded from the result.
    ///
    /// - Returns: A ``Series`` whose index labels are the stringified unique
    ///   values and whose data values are the corresponding counts (as
    ///   `Double`).
    public func valueCounts() -> Series {
        switch data {
        case .double(let a):
            // Build frequency table
            var counts = [Double: Int](minimumCapacity: Swift.min(a.count, 1_000_000))
            a.data.withUnsafeBufferPointer { src in
                if a.mask.allValid {
                    for i in 0..<src.count {
                        counts[src[i], default: 0] += 1
                    }
                } else {
                    for i in 0..<src.count where a.mask[i] {
                        counts[src[i], default: 0] += 1
                    }
                }
            }
            let n = counts.count
            // Extract into parallel arrays (avoids tuple copies during sort)
            var keys = ContiguousArray<Double>(repeating: 0, count: n)
            var cts = ContiguousArray<Int>(repeating: 0, count: n)
            var ki = 0
            for (k, v) in counts {
                keys[ki] = k
                cts[ki] = v
                ki += 1
            }
            // Check if sort is needed (all-unique case: every count is 1)
            let needsSort = n != a.validCount
            // Build result — sort by count descending only when needed
            var values = ContiguousArray<Double>(repeating: 0, count: n)
            var labels = [String]()
            labels.reserveCapacity(n)
            if needsSort {
                var order = Array(0..<n)
                order.sort { cts[$0] > cts[$1] }
                for i in 0..<n {
                    let j = order[i]
                    values[i] = Double(cts[j])
                    labels.append(String(keys[j]))
                }
            } else {
                for i in 0..<n {
                    values[i] = 1.0
                    labels.append(String(keys[i]))
                }
            }
            return Series(
                data: .double(NullableArray(data: NativeArray(values), mask: BitVector(repeating: true, count: n))),
                index: labels,
                name: name
            )
        case .string(let a):
            var counts = [String: Int](minimumCapacity: Swift.min(a.count, 1_000_000))
            a.storage.withContiguousStorageIfAvailable { buf in
                for i in 0..<buf.count {
                    if let s = buf[i] {
                        counts[s, default: 0] += 1
                    }
                }
            }
            let sortedPairs = counts.sorted { $0.value > $1.value }
            let n = sortedPairs.count
            var values = ContiguousArray<Double>(repeating: 0, count: n)
            var labels = [String]()
            labels.reserveCapacity(n)
            for i in 0..<n {
                values[i] = Double(sortedPairs[i].value)
                labels.append(sortedPairs[i].key)
            }
            return Series(
                data: .double(NullableArray(data: NativeArray(values), mask: BitVector(repeating: true, count: n))),
                index: labels,
                name: name
            )
        default:
            return self
        }
    }

    // MARK: - Element-wise Arithmetic (Double Series Only)

    /// Element-wise addition of two numeric Series.
    ///
    /// Both operands must be `.double` columns; a fatal error is raised
    /// otherwise.  The result inherits the left-hand side's index.
    /// Delegates to ``NullableArray.+`` which handles mask propagation
    /// (if either operand is NA at a position, the result is NA there).
    public static func + (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la + ra), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    /// Element-wise subtraction of two numeric Series.
    ///
    /// Both operands must be `.double` columns.  NA propagation and index
    /// inheritance follow the same rules as ``+``.
    public static func - (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la - ra), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    /// Element-wise multiplication of two numeric Series.
    ///
    /// Both operands must be `.double` columns.  NA propagation and index
    /// inheritance follow the same rules as ``+``.
    public static func * (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la * ra), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    /// Element-wise division of two numeric Series.
    ///
    /// Both operands must be `.double` columns.  NA propagation and index
    /// inheritance follow the same rules as ``+``.  Division by zero
    /// produces `+/-inf` or `NaN` per IEEE 754 semantics.
    public static func / (lhs: Series, rhs: Series) -> Series {
        guard case .double(let la) = lhs.data, case .double(let ra) = rhs.data else {
            fatalError("Arithmetic only supported on numeric Series")
        }
        return Series(data: .double(la / ra), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    // MARK: - Scalar Arithmetic
    //
    // Each scalar arithmetic operator has two code paths:
    //
    // 1. **allValid fast path** — When the mask has `allValid == true`, the
    //    operation is performed via ``VectorOps`` (backed by Accelerate/vDSP
    //    where available), operating on contiguous `UnsafeBufferPointer`
    //    input and `UnsafeMutableBufferPointer` output.  This avoids
    //    per-element mask checks and enables SIMD auto-vectorisation.
    //
    // 2. **NA-aware slow path** — When NA values exist, the underlying
    //    ``NullableArray`` is copied and only valid positions are mutated
    //    element-by-element.
    //
    // The result always inherits the left-hand operand's index and name.

    /// Adds a scalar `Double` to every valid element of a numeric Series.
    ///
    /// Uses Accelerate/vDSP via ``VectorOps.scalarAdd`` when the mask is
    /// all-valid; falls back to per-element mutation otherwise.  Non-numeric
    /// Series are returned unchanged.
    public static func + (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            let n = a.count
            let resultData = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                a.data.withUnsafeBufferPointer { src in
                    VectorOps.scalarAdd(src, rhs, result: buf)
                }
                count = n
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] + rhs
        }
        return Series(data: .double(result), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    /// Subtracts a scalar `Double` from every valid element of a numeric
    /// Series.
    ///
    /// Uses Accelerate/vDSP via ``VectorOps.scalarSubtract`` when all-valid;
    /// falls back to per-element mutation otherwise.
    public static func - (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            let n = a.count
            let resultData = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                a.data.withUnsafeBufferPointer { src in
                    VectorOps.scalarSubtract(src, rhs, result: buf)
                }
                count = n
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] - rhs
        }
        return Series(data: .double(result), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    /// Multiplies every valid element of a numeric Series by a scalar
    /// `Double`.
    ///
    /// Uses Accelerate/vDSP via ``VectorOps.scalarMultiply`` when all-valid;
    /// falls back to per-element mutation otherwise.
    public static func * (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            let n = a.count
            let resultData = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                a.data.withUnsafeBufferPointer { src in
                    VectorOps.scalarMultiply(src, rhs, result: buf)
                }
                count = n
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] * rhs
        }
        return Series(data: .double(result), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    /// Divides every valid element of a numeric Series by a scalar `Double`.
    ///
    /// Uses Accelerate/vDSP via ``VectorOps.scalarDivide`` when all-valid;
    /// falls back to per-element mutation otherwise.  Division by zero
    /// follows IEEE 754 semantics.
    public static func / (lhs: Series, rhs: Double) -> Series {
        guard case .double(let a) = lhs.data else { return lhs }
        if a.mask.allValid {
            let n = a.count
            let resultData = ContiguousArray<Double>(unsafeUninitializedCapacity: n) { buf, count in
                a.data.withUnsafeBufferPointer { src in
                    VectorOps.scalarDivide(src, rhs, result: buf)
                }
                count = n
            }
            return Series(data: .double(NullableArray(NativeArray(resultData))), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
        }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = result.data[i] / rhs
        }
        return Series(data: .double(result), defaultIndex: lhs._isDefaultIndex, index: lhs._indexLabels, name: lhs.name)
    }

    // MARK: - Comparison Operators
    //
    // All comparison operators return `[Bool]` masks suitable for use with
    // ``DataFrame.filter(mask:)`` or ``DataFrame.subscript(mask:)``.
    //
    // NA values always produce `false` in the result mask — this matches
    // pandas' three-valued logic where comparisons involving NA are falsy.
    //
    // Each operator has an `allValid` fast path that skips mask checks,
    // iterating over the raw `UnsafeBufferPointer` directly.

    /// Element-wise greater-than comparison against a scalar `Double`.
    ///
    /// NA values produce `false`.  Non-numeric Series return an all-`false`
    /// mask.
    ///
    /// - Returns: A `[Bool]` mask of length ``count``.
    public static func > (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] > rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] > rhs }
            }
        }
        return result
    }

    /// Element-wise greater-than-or-equal comparison against a scalar
    /// `Double`.  NA values produce `false`.
    public static func >= (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] >= rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] >= rhs }
            }
        }
        return result
    }

    /// Element-wise less-than comparison against a scalar `Double`.  NA
    /// values produce `false`.
    public static func < (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] < rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] < rhs }
            }
        }
        return result
    }

    /// Element-wise less-than-or-equal comparison against a scalar `Double`.
    /// NA values produce `false`.
    public static func <= (lhs: Series, rhs: Double) -> [Bool] {
        guard case .double(let a) = lhs.data else { return [Bool](repeating: false, count: lhs.count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] <= rhs }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] <= rhs }
            }
        }
        return result
    }

    /// Element-wise equality test against a scalar `Double`.
    ///
    /// NA values produce `false`.  Uses an `allValid` fast path when no NAs
    /// are present.  Named `eq` instead of overloading `==` to avoid
    /// ambiguity with `Equatable` conformance.
    ///
    /// - Parameter value: The `Double` value to compare against.
    /// - Returns: A `[Bool]` mask of length ``count``.
    public func eq(_ value: Double) -> [Bool] {
        guard case .double(let a) = data else { return [Bool](repeating: false, count: count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] == value }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] == value }
            }
        }
        return result
    }

    /// Element-wise inequality test against a scalar `Double`.
    ///
    /// NA values produce `false`.  This is the logical complement of
    /// ``eq(_:)-Double`` **except** at NA positions (where both return
    /// `false`).
    ///
    /// - Parameter value: The `Double` value to compare against.
    /// - Returns: A `[Bool]` mask of length ``count``.
    public func ne(_ value: Double) -> [Bool] {
        guard case .double(let a) = data else { return [Bool](repeating: false, count: count) }
        let n = a.count
        var result = [Bool](repeating: false, count: n)
        a.data.withUnsafeBufferPointer { buf in
            if a.mask.allValid {
                for i in 0..<n { result[i] = buf[i] != value }
            } else {
                for i in 0..<n { result[i] = a.mask[i] && buf[i] != value }
            }
        }
        return result
    }

    /// Element-wise string equality test.
    ///
    /// NA values produce `false`.  Only operates on `.string` columns;
    /// non-string Series return an all-`false` mask.
    ///
    /// - Parameter value: The `String` to compare against.
    /// - Returns: A `[Bool]` mask of length ``count``.
    public func eq(_ value: String) -> [Bool] {
        guard case .string(let a) = data else { return [Bool](repeating: false, count: count) }
        return a.storage.map { $0 == value }
    }

    /// Element-wise string inequality test.
    ///
    /// NA values produce `false`.  Only operates on `.string` columns.
    ///
    /// - Parameter value: The `String` to compare against.
    /// - Returns: A `[Bool]` mask of length ``count``.
    public func ne(_ value: String) -> [Bool] {
        guard case .string(let a) = data else { return [Bool](repeating: false, count: count) }
        return a.storage.map { $0 != nil && $0 != value }
    }

    /// Element-wise substring containment check, analogous to
    /// ``pandas.Series.str.contains()``.
    ///
    /// Returns `true` at positions where the string value contains
    /// `substring`.  NA values produce `false`.  Non-string Series return
    /// an all-`false` mask.
    ///
    /// - Parameter substring: The substring to search for.
    /// - Returns: A `[Bool]` mask of length ``count``.
    public func strContains(_ substring: String) -> [Bool] {
        guard case .string(let a) = data else { return [Bool](repeating: false, count: count) }
        return a.storage.map { $0?.contains(substring) ?? false }
    }

    // MARK: - Apply / Map

    /// Applies a transformation closure to each valid (non-NA) numeric
    /// element, returning a new Series with the same index, analogous to
    /// ``pandas.Series.apply(func)``.
    ///
    /// NA positions are preserved (not passed to the closure).  Non-numeric
    /// Series are returned unchanged.
    ///
    /// - Parameter transform: A `(Double) -> Double` closure.
    /// - Returns: A transformed ``Series``.
    public func apply(_ transform: (Double) -> Double) -> Series {
        guard case .double(let a) = data else { return self }
        var result = a.copy()
        for i in 0..<result.count where result.mask[i] {
            result.data[i] = transform(result.data[i])
        }
        return Series(data: .double(result), defaultIndex: _isDefaultIndex, index: _indexLabels, name: name)
    }

    /// Maps numeric values through a lookup dictionary, analogous to
    /// ``pandas.Series.map(dict)``.
    ///
    /// Values present as keys in `mapping` are replaced with the
    /// corresponding value; values not found (and existing NAs) become NA
    /// in the result.  The result uses a default range index.
    ///
    /// - Parameter mapping: A `[Double: Double]` lookup table.
    /// - Returns: A new ``Series`` with mapped values.
    public func map(_ mapping: [Double: Double]) -> Series {
        guard case .double(let a) = data else { return self }
        var values = [Double?]()
        values.reserveCapacity(a.count)
        for i in 0..<a.count {
            if a.mask[i], let mapped = mapping[a.data[i]] {
                values.append(mapped)
            } else {
                values.append(nil)
            }
        }
        return Series(values, name: name)
    }

    /// Maps string values through a lookup dictionary, analogous to
    /// ``pandas.Series.map(dict)`` for string data.
    ///
    /// Values present as keys in `mapping` are replaced; unmapped values
    /// and existing NAs become NA.  The result uses a default range index.
    ///
    /// - Parameter mapping: A `[String: String]` lookup table.
    /// - Returns: A new ``Series`` with mapped values.
    public func map(_ mapping: [String: String]) -> Series {
        guard case .string(let a) = data else { return self }
        let mapped: [String?] = a.storage.map { s in
            guard let s = s, let v = mapping[s] else { return nil }
            return v
        }
        return Series(mapped, name: name)
    }

    // MARK: - Cumulative Operations

    /// Returns the cumulative sum of the Series, analogous to
    /// ``pandas.Series.cumsum(skipna=True)``.
    ///
    /// NA values are **skipped** (not propagated) — the running total
    /// continues from the last valid value, and NA positions in the result
    /// retain their NA status.
    ///
    /// ## Performance
    ///
    /// - **allValid fast path** — When no NAs exist, a prefix-sum is
    ///   computed using raw pointers (`UnsafeBufferPointer` input,
    ///   `UnsafeMutableBufferPointer` output) in a single forward pass.
    ///   This avoids per-element mask checks and enables optimal
    ///   auto-vectorisation.
    /// - **NA-aware slow path** — When NAs are present, the loop checks
    ///   the mask at each position and skips NA elements while preserving
    ///   the running sum for subsequent valid elements.
    ///
    /// - Returns: A new ``Series`` of the same length with cumulative sums
    ///   (NA positions remain NA).
    public func cumsum() -> Series {
        guard case .double(let a) = data else { return self }
        let n = a.count
        // Build result using raw pointer accumulation + reuse existing index
        let resultData: NullableArray<Double>
        if a.mask.allValid {
            // Fast path: no NAs — prefix sum with raw pointers
            var result = ContiguousArray<Double>(repeating: 0, count: n)
            a.data.withUnsafeBufferPointer { src in
                result.withUnsafeMutableBufferPointer { dst in
                    var running = 0.0
                    for i in 0..<n {
                        running += src[i]
                        dst[i] = running
                    }
                }
            }
            resultData = NullableArray(data: NativeArray(result), mask: a.mask)
        } else {
            // Slow path: skip NAs
            var result = ContiguousArray<Double>(repeating: 0, count: n)
            a.data.withUnsafeBufferPointer { src in
                result.withUnsafeMutableBufferPointer { dst in
                    var running = 0.0
                    for i in 0..<n {
                        if a.mask[i] {
                            running += src[i]
                            dst[i] = running
                        }
                    }
                }
            }
            resultData = NullableArray(data: NativeArray(result), mask: a.mask)
        }
        return Series(data: .double(resultData), defaultIndex: _isDefaultIndex, index: _indexLabels, name: name)
    }

    // MARK: - Additional Aggregations

    /// Returns the median of the valid (non-NA) numeric values, or `nil` if
    /// the Series is non-numeric or empty.
    ///
    /// ## Algorithm — O(n) Quickselect
    ///
    /// Instead of sorting the data (O(n log n)), this method uses
    /// ``NativeArray.nthElement(_:)`` — an in-place quickselect — to find the
    /// middle element in O(n) expected time.
    ///
    /// For even-length data, the median is the average of the two middle
    /// elements.  After `nthElement(mid)`, all elements in `[0..<mid]` are
    /// guaranteed to be less-than-or-equal to `arr[mid]`.  The lower median
    /// is therefore the **maximum** of the left partition, obtained via
    /// ``VectorOps.max`` on `buf[0..<mid]` — this avoids a second
    /// quickselect call.
    ///
    /// An `allValid` fast path skips the ``NullableArray.dropNA()`` copy
    /// when no NAs exist.
    ///
    /// - Returns: The median as `Double`, or `nil`.
    public func median() -> Double? {
        guard case .double(let a) = data else { return nil }
        // Fast-path: skip dropNA() when no NAs exist
        var arr: NativeArray<Double>
        if a.mask.allValid {
            arr = a.data.copy()
        } else {
            arr = a.dropNA()
        }
        let n = arr.count
        guard n > 0 else { return nil }
        let mid = n / 2
        arr.nthElement(mid)
        if n % 2 == 0 {
            let upper = arr[mid]
            // After nthElement(mid), elements [0..mid-1] are all ≤ arr[mid].
            // Max of left partition gives lower median — avoids second quickselect.
            let lower = arr.withUnsafeBufferPointer { buf in
                VectorOps.max(UnsafeBufferPointer(rebasing: buf[0..<mid]))
            }
            return (lower + upper) / 2.0
        }
        return arr[mid]
    }

    /// Returns the `q`-th quantile (0.0 to 1.0) of the valid numeric values
    /// using linear interpolation, analogous to
    /// ``pandas.Series.quantile(q, interpolation='linear')``.
    ///
    /// ## Algorithm — O(n) Selection with Linear Interpolation
    ///
    /// The target quantile position `pos = q * (N - 1)` generally falls
    /// between two integer ranks `lower` and `upper`.  A single
    /// ``NativeArray.nthElement(upper)`` call partitions the array such that
    /// `arr[upper]` holds the correct value and all elements in `[0..<upper]`
    /// are less-than-or-equal.  The `lower` value is then found as the
    /// maximum of the left partition via ``VectorOps.max``, avoiding a
    /// second quickselect.  The final result is linearly interpolated:
    /// `lowerVal + frac * (upperVal - lowerVal)`.
    ///
    /// An `allValid` fast path skips the dropNA copy when no NAs exist.
    ///
    /// - Parameter q: Quantile in `[0.0, 1.0]`.  A precondition failure is
    ///   triggered if `q` is out of range.
    /// - Returns: The interpolated quantile as `Double`, or `nil` if the
    ///   Series is non-numeric or has no valid values.
    public func quantile(_ q: Double) -> Double? {
        precondition(q >= 0.0 && q <= 1.0, "Quantile must be between 0 and 1")
        guard case .double(let a) = data else { return nil }
        var arr: NativeArray<Double>
        if a.mask.allValid {
            arr = a.data.copy()
        } else {
            arr = a.dropNA()
        }
        guard arr.count > 0 else { return nil }
        if arr.count == 1 { return arr[0] }
        let pos = q * Double(arr.count - 1)
        let lower = Int(pos)
        let upper = Swift.min(lower + 1, arr.count - 1)
        let frac = pos - Double(lower)
        if lower == upper {
            arr.nthElement(lower)
            return arr[lower]
        }
        arr.nthElement(upper)
        let upperVal = arr[upper]
        // After nthElement(upper), elements [0..upper-1] are ≤ arr[upper].
        // Max of left partition gives arr[lower] without second quickselect.
        let lowerVal = arr.withUnsafeBufferPointer { buf in
            VectorOps.max(UnsafeBufferPointer(rebasing: buf[0..<upper]))
        }
        return lowerVal + frac * (upperVal - lowerVal)
    }

    // MARK: - Unique / Duplicated

    /// Returns the unique values as a new Series (preserving first-seen
    /// order), analogous to ``pandas.Series.unique()``.
    ///
    /// Delegates to ``NullableArray.unique()`` / ``StringArray.unique()``
    /// which use hash-set-based deduplication.  The result has a default
    /// range index.
    ///
    /// - Returns: A ``Series`` of unique values.
    public func unique() -> Series {
        switch data {
        case .double(let a):
            let u = a.unique()
            return Series(data: .double(u), name: name)
        case .string(let a):
            let u = a.unique()
            return Series(data: .string(u), name: name)
        default:
            return self
        }
    }

    /// The number of unique non-NA values, analogous to
    /// ``pandas.Series.nunique()``.
    ///
    /// Computed by calling ``unique()`` and then counting valid elements,
    /// so the cost is O(n) time and O(unique count) space.
    public var nUnique: Int {
        switch data {
        case .double(let a): return a.unique().validCount
        case .string(let a): return a.unique().validCount
        default: return 0
        }
    }

    /// Returns a `[Bool]` mask that is `true` at positions where the value
    /// has already appeared earlier in the Series, analogous to
    /// ``pandas.Series.duplicated(keep='first')``.
    ///
    /// Uses a `Set` for O(1) amortised membership testing.  NA values are
    /// never considered duplicates (they always return `false`).
    ///
    /// - Returns: A `[Bool]` array of length ``count``.
    public func duplicated() -> [Bool] {
        switch data {
        case .double(let a):
            var seen = Set<Double>()
            return (0..<a.count).map { i in
                guard a.mask[i] else { return false }
                return !seen.insert(a.data[i]).inserted
            }
        case .string(let a):
            var seen = Set<String>()
            return a.storage.map { s in
                guard let s = s else { return false }
                return !seen.insert(s).inserted
            }
        default:
            return [Bool](repeating: false, count: count)
        }
    }

    /// Returns a new Series with duplicate values removed, keeping the first
    /// occurrence, analogous to ``pandas.Series.drop_duplicates(keep='first')``.
    ///
    /// Index labels are gathered for the kept positions.
    ///
    /// - Returns: A deduplicated ``Series``.
    public func dropDuplicates() -> Series {
        let dupes = duplicated()
        let keepIndices = dupes.enumerated().compactMap { !$1 ? $0 : nil }
        if _isDefaultIndex {
            return Series(data: data.take(indices: keepIndices), name: name)
        }
        return Series(
            data: data.take(indices: keepIndices),
            index: keepIndices.map { _indexLabels[$0] },
            name: name
        )
    }

    // MARK: - Description (CustomStringConvertible)

    /// A human-readable string representation of the Series, used by
    /// `print(series)` and string interpolation.
    ///
    /// Displays up to 20 elements with index labels left-aligned and numeric
    /// values right-aligned.  A metadata footer shows the series name (if
    /// any), dtype, and total length.
    public var description: String {
        var lines = [String]()
        let maxDisplay = Swift.min(count, 20)
        let maxLabelWidth = Swift.max(indexLabels.prefix(maxDisplay).map { $0.count }.max() ?? 0, 1)

        // Calculate value width for right-aligning numeric values
        let maxValueWidth = (0..<maxDisplay).map { data.formattedValue(at: $0).count }.max() ?? 0

        for i in 0..<maxDisplay {
            let label = indexLabels[i].padding(toLength: maxLabelWidth, withPad: " ", startingAt: 0)
            let value = data.formattedValue(at: i)
            let aligned = isNumeric
                ? String(repeating: " ", count: Swift.max(0, maxValueWidth - value.count)) + value
                : value
            lines.append("\(label)  \(aligned)")
        }

        if count > maxDisplay {
            lines.append("... (\(count) rows)")
        }

        var meta = "dtype: \(dtype)"
        if let name = name {
            meta = "Name: \(name), " + meta
        }
        meta += ", length: \(count)"
        lines.append(meta)

        return lines.joined(separator: "\n")
    }

    // MARK: - Describe

    /// Generates descriptive statistics for the Series, analogous to
    /// ``pandas.Series.describe()``.
    ///
    /// For numeric Series, returns a new Series indexed by
    /// `["count", "mean", "std", "min", "25%", "50%", "75%", "max"]`.
    /// The 25th, 50th, and 75th percentiles are computed via
    /// ``quantile(_:)`` and ``median()`` (both O(n) quickselect).
    ///
    /// For non-numeric Series, returns `["count", "non-null"]` only.
    ///
    /// - Returns: A ``Series`` of descriptive statistics.
    public func describe() -> Series {
        guard let doubles = data.asDouble() else {
            return Series(
                data: .fromDoubles([Double(count), Double(validCount)]),
                index: ["count", "non-null"],
                name: name
            )
        }
        let stats: [(String, Double)] = [
            ("count", Double(doubles.validCount)),
            ("mean", doubles.mean() ?? .nan),
            ("std", doubles.std(ddof: 1) ?? .nan),
            ("min", doubles.min() ?? .nan),
            ("25%", quantile(0.25) ?? .nan),
            ("50%", median() ?? .nan),
            ("75%", quantile(0.75) ?? .nan),
            ("max", doubles.max() ?? .nan),
        ]
        return Series(
            data: .fromDoubles(stats.map { $0.1 }),
            index: stats.map { $0.0 },
            name: name
        )
    }
}

// MARK: - Equatable

extension Series: Equatable {
    /// Two Series are equal if they have the same name and identical column data.
    ///
    /// Index labels are not compared, matching pandas value-based equality
    /// semantics. To compare indexes, check `lhs.indexLabels == rhs.indexLabels`
    /// separately.
    public static func == (lhs: Series, rhs: Series) -> Bool {
        lhs.name == rhs.name && lhs.data == rhs.data
    }
}

// MARK: - Sequence

extension Series: Sequence {
    /// An iterator that yields each element of a Series as `Any?`.
    ///
    /// Double and Int64 values are returned as their native types. String values
    /// are returned as `String?`. NA positions yield `nil`.
    ///
    /// - Note: Iteration is O(n) and intended for interop with Swift stdlib
    ///   patterns (`for value in series`, `series.map { ... }`). For
    ///   performance-critical numeric work, use ``doubleValues`` or access the
    ///   underlying ``data`` column directly.
    public struct SeriesIterator: IteratorProtocol {
        private let series: Series
        private var position: Int = 0

        init(_ series: Series) { self.series = series }

        public mutating func next() -> Any?? {
            guard position < series.count else { return nil }
            let value = series.data.value(at: position)
            position += 1
            return value
        }
    }

    public func makeIterator() -> SeriesIterator {
        SeriesIterator(self)
    }
}
