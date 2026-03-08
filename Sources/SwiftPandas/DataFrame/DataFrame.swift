// MARK: - DataFrame.swift
//
// The central 2D labeled tabular data structure in SwiftPandas, designed as a
// Swift-native equivalent of Python's ``pandas.DataFrame``.
//
// ## Storage Model
//
// Data is stored in **column-oriented** format: each column is an independent
// ``Column`` enum value (`.double`, `.int64`, `.string`, `.bool`), keyed by
// name in an internal `[String: Column]` dictionary.  Column order is
// maintained separately in the `columnNames` array so that iteration and
// display honour insertion order.
//
// Numeric data defaults to `Double` (IEEE 754 double-precision).  Missing
// values are represented at the column level through ``NullableArray`` and its
// companion ``BitVector`` validity mask — **not** through optional Swift types
// at the row level — which enables tight, branchless SIMD loops in the
// common "all-valid" fast path.
//
// ## Value Semantics & Copy-on-Write (CoW)
//
// `DataFrame` is a value type (`struct`) and conforms to `Sendable`.  The
// underlying ``NativeArray`` buffers use Swift's standard CoW mechanism:
// buffers are shared across copies until a mutation occurs, at which point
// the mutating copy gets its own storage.  This makes passing DataFrames by
// value essentially free when no mutation follows.
//
// ## Index
//
// Every DataFrame has an index — an ordered array of string labels, one per
// row.  To avoid the cost of materialising `["0", "1", …, "N-1"]` for the
// overwhelmingly common case of a default range index, the index is
// **lazily generated**: an internal `_isDefaultIndex` flag is kept, and the
// `indexLabels` computed property only allocates the string array when
// explicitly accessed.  Operations that produce a new DataFrame (filter,
// sort, merge, …) propagate the lazy-index flag whenever possible.
//
// ## Performance Design Notes
//
// * **Sorting** — Single-column ``sortValues(by:ascending:)`` has an
//   `allValid` fast path that skips NA-checking.  Multi-column sorting
//   pre-extracts column data into a ``SortKey`` enum before the comparator
//   runs, eliminating per-comparison dictionary lookups and enum dispatch.
// * **GroupBy** — Uses a factorize-then-accumulate strategy.  Group columns
//   are integer-coded once in `init`; aggregation loops use raw-pointer
//   accumulators (`UnsafeMutablePointer`) for cache-friendly single-pass
//   accumulation, with optional Metal GPU offload for large datasets.
// * **Merge** — Employs a typed hash join: the build side is hashed using
//   the native key type (Double, String, …) instead of stringified keys,
//   avoiding allocation and comparison overhead.
// * **Describe** — Computes 25th / 50th / 75th percentiles via *ranged
//   quickselect*: after selecting the k-th element, subsequent selections
//   restrict the search to the unsorted partition, giving amortised O(n)
//   total work across all three quantiles.
// * **Concat** — Performs direct buffer concatenation (NativeArray +
//   BitVector) instead of round-tripping through optional arrays.
// * **Filter** — Converts a `[Bool]` mask to an index-gather to avoid
//   branch misprediction at ~50 % selectivity.

/// A two-dimensional, size-mutable, labeled tabular data structure with
/// column-oriented storage — the Swift equivalent of ``pandas.DataFrame``.
///
/// `DataFrame` stores each column as an independent ``Column`` value and
/// maintains column order via an internal `columnNames` array.  It uses
/// Swift value semantics with copy-on-write, so copies are cheap until
/// mutation occurs.  The row index is generated lazily for default range
/// indices, avoiding unnecessary `String` allocations.
///
/// ## Topics
///
/// ### Creating a DataFrame
/// - ``init()``
/// - ``init(_:)-([String:[Double]])``
/// - ``init(_:)-([String:[Double?]])``
/// - ``init(columns:index:)``
/// - ``init(records:)``
///
/// ### Shape & Metadata
/// - ``rowCount``
/// - ``columnCount``
/// - ``shape``
/// - ``isEmpty``
/// - ``dtypes``
///
/// ### Column Access
/// - ``subscript(column:)``
/// - ``select(columns:)``
/// - ``drop(columns:)``
/// - ``rename(columns:)``
///
/// ### Row Access
/// - ``iloc(_:)-Range``
/// - ``iloc(_:)-Int``
/// - ``loc(_:)-String``
/// - ``loc(_:)-[String]``
/// - ``head(_:)``
/// - ``tail(_:)``
///
/// ### Filtering & Sorting
/// - ``filter(mask:)``
/// - ``subscript(mask:)``
/// - ``sortValues(by:ascending:)-multi``
/// - ``sortValues(by:ascending:)-single``
///
/// ### Aggregation
/// - ``sum()-DataFrame``
/// - ``mean()-DataFrame``
/// - ``std(ddof:)``
/// - ``min()-DataFrame``
/// - ``max()-DataFrame``
/// - ``median()-DataFrame``
/// - ``describe()-DataFrame``
///
/// ### GroupBy
/// - ``groupBy(_:)-String``
/// - ``groupBy(_:)-[String]``
///
/// ### Joins & Concatenation
/// - ``merge(_:on:how:)``
/// - ``concat(_:)``
///
/// ### Deduplication
/// - ``duplicated(subset:)``
/// - ``dropDuplicates(subset:)``
///
/// ### Transformation
/// - ``apply(_:)``
public struct DataFrame: CustomStringConvertible, Sendable {
    /// The ordered list of column names in this DataFrame.
    ///
    /// Column order is preserved across all operations that produce a new
    /// DataFrame (select, drop, merge, concat, etc.).  The array is
    /// `private(set)` — external code can read but not directly mutate it;
    /// mutations go through the subscript setter or dedicated methods.
    public private(set) var columnNames: [String]

    /// The backing dictionary mapping each column name to its ``Column`` data.
    ///
    /// Keyed lookup is O(1) on average.  The dictionary is `internal` so that
    /// sibling types (e.g. ``GroupBy``, CSV readers) can access raw column
    /// storage without going through the ``Series`` abstraction.
    internal var columns: [String: Column]

    /// Row index labels, lazily materialised for default range indices.
    ///
    /// When the DataFrame uses a default range index (`_isDefaultIndex == true`)
    /// and `_indexLabels` is empty, the getter synthesises `["0", "1", …]` on
    /// the fly.  Setting this property automatically clears the default-index
    /// flag, marking the index as user-defined.
    ///
    /// - Complexity: O(n) on first access for default indices (string
    ///   allocation); O(1) thereafter because subsequent accesses return
    ///   the cached array.
    public var indexLabels: [String] {
        get {
            if _isDefaultIndex && _indexLabels.isEmpty && rowCount > 0 {
                return (0..<rowCount).map { "\($0)" }
            }
            return _indexLabels
        }
        set {
            _indexLabels = newValue
            _isDefaultIndex = false
        }
    }
    /// The raw backing store for index labels.
    ///
    /// Empty when the DataFrame is using a default range index (to save memory).
    /// Populated only when a user-supplied or gathered index is in use.
    internal var _indexLabels: [String] = []

    /// Internal flag indicating whether this DataFrame uses a default
    /// zero-based range index (`0, 1, 2, …`).
    ///
    /// When `true`, ``indexLabels`` synthesises the label array lazily and
    /// operations that produce new DataFrames skip index-gathering entirely.
    internal var _isDefaultIndex: Bool = true

    /// Read-only accessor for whether this DataFrame uses a default range
    /// index, exposed to sibling modules without making the mutable flag
    /// `public`.
    internal var isDefaultIndex: Bool { _isDefaultIndex }

    // MARK: - Initializers

    /// Creates an empty DataFrame with no columns and no rows.
    ///
    /// This is the designated "blank slate" initializer.  Columns can be added
    /// afterwards via the subscript setter (`df["col"] = series`).
    ///
    /// ```swift
    /// var df = DataFrame()
    /// df["x"] = Series([1.0, 2.0, 3.0])
    /// ```
    public init() {
        self.columnNames = []
        self.columns = [:]
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a DataFrame from a dictionary mapping column names to arrays of
    /// `Double` values.
    ///
    /// Column order is determined by sorting the dictionary keys
    /// lexicographically (matching Python pandas' behaviour for `dict` input).
    /// All value arrays must have the same length; a precondition failure is
    /// triggered otherwise.  A default range index (`0, 1, …, N-1`) is used.
    ///
    /// ```swift
    /// let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
    /// ```
    ///
    /// - Parameter dict: A dictionary where keys are column names and values
    ///   are equal-length `[Double]` arrays.
    public init(_ dict: [String: [Double]]) {
        let sortedKeys = dict.keys.sorted()
        let rowCount = dict.values.first?.count ?? 0

        self.columnNames = sortedKeys
        self.columns = [:]
        for key in sortedKeys {
            let values = dict[key]!
            precondition(values.count == rowCount, "All columns must have same length")
            self.columns[key] = .fromDoubles(values)
        }
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a DataFrame from a dictionary mapping column names to arrays of
    /// optional `Double` values, allowing `nil` entries to represent missing
    /// data (NA).
    ///
    /// Behaves identically to ``init(_:)-([String:[Double]])`` except that
    /// `nil` elements are stored as NA in the underlying ``NullableArray``
    /// validity mask rather than as sentinel `Double` values.  Column order
    /// is lexicographic by key.
    ///
    /// - Parameter dict: A dictionary where keys are column names and values
    ///   are equal-length `[Double?]` arrays.
    public init(_ dict: [String: [Double?]]) {
        let sortedKeys = dict.keys.sorted()
        let rowCount = dict.values.first?.count ?? 0

        self.columnNames = sortedKeys
        self.columns = [:]
        for key in sortedKeys {
            let values = dict[key]!
            precondition(values.count == rowCount, "All columns must have same length")
            self.columns[key] = .fromOptionalDoubles(values)
        }
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    /// Creates a DataFrame from an ordered array of `(name, Column)` tuples
    /// with an optional explicit index.
    ///
    /// This is the most flexible initializer — it accepts pre-built ``Column``
    /// values of any type and preserves the exact column order given.  When
    /// `index` is `nil`, a default range index is used (lazily generated).
    ///
    /// ```swift
    /// let df = DataFrame(
    ///     columns: [
    ///         ("name", .fromStrings(["Alice", "Bob"])),
    ///         ("age",  .fromDoubles([30, 25]))
    ///     ],
    ///     index: ["row0", "row1"]
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - columns: Ordered `(name, Column)` pairs.  All columns must have
    ///     the same `count`; a precondition failure is triggered otherwise.
    ///   - index: Optional array of row labels.  When provided, its length
    ///     must equal the row count.  When `nil`, a lazy range index is used.
    public init(columns: [(String, Column)], index: [String]? = nil) {
        let rowCount = columns.first?.1.count ?? 0
        self.columnNames = columns.map { $0.0 }
        self.columns = [:]
        for (name, col) in columns {
            precondition(col.count == rowCount, "All columns must have same length")
            self.columns[name] = col
        }
        if let index = index {
            self._indexLabels = index
            self._isDefaultIndex = false
        } else {
            self._indexLabels = []
            self._isDefaultIndex = true
        }
    }

    /// Creates a DataFrame from an array of row dictionaries ("records"
    /// orientation), analogous to ``pandas.DataFrame.from_records``.
    ///
    /// The union of all dictionary keys across every record determines the
    /// column set; columns are sorted lexicographically.  If a record is
    /// missing a key that appears in other records, the corresponding cell is
    /// stored as NA (using ``Column.fromOptionalDoubles``).
    ///
    /// ```swift
    /// let df = DataFrame(records: [
    ///     ["x": 1.0, "y": 10.0],
    ///     ["x": 2.0],               // "y" will be NA in this row
    /// ])
    /// ```
    ///
    /// - Parameter records: An array of `[String: Double]` dictionaries, one
    ///   per row.
    public init(records: [[String: Double]]) {
        let allKeys = records.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let sortedKeys = allKeys.sorted()

        self.columnNames = sortedKeys
        self.columns = [:]

        for key in sortedKeys {
            let values: [Double?] = records.map { $0[key] }
            self.columns[key] = .fromOptionalDoubles(values)
        }
        self._indexLabels = []
        self._isDefaultIndex = true
    }

    // MARK: - Shape & Metadata

    /// The number of rows in the DataFrame.
    ///
    /// Derived from the count of the first column; returns `0` if the
    /// DataFrame has no columns.
    ///
    /// - Complexity: O(1).
    public var rowCount: Int {
        columns.values.first?.count ?? 0
    }

    /// The number of columns in the DataFrame.
    ///
    /// - Complexity: O(1).
    public var columnCount: Int {
        columnNames.count
    }

    /// The shape of the DataFrame as a `(rows, columns)` tuple, mirroring
    /// ``pandas.DataFrame.shape``.
    ///
    /// ```swift
    /// let (nRows, nCols) = df.shape
    /// ```
    public var shape: (rows: Int, columns: Int) {
        (rowCount, columnCount)
    }

    /// `true` when the DataFrame contains no data — either zero rows or zero
    /// columns.
    public var isEmpty: Bool {
        rowCount == 0 || columnCount == 0
    }

    /// An ordered list of `(columnName, dtype)` pairs describing the data
    /// type of each column, analogous to ``pandas.DataFrame.dtypes``.
    ///
    /// The dtype is represented by the ``DTypeEnum`` enum (`.float64`,
    /// `.int64`, `.string`, `.bool`).
    public var dtypes: [(name: String, dtype: DTypeEnum)] {
        columnNames.map { ($0, columns[$0]!.dtype) }
    }

    // MARK: - Column Access

    /// Accesses a column by name, returning (get) or replacing (set) a
    /// ``Series``.
    ///
    /// **Get:** Returns a ``Series`` wrapping the raw ``Column`` data and
    /// inheriting the DataFrame's index.  Fatal-errors if the column name
    /// does not exist.
    ///
    /// **Set:** Replaces (or inserts) a column.  The new ``Series`` must have
    /// the same `count` as the DataFrame's current ``rowCount`` (unless the
    /// DataFrame has no columns yet, in which case the new Series defines the
    /// row count).  When the first column is inserted this way, the
    /// DataFrame also adopts the Series' index.
    ///
    /// ```swift
    /// let ages: Series = df["age"]          // get
    /// df["salary"] = Series([50_000, …])    // set (insert or replace)
    /// ```
    public subscript(column: String) -> Series {
        get {
            guard let col = columns[column] else {
                fatalError("Column '\(column)' not found")
            }
            return Series(data: col, defaultIndex: _isDefaultIndex, index: _indexLabels, name: column)
        }
        set {
            precondition(newValue.count == rowCount || columnCount == 0,
                        "New column must have same length as DataFrame")
            if !columnNames.contains(column) {
                columnNames.append(column)
            }
            columns[column] = newValue.data
            if columnCount == 1 {
                _indexLabels = newValue._indexLabels
                _isDefaultIndex = newValue._isDefaultIndex
            }
        }
    }

    /// Returns a new DataFrame containing only the specified columns, in the
    /// order given.
    ///
    /// Fatal-errors if any name in `names` does not exist in the DataFrame.
    /// The resulting DataFrame shares the same index (and default-index flag)
    /// as the receiver.
    ///
    /// - Parameter names: The column names to retain.
    /// - Returns: A new ``DataFrame`` with only the requested columns.
    public func select(columns names: [String]) -> DataFrame {
        var result = DataFrame()
        result._indexLabels = _indexLabels
        result._isDefaultIndex = _isDefaultIndex
        result.columnNames = names
        for name in names {
            guard let col = columns[name] else {
                fatalError("Column '\(name)' not found")
            }
            result.columns[name] = col
        }
        return result
    }

    /// Returns a new DataFrame with the specified columns removed.
    ///
    /// Columns not present in `names` are silently ignored (no error).
    /// Implemented as the complement of ``select(columns:)``.
    ///
    /// - Parameter names: The column names to drop.
    /// - Returns: A new ``DataFrame`` without the named columns.
    public func drop(columns names: [String]) -> DataFrame {
        let remaining = columnNames.filter { !names.contains($0) }
        return select(columns: remaining)
    }

    /// Returns a new DataFrame with columns renamed according to the given
    /// mapping.
    ///
    /// Keys in `mapping` that do not correspond to existing column names are
    /// silently ignored.  Columns whose names do not appear as keys are kept
    /// unchanged.  Both the `columnNames` array and the internal `columns`
    /// dictionary are updated consistently.
    ///
    /// - Parameter mapping: A `[oldName: newName]` dictionary.
    /// - Returns: A renamed copy of the DataFrame.
    public func rename(columns mapping: [String: String]) -> DataFrame {
        var result = self
        result.columnNames = columnNames.map { mapping[$0] ?? $0 }
        var newColumns = [String: Column]()
        for (oldName, col) in columns {
            let newName = mapping[oldName] ?? oldName
            newColumns[newName] = col
        }
        result.columns = newColumns
        return result
    }

    // MARK: - Row Access (iloc — integer-location based)

    /// Selects a contiguous slice of rows by integer position range,
    /// analogous to ``pandas.DataFrame.iloc[start:stop]``.
    ///
    /// Returns a new DataFrame containing only the rows whose positions fall
    /// within `range`.  The result inherits the receiver's index (custom or
    /// default) appropriately.
    ///
    /// - Parameter range: A half-open `Range<Int>` of row positions.
    /// - Returns: A new ``DataFrame`` with the selected rows.
    public func iloc(_ range: Range<Int>) -> DataFrame {
        let indices = Array(range)
        return takeRows(indices)
    }

    /// Selects a single row by integer position, returning a dictionary of
    /// column-name to value pairs.
    ///
    /// This mirrors ``pandas.DataFrame.iloc[i]`` but returns a Swift
    /// dictionary rather than a ``Series`` for ergonomic single-row access.
    /// Triggers a precondition failure if `position` is out of bounds.
    ///
    /// - Parameter position: Zero-based row index.
    /// - Returns: A `[String: Any?]` dictionary where keys are column names
    ///   and values are the typed cell values (or `nil` for NA).
    public func iloc(_ position: Int) -> [String: Any?] {
        precondition(position >= 0 && position < rowCount, "Position out of range")
        var row = [String: Any?]()
        for name in columnNames {
            row[name] = columns[name]!.value(at: position)
        }
        return row
    }

    // MARK: - Row Access (loc — label-based)

    /// Selects a single row by its index label, analogous to
    /// ``pandas.DataFrame.loc[label]``.
    ///
    /// Performs a linear scan of ``indexLabels`` to find the first occurrence
    /// of `label`.  Returns `nil` if the label is not found; otherwise
    /// delegates to ``iloc(_:)-Int``.
    ///
    /// - Parameter label: The string index label to look up.
    /// - Returns: A `[String: Any?]` dictionary for the matching row, or
    ///   `nil` if the label does not exist.
    public func loc(_ label: String) -> [String: Any?]? {
        guard let pos = indexLabels.firstIndex(of: label) else { return nil }
        return iloc(pos)
    }

    /// Selects multiple rows by their index labels, returning a new DataFrame.
    ///
    /// Labels that do not exist in the index are silently skipped (via
    /// `compactMap`).  The returned DataFrame preserves the order of
    /// `labels`.
    ///
    /// - Parameter labels: An array of string index labels.
    /// - Returns: A new ``DataFrame`` containing the matched rows.
    public func loc(_ labels: [String]) -> DataFrame {
        let indices = labels.compactMap { label in indexLabels.firstIndex(of: label) }
        return takeRows(indices)
    }

    // MARK: - Boolean Mask Filtering

    /// Selects rows where the corresponding element in `mask` is `true`,
    /// analogous to ``pandas.DataFrame[mask]``.
    ///
    /// Internally the boolean mask is first converted to a compact integer
    /// index array, and then a gather (``takeRows(_:)``) is performed.  This
    /// **index-gather** strategy avoids branch-misprediction overhead that
    /// occurs with a direct mask-based copy loop at ~50 % selectivity — a
    /// common scenario when filtering by a comparison operator (e.g.
    /// `df["age"] > 30`).
    ///
    /// - Parameter mask: A `[Bool]` array whose length must equal
    ///   ``rowCount``; a precondition failure is triggered otherwise.
    /// - Returns: A new ``DataFrame`` containing only the rows where `mask`
    ///   is `true`, preserving column order and index labels.
    ///
    /// - Complexity: O(rows * columns) — one pass to build the index array,
    ///   then one gather per column.
    public func filter(mask: [Bool]) -> DataFrame {
        precondition(mask.count == rowCount, "Mask must have same length as DataFrame")
        // Convert mask to index array — index-based gather avoids branch
        // misprediction at ~50% selectivity that plagues mask-based take.
        let n = mask.count
        let indices = ContiguousArray<Int>(unsafeUninitializedCapacity: n) { buf, count in
            mask.withUnsafeBufferPointer { m in
                var j = 0
                for i in 0..<n {
                    if m[i] {
                        (buf.baseAddress! + j).initialize(to: i)
                        j += 1
                    }
                }
                count = j
            }
        }
        let indexArray = Array(indices)
        var newColumns = [(String, Column)]()
        newColumns.reserveCapacity(columnNames.count)
        for name in columnNames {
            newColumns.append((name, columns[name]!.take(indices: indexArray)))
        }
        if _isDefaultIndex {
            return DataFrame(columns: newColumns)
        }
        // Custom index: gather labels
        var gathered = [String]()
        gathered.reserveCapacity(indexArray.count)
        for idx in indexArray {
            gathered.append(_indexLabels[idx])
        }
        return DataFrame(columns: newColumns, index: gathered)
    }

    /// Subscript with a boolean mask, enabling the idiomatic pandas-style
    /// filtering syntax `df[df["age"] > 30]`.
    ///
    /// This is a convenience wrapper around ``filter(mask:)``.  The `[Bool]`
    /// mask is typically produced by one of the ``Series`` comparison
    /// operators (`>`, `>=`, `<`, `<=`, ``eq(_:)``, ``ne(_:)``).
    public subscript(mask: [Bool]) -> DataFrame {
        filter(mask: mask)
    }

    /// Gathers rows at the specified integer positions into a new DataFrame.
    ///
    /// This is the low-level building block used by ``iloc(_:)-Range``,
    /// ``filter(mask:)``, ``sortValues(by:ascending:)``, and many other
    /// methods.  Each column is gathered independently via
    /// ``Column.take(indices:)``.  When the receiver uses a default range
    /// index, the result also gets a fresh default range index (avoiding N
    /// `String` copies); otherwise the index labels are gathered in the same
    /// order as `indices`.
    ///
    /// - Parameter indices: Row positions to extract (may contain duplicates
    ///   and need not be sorted).
    /// - Returns: A new ``DataFrame`` with the gathered rows.
    public func takeRows(_ indices: [Int]) -> DataFrame {
        var newColumns = [(String, Column)]()
        newColumns.reserveCapacity(columnNames.count)
        for name in columnNames {
            newColumns.append((name, columns[name]!.take(indices: indices)))
        }
        if isDefaultIndex {
            // Default range index: generate new range (avoids N string copies)
            return DataFrame(columns: newColumns)
        }
        // Custom index: gather labels from old index
        var newIndex = [String]()
        newIndex.reserveCapacity(indices.count)
        indices.withUnsafeBufferPointer { idx in
            for i in 0..<idx.count {
                newIndex.append(indexLabels[idx[i]])
            }
        }
        return DataFrame(columns: newColumns, index: newIndex)
    }

    // MARK: - Head / Tail

    /// Returns the first `n` rows of the DataFrame (default 5), analogous to
    /// ``pandas.DataFrame.head()``.
    ///
    /// If `n` exceeds ``rowCount``, the entire DataFrame is returned.
    ///
    /// - Parameter n: Number of rows to return (default `5`).
    public func head(_ n: Int = 5) -> DataFrame {
        iloc(0..<Swift.min(n, rowCount))
    }

    /// Returns the last `n` rows of the DataFrame (default 5), analogous to
    /// ``pandas.DataFrame.tail()``.
    ///
    /// If `n` exceeds ``rowCount``, the entire DataFrame is returned.
    ///
    /// - Parameter n: Number of rows to return (default `5`).
    public func tail(_ n: Int = 5) -> DataFrame {
        let start = Swift.max(0, rowCount - n)
        return iloc(start..<rowCount)
    }

    // MARK: - Sorting

    /// Sorts the DataFrame by values in multiple columns, with the leftmost
    /// column acting as the primary sort key, analogous to
    /// ``pandas.DataFrame.sort_values(by=[...])`` with a list of columns.
    ///
    /// ## Performance
    ///
    /// To avoid paying the cost of dictionary lookups and ``Column`` enum
    /// dispatch on every pair-wise comparison (which would execute O(n log n)
    /// times), this method **pre-extracts** each sort column's raw data into
    /// a local ``SortKey`` enum *before* entering the sort.  The ``SortKey``
    /// enum has specialised cases for:
    ///
    /// - `doubleAllValid` — contiguous `Double` buffer with no NA values.
    /// - `doubleWithNA` — `Double` buffer plus ``BitVector`` mask.
    /// - `int64AllValid` / `int64WithNA` — analogous for `Int64`.
    /// - `string` — ``StringArray`` with optional-`String` elements.
    ///
    /// NA values sort to the **end** regardless of sort direction (matching
    /// pandas' default `na_position="last"`).
    ///
    /// - Parameters:
    ///   - sortColumns: Column names to sort by, in priority order (leftmost
    ///     is primary).
    ///   - ascending: Per-column ascending flags.  Defaults to all `true`.
    ///     Must have the same count as `sortColumns`.
    /// - Returns: A new ``DataFrame`` sorted according to the specified keys.
    public func sortValues(by sortColumns: [String], ascending: [Bool]? = nil) -> DataFrame {
        let ascFlags = ascending ?? [Bool](repeating: true, count: sortColumns.count)
        precondition(ascFlags.count == sortColumns.count, "ascending array must match columns count")

        // Pre-extract column data outside the comparator to avoid dictionary
        // lookups and enum dispatch on every comparison (O(n log n) times).
        enum SortKey {
            case doubleAllValid(ContiguousArray<Double>, Bool)
            case doubleWithNA(ContiguousArray<Double>, BitVector, Bool)
            case int64AllValid(ContiguousArray<Int64>, Bool)
            case int64WithNA(ContiguousArray<Int64>, BitVector, Bool)
            case string(StringArray, Bool)
        }
        var sortKeys = [SortKey]()
        sortKeys.reserveCapacity(sortColumns.count)
        for (colIdx, colName) in sortColumns.enumerated() {
            guard let col = columns[colName] else { continue }
            let asc = ascFlags[colIdx]
            switch col {
            case .double(let a):
                if a.mask.allValid {
                    sortKeys.append(.doubleAllValid(a.data.buffer.storage, asc))
                } else {
                    sortKeys.append(.doubleWithNA(a.data.buffer.storage, a.mask, asc))
                }
            case .int64(let a):
                if a.mask.allValid {
                    sortKeys.append(.int64AllValid(a.data.buffer.storage, asc))
                } else {
                    sortKeys.append(.int64WithNA(a.data.buffer.storage, a.mask, asc))
                }
            case .string(let a):
                sortKeys.append(.string(a, asc))
            default:
                break
            }
        }

        var indices = Array(0..<rowCount)
        indices.sort { i, j in
            for key in sortKeys {
                switch key {
                case .doubleAllValid(let data, let asc):
                    if data[i] != data[j] {
                        return asc ? data[i] < data[j] : data[i] > data[j]
                    }
                case .doubleWithNA(let data, let mask, let asc):
                    let iValid = mask[i], jValid = mask[j]
                    if !iValid && !jValid { continue }
                    if !iValid { return false }
                    if !jValid { return true }
                    if data[i] != data[j] {
                        return asc ? data[i] < data[j] : data[i] > data[j]
                    }
                case .int64AllValid(let data, let asc):
                    if data[i] != data[j] {
                        return asc ? data[i] < data[j] : data[i] > data[j]
                    }
                case .int64WithNA(let data, let mask, let asc):
                    let iValid = mask[i], jValid = mask[j]
                    if !iValid && !jValid { continue }
                    if !iValid { return false }
                    if !jValid { return true }
                    if data[i] != data[j] {
                        return asc ? data[i] < data[j] : data[i] > data[j]
                    }
                case .string(let a, let asc):
                    let iVal = a[i], jVal = a[j]
                    if iVal == nil && jVal == nil { continue }
                    if iVal == nil { return false }
                    if jVal == nil { return true }
                    if iVal! != jVal! {
                        return asc ? iVal! < jVal! : iVal! > jVal!
                    }
                }
            }
            return false
        }
        return takeRows(indices)
    }

    /// Sorts the DataFrame by a single column's values, analogous to
    /// ``pandas.DataFrame.sort_values(by=column)``.
    ///
    /// This single-column overload is significantly faster than the
    /// multi-column variant for two reasons:
    ///
    /// 1. **allValid fast path** — When the column's ``BitVector`` mask has
    ///    `allValid == true` (no NA values), sorting delegates directly to
    ///    ``NativeArray.argsort(ascending:)`` which uses a contiguous buffer
    ///    comparison, avoiding per-element mask checks.
    /// 2. **No SortKey indirection** — Column data is pattern-matched once
    ///    and used directly; there is no enum wrapper.
    ///
    /// When NA values are present, valid rows are sorted first and NA rows
    /// are appended at the end (matching pandas' `na_position="last"`).
    ///
    /// - Parameters:
    ///   - column: The column name to sort by.  Fatal-errors if not found.
    ///   - ascending: Sort order; `true` (default) for ascending.
    /// - Returns: A new sorted ``DataFrame``.
    public func sortValues(by column: String, ascending: Bool = true) -> DataFrame {
        guard let col = columns[column] else {
            fatalError("Column '\(column)' not found")
        }
        let indices: [Int]
        switch col {
        case .double(let a):
            if a.mask.allValid {
                // Fast path: no NAs — direct argsort on raw storage
                indices = a.data.argsort(ascending: ascending)
            } else {
                var validPositions = [Int]()
                var naPositions = [Int]()
                validPositions.reserveCapacity(a.count)
                naPositions.reserveCapacity(a.count / 10)
                for i in 0..<a.count {
                    if a.mask[i] { validPositions.append(i) } else { naPositions.append(i) }
                }
                a.data.withUnsafeBufferPointer { buf in
                    validPositions.sort { ascending ? buf[$0] < buf[$1] : buf[$0] > buf[$1] }
                }
                indices = validPositions + naPositions
            }
        case .string(let a):
            indices = a.argsort(ascending: ascending)
        case .int64(let a):
            if a.mask.allValid {
                indices = a.data.argsort(ascending: ascending)
            } else {
                var validPositions = [Int]()
                var naPositions = [Int]()
                validPositions.reserveCapacity(a.count)
                naPositions.reserveCapacity(a.count / 10)
                for i in 0..<a.count {
                    if a.mask[i] { validPositions.append(i) } else { naPositions.append(i) }
                }
                a.data.withUnsafeBufferPointer { buf in
                    validPositions.sort { ascending ? buf[$0] < buf[$1] : buf[$0] > buf[$1] }
                }
                indices = validPositions + naPositions
            }
        default:
            return self
        }
        return takeRows(indices)
    }

    // MARK: - Aggregations

    /// Computes the sum of each numeric column, returning a ``Series``
    /// indexed by column name.
    ///
    /// Non-numeric columns are silently skipped.  NA values within a column
    /// are excluded from the summation (matching pandas' default
    /// `skipna=True` behaviour).  If a column has no valid values, its sum
    /// is `NaN`.
    ///
    /// - Returns: A ``Series`` with one entry per numeric column.
    public func sum() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.sum() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Computes the arithmetic mean of each numeric column, returning a
    /// ``Series`` indexed by column name.
    ///
    /// NA values are excluded.  Returns `NaN` for columns with no valid
    /// values.
    public func mean() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.mean() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Computes the sample standard deviation of each numeric column,
    /// returning a ``Series`` indexed by column name.
    ///
    /// Uses `ddof` (delta degrees of freedom) in the denominator
    /// (`N - ddof`), defaulting to `1` for Bessel's correction (matching
    /// pandas).  NA values are excluded.
    ///
    /// - Parameter ddof: Delta degrees of freedom (default `1`).
    public func std(ddof: Int = 1) -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.std(ddof: ddof) ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Computes the minimum value of each numeric column, returning a
    /// ``Series`` indexed by column name.  NA values are excluded.
    public func min() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.min() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Computes the maximum value of each numeric column, returning a
    /// ``Series`` indexed by column name.  NA values are excluded.
    public func max() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.max() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Computes the median of each numeric column, returning a ``Series``
    /// indexed by column name.
    ///
    /// Delegates to ``Series.median()`` which uses O(n) quickselect rather
    /// than O(n log n) sorting.  NA values are excluded.
    public func median() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { self[$0].median() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Generates descriptive statistics for all numeric columns, analogous to
    /// ``pandas.DataFrame.describe()``.
    ///
    /// Returns a new DataFrame with statistic names as the index:
    /// `["count", "mean", "std", "min", "25%", "50%", "75%", "max"]` and one
    /// column per numeric column in the original DataFrame.
    ///
    /// ## Performance — Ranged Quickselect
    ///
    /// The 25th, 50th, and 75th percentiles are computed using **ranged
    /// quickselect** (`NativeArray.nthElement`).  After selecting the k-th
    /// element for the 25th percentile, the array is partially partitioned:
    /// elements `[0..k]` are all less-than-or-equal-to `arr[k]`, and
    /// elements `[k+1..n-1]` are all greater-than-or-equal.  The 50th
    /// percentile search is therefore restricted to `[k+1..n-1]`, and the
    /// 75th percentile further narrows the range.  This gives amortised O(n)
    /// total work for all three quantiles combined, rather than O(n) per
    /// quantile.
    ///
    /// Linear interpolation is used between adjacent ranks (matching pandas'
    /// default `interpolation='linear'`).
    ///
    /// - Returns: A ``DataFrame`` of descriptive statistics.
    public func describe() -> DataFrame {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        var resultCols = [(String, Column)]()

        for colName in numericCols {
            guard let doubles = columns[colName]!.asDouble() else { continue }
            let count = Double(doubles.validCount)
            let mean = doubles.mean() ?? .nan
            let std = doubles.std(ddof: 1) ?? .nan
            let minVal = doubles.min() ?? .nan
            let maxVal = doubles.max() ?? .nan

            // Copy array once, compute all 3 quantiles on the same copy
            // using ranged quickselect. After nthElement(k1), elements
            // [0..k1] <= arr[k1] and [k1+1..n-1] >= arr[k1], so the
            // next nthElement only needs to search the narrowed range.
            var q25 = Double.nan, q50 = Double.nan, q75 = Double.nan
            var arr: NativeArray<Double>
            if doubles.mask.allValid {
                arr = doubles.data.copy()
            } else {
                arr = doubles.dropNA()
            }
            let n = arr.count
            if n > 0 {
                // Helper for linear interpolation quantile
                func iq(_ q: Double) -> (Int, Int, Double) {
                    let pos = q * Double(n - 1)
                    let lo = Int(pos)
                    let hi = Swift.min(lo + 1, n - 1)
                    return (lo, hi, pos - Double(lo))
                }
                let (lo25, hi25, f25) = iq(0.25)
                let (lo50, hi50, f50) = iq(0.50)
                let (lo75, hi75, f75) = iq(0.75)

                // q25: select hi25 (gets both lo25 and hi25 positioned)
                arr.nthElement(hi25)
                let v25hi = arr[hi25]
                let v25lo = (lo25 == hi25) ? v25hi : arr.withUnsafeBufferPointer { buf in
                    VectorOps.max(UnsafeBufferPointer(rebasing: buf[0...lo25]))
                }
                q25 = v25lo + f25 * (v25hi - v25lo)

                // q50: search only in [hi25+1..n-1] since elements before are <= q25
                arr.nthElement(hi50, lo: hi25 + 1, hi: n - 1)
                let v50hi = arr[hi50]
                let v50lo = (lo50 == hi50) ? v50hi : arr.withUnsafeBufferPointer { buf in
                    VectorOps.max(UnsafeBufferPointer(rebasing: buf[0...lo50]))
                }
                q50 = v50lo + f50 * (v50hi - v50lo)

                // q75: search only in [hi50+1..n-1]
                arr.nthElement(hi75, lo: hi50 + 1, hi: n - 1)
                let v75hi = arr[hi75]
                let v75lo = (lo75 == hi75) ? v75hi : arr.withUnsafeBufferPointer { buf in
                    VectorOps.max(UnsafeBufferPointer(rebasing: buf[0...lo75]))
                }
                q75 = v75lo + f75 * (v75hi - v75lo)
            }

            let stats: [Double] = [count, mean, std, minVal, q25, q50, q75, maxVal]
            resultCols.append((colName, .fromDoubles(stats)))
        }

        return DataFrame(
            columns: resultCols,
            index: ["count", "mean", "std", "min", "25%", "50%", "75%", "max"]
        )
    }

    // MARK: - Duplicates

    /// Returns a `[Bool]` mask that is `true` for rows whose values (in the
    /// specified columns) have already appeared in an earlier row, analogous
    /// to ``pandas.DataFrame.duplicated(keep='first')``.
    ///
    /// Composite keys are formed by joining each row's formatted column values
    /// with a tab separator and inserting them into a `Set<String>` for O(1)
    /// membership testing.
    ///
    /// - Parameter subset: Column names to consider.  Defaults to all columns
    ///   when `nil`.
    /// - Returns: A `[Bool]` array of length ``rowCount``.
    public func duplicated(subset: [String]? = nil) -> [Bool] {
        let cols = subset ?? columnNames
        var seen = Set<String>()
        return (0..<rowCount).map { i in
            let key = cols.map { columns[$0]!.formattedValue(at: i) }.joined(separator: "\t")
            return !seen.insert(key).inserted
        }
    }

    /// Returns a new DataFrame with duplicate rows removed, keeping the first
    /// occurrence of each unique row, analogous to
    /// ``pandas.DataFrame.drop_duplicates(keep='first')``.
    ///
    /// - Parameter subset: Column names to consider for duplicate detection.
    ///   Defaults to all columns when `nil`.
    /// - Returns: A deduplicated ``DataFrame``.
    public func dropDuplicates(subset: [String]? = nil) -> DataFrame {
        let dupes = duplicated(subset: subset)
        let keepIndices = dupes.enumerated().compactMap { !$1 ? $0 : nil }
        return takeRows(keepIndices)
    }

    // MARK: - Apply

    /// Applies a transformation function to each column independently,
    /// returning a new DataFrame with the transformed columns, analogous to
    /// ``pandas.DataFrame.apply(axis=0)``.
    ///
    /// The transform receives a ``Series`` for each column and must return a
    /// ``Series`` of the same length.  The resulting DataFrame preserves the
    /// original column names and index.
    ///
    /// ```swift
    /// let normalised = df.apply { col in col / col.max()! }
    /// ```
    ///
    /// - Parameter transform: A closure `(Series) -> Series` applied to every
    ///   column.
    /// - Returns: A new ``DataFrame`` with transformed column data.
    public func apply(_ transform: (Series) -> Series) -> DataFrame {
        var resultCols = [(String, Column)]()
        for name in columnNames {
            let series = self[name]
            let transformed = transform(series)
            resultCols.append((name, transformed.data))
        }
        if _isDefaultIndex {
            return DataFrame(columns: resultCols)
        }
        return DataFrame(columns: resultCols, index: indexLabels)
    }

    // MARK: - Concat

    /// Concatenates an array of DataFrames vertically (row-wise), analogous
    /// to ``pandas.concat(axis=0)``.
    ///
    /// All DataFrames must share the same column schema (names and order are
    /// taken from the first frame).  The implementation performs **direct
    /// buffer concatenation** for each column type:
    ///
    /// - `.double` / `.int64` / `.bool`: ``NativeArray`` buffers are appended
    ///   and ``BitVector`` masks are concatenated, avoiding the overhead of
    ///   creating intermediate optional arrays.
    /// - `.string`: Optional-string storage arrays are simply appended.
    ///
    /// If all input frames use default range indices, the result also uses a
    /// default range index (skipping index-label gathering entirely).
    ///
    /// - Parameter frames: An array of DataFrames to concatenate.
    /// - Returns: A single ``DataFrame`` containing all rows.  Returns an
    ///   empty DataFrame if `frames` is empty.
    public static func concat(_ frames: [DataFrame]) -> DataFrame {
        guard let first = frames.first else { return DataFrame() }
        let colNames = first.columnNames
        let totalRows = frames.reduce(0) { $0 + $1.rowCount }

        var resultCols = [(String, Column)]()
        var resultIndex = [String]()
        resultIndex.reserveCapacity(totalRows)

        for name in colNames {
            guard let firstCol = first.columns[name] else { continue }
            switch firstCol {
            case .double:
                // Direct buffer concatenation — no [Double?] intermediary
                var combinedData = NativeArray<Double>([])
                var masks = [BitVector]()
                masks.reserveCapacity(frames.count)
                for frame in frames {
                    guard case .double(let arr) = frame.columns[name] else { continue }
                    combinedData.append(contentsOf: arr.data)
                    masks.append(arr.mask)
                }
                let combinedMask = BitVector.concat(masks)
                resultCols.append((name, .double(NullableArray(data: combinedData, mask: combinedMask))))
            case .string:
                var allValues = [String?]()
                allValues.reserveCapacity(totalRows)
                for frame in frames {
                    guard case .string(let arr) = frame.columns[name] else { continue }
                    allValues.append(contentsOf: arr.storage)
                }
                resultCols.append((name, .fromOptionalStrings(allValues)))
            case .int64:
                var combinedData = NativeArray<Int64>([])
                var masks = [BitVector]()
                masks.reserveCapacity(frames.count)
                for frame in frames {
                    guard case .int64(let arr) = frame.columns[name] else { continue }
                    combinedData.append(contentsOf: arr.data)
                    masks.append(arr.mask)
                }
                let combinedMask = BitVector.concat(masks)
                resultCols.append((name, .int64(NullableArray(data: combinedData, mask: combinedMask))))
            case .bool:
                var combinedData = NativeArray<Bool>([])
                var masks = [BitVector]()
                masks.reserveCapacity(frames.count)
                for frame in frames {
                    guard case .bool(let arr) = frame.columns[name] else { continue }
                    combinedData.append(contentsOf: arr.data)
                    masks.append(arr.mask)
                }
                let combinedMask = BitVector.concat(masks)
                resultCols.append((name, .bool(NullableArray(data: combinedData, mask: combinedMask))))
            }
        }

        // If all frames use default range index, skip index gathering entirely
        let allDefault = frames.allSatisfy { $0._isDefaultIndex }
        if allDefault {
            return DataFrame(columns: resultCols)
        }
        for frame in frames {
            resultIndex.append(contentsOf: frame.indexLabels)
        }
        return DataFrame(columns: resultCols, index: resultIndex)
    }

    // MARK: - Merge

    /// Merges (joins) this DataFrame with `right` on a shared key column,
    /// analogous to ``pandas.DataFrame.merge(on=key)``.
    ///
    /// Supports four join types via the ``MergeHow`` enum: `.inner` (default),
    /// `.left`, `.right`, and `.outer`.
    ///
    /// ## Algorithm — Typed Hash Join
    ///
    /// The right-hand key column is hashed into a lookup table
    /// (`[KeyType: [Int]]`) using the **native column type** (Double, String,
    /// etc.) rather than stringified keys.  This avoids allocation and
    /// comparison overhead for the common numeric-key case.  The left-hand
    /// column is then probed against this table row-by-row.
    ///
    /// For `.inner` joins on large datasets, a Metal GPU fast path is
    /// attempted first (see ``MetalMerge``); if unavailable or below the
    /// threshold, the CPU hash-join runs instead.
    ///
    /// When a right-side column name collides with a left-side name (and is
    /// not the key column), it is suffixed with `"_right"`.
    ///
    /// Unmatched rows in left/outer joins produce `-1` in `rightIndices`,
    /// which ``Column.take(indices:)`` interprets as NA.
    ///
    /// - Parameters:
    ///   - right: The other ``DataFrame`` to join with.
    ///   - key: The column name present in both DataFrames to join on.
    ///     Fatal-errors if missing from either side.
    ///   - how: The join type (default `.inner`).
    /// - Returns: A new ``DataFrame`` containing the joined rows.
    public func merge(
        _ right: DataFrame,
        on key: String,
        how: MergeHow = .inner
    ) -> DataFrame {
        guard let leftCol = columns[key], let rightCol = right.columns[key] else {
            fatalError("Key column '\(key)' not found in both DataFrames")
        }

        // GPU fast path for inner joins on large datasets
        if how == .inner && MetalDispatch.shouldUseGPU(
            rowCount: Swift.max(rowCount, right.rowCount),
            threshold: MetalDispatch.mergeThreshold
        ) {
            if let result = MetalMerge.innerJoin(left: self, right: right, on: key) {
                return result
            }
        }

        // CPU path — use typed hash matching for speed
        // Pre-allocate with estimated capacity (assumes ~1:1 match ratio)
        let estimatedMatches = Swift.max(rowCount, right.rowCount)
        var leftIndices = [Int]()
        var rightIndices = [Int]()
        leftIndices.reserveCapacity(estimatedMatches)
        rightIndices.reserveCapacity(estimatedMatches)

        switch (leftCol, rightCol) {
        case (.double(let la), .double(let ra)):
            var rightLookup = [Double: [Int]](minimumCapacity: right.rowCount)
            for i in 0..<right.rowCount where ra.mask[i] {
                rightLookup[ra.data[i], default: []].append(i)
            }
            for i in 0..<rowCount {
                guard la.mask[i] else {
                    if how == .left || how == .outer { leftIndices.append(i); rightIndices.append(-1) }
                    continue
                }
                if let matches = rightLookup[la.data[i]] {
                    for j in matches { leftIndices.append(i); rightIndices.append(j) }
                } else if how == .left || how == .outer {
                    leftIndices.append(i); rightIndices.append(-1)
                }
            }
        case (.string(let la), .string(let ra)):
            var rightLookup = [String: [Int]](minimumCapacity: right.rowCount)
            for i in 0..<right.rowCount {
                if let k = ra[i] { rightLookup[k, default: []].append(i) }
            }
            for i in 0..<rowCount {
                guard let k = la[i] else {
                    if how == .left || how == .outer { leftIndices.append(i); rightIndices.append(-1) }
                    continue
                }
                if let matches = rightLookup[k] {
                    for j in matches { leftIndices.append(i); rightIndices.append(j) }
                } else if how == .left || how == .outer {
                    leftIndices.append(i); rightIndices.append(-1)
                }
            }
        default:
            var rightLookup = [String: [Int]](minimumCapacity: right.rowCount)
            for i in 0..<right.rowCount {
                let k = rightCol.formattedValue(at: i)
                rightLookup[k, default: []].append(i)
            }
            for i in 0..<rowCount {
                let k = leftCol.formattedValue(at: i)
                if let matches = rightLookup[k] {
                    for j in matches { leftIndices.append(i); rightIndices.append(j) }
                } else if how == .left || how == .outer {
                    leftIndices.append(i); rightIndices.append(-1)
                }
            }
        }

        // Build result columns
        var resultCols = [(String, Column)]()
        for name in columnNames {
            resultCols.append((name, columns[name]!.take(indices: leftIndices)))
        }
        for name in right.columnNames where name != key {
            let suffix = columnNames.contains(name) ? "_right" : ""
            resultCols.append((name + suffix, right.columns[name]!.take(indices: rightIndices)))
        }

        return DataFrame(columns: resultCols)
    }

    // MARK: - GroupBy

    /// Groups the DataFrame by a single column, returning a ``GroupBy``
    /// object for split-apply-combine aggregation.
    ///
    /// The returned ``GroupBy`` pre-computes integer group codes via
    /// factorisation in its initializer, so subsequent calls to
    /// ``.sum()``, ``.mean()``, etc. are fast single-pass accumulations.
    ///
    /// ```swift
    /// let result = df.groupBy("city").mean()
    /// ```
    ///
    /// - Parameter column: The column name to group by.
    /// - Returns: A ``GroupBy`` instance bound to this DataFrame.
    public func groupBy(_ column: String) -> GroupBy {
        GroupBy(dataFrame: self, by: [column])
    }

    /// Groups the DataFrame by multiple columns, returning a ``GroupBy``
    /// object.
    ///
    /// Composite group codes are computed by combining per-column factorised
    /// codes via a mixed-radix scheme (`code = code * nUnique + colCode`).
    ///
    /// - Parameter groupColumns: The column names to group by.
    /// - Returns: A ``GroupBy`` instance bound to this DataFrame.
    public func groupBy(_ groupColumns: [String]) -> GroupBy {
        GroupBy(dataFrame: self, by: groupColumns)
    }

    // MARK: - Description (CustomStringConvertible)

    /// A human-readable, box-drawing-formatted table representation of the
    /// DataFrame, used by `print(df)` and string interpolation.
    ///
    /// Displays up to 20 rows with Unicode box-drawing borders.  Numeric
    /// columns are right-aligned; string columns are left-aligned.  When
    /// the DataFrame has more than 20 rows, a `"... N rows total"` footer
    /// is appended.  A summary line `"[rows x columns]"` is always included.
    public var description: String {
        guard !isEmpty else { return "Empty DataFrame" }

        let maxRows = Swift.min(rowCount, 20)

        // Calculate column widths (right-aligned for numeric, left-aligned for strings)
        var colWidths = [String: Int]()
        for name in columnNames {
            colWidths[name] = name.count
        }
        for i in 0..<maxRows {
            for name in columnNames {
                let val = columns[name]!.formattedValue(at: i)
                colWidths[name] = Swift.max(colWidths[name]!, val.count)
            }
        }

        let indexWidth = Swift.max(indexLabels.prefix(maxRows).map { $0.count }.max() ?? 0, 1)

        // Build separator line
        let colSeparators = columnNames.map { String(repeating: "\u{2500}", count: colWidths[$0]! + 2) }
        let topBorder = "\u{250C}" + String(repeating: "\u{2500}", count: indexWidth + 2) + "\u{252C}" + colSeparators.joined(separator: "\u{252C}") + "\u{2510}"
        let headerSep = "\u{251C}" + String(repeating: "\u{2500}", count: indexWidth + 2) + "\u{253C}" + colSeparators.joined(separator: "\u{253C}") + "\u{2524}"
        let bottomBorder = "\u{2514}" + String(repeating: "\u{2500}", count: indexWidth + 2) + "\u{2534}" + colSeparators.joined(separator: "\u{2534}") + "\u{2518}"

        var lines = [String]()

        // Top border
        lines.append(topBorder)

        // Header row
        let idxHeader = String(repeating: " ", count: indexWidth).padding(toLength: indexWidth, withPad: " ", startingAt: 0)
        let headerCells = columnNames.map { name in
            " " + name.padding(toLength: colWidths[name]!, withPad: " ", startingAt: 0) + " "
        }
        lines.append("\u{2502} \(idxHeader) \u{2502}" + headerCells.joined(separator: "\u{2502}") + "\u{2502}")

        // Header separator
        lines.append(headerSep)

        // Data rows
        for i in 0..<maxRows {
            let idx = indexLabels[i].padding(toLength: indexWidth, withPad: " ", startingAt: 0)
            let cells = columnNames.map { name -> String in
                let val = columns[name]!.formattedValue(at: i)
                let isNumeric = columns[name]!.isNumeric
                if isNumeric {
                    // Right-align numeric values
                    let padded = String(repeating: " ", count: Swift.max(0, colWidths[name]! - val.count)) + val
                    return " " + padded + " "
                } else {
                    return " " + val.padding(toLength: colWidths[name]!, withPad: " ", startingAt: 0) + " "
                }
            }
            lines.append("\u{2502} \(idx) \u{2502}" + cells.joined(separator: "\u{2502}") + "\u{2502}")
        }

        // Bottom border
        lines.append(bottomBorder)

        if rowCount > maxRows {
            lines.append("... \(rowCount) rows total")
        }

        lines.append("[\(rowCount) rows x \(columnCount) columns]")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Merge Type

/// Specifies the type of join to perform in ``DataFrame.merge(_:on:how:)``,
/// mirroring the `how` parameter of ``pandas.DataFrame.merge()``.
///
/// - ``inner``: Keep only rows with matching keys in **both** DataFrames
///   (set intersection).
/// - ``left``: Keep all rows from the left DataFrame; unmatched right-side
///   cells are filled with NA.
/// - ``right``: Keep all rows from the right DataFrame; unmatched left-side
///   cells are filled with NA.  *(Implemented by swapping left/right and
///   performing a left join internally.)*
/// - ``outer``: Keep all rows from **both** DataFrames; unmatched cells on
///   either side are filled with NA (set union).
public enum MergeHow: Sendable {
    /// Inner join — only matching keys.
    case inner
    /// Left join — all left rows, NA-fill for unmatched right.
    case left
    /// Right join — all right rows, NA-fill for unmatched left.
    case right
    /// Outer (full) join — all rows from both sides.
    case outer
}

// MARK: - GroupBy

/// Enumerates the built-in aggregation operations supported by the
/// optimised ``GroupBy.fastAggregate(_:)`` code path.
///
/// Each case maps to a tight, single-pass accumulation loop using
/// either raw-pointer accumulators (fully-valid fast path) or
/// mask-checked Swift arrays (NA-aware slow path).
public enum GroupByAggOp: Sendable {
    /// Sum of values per group.
    case sum
    /// Arithmetic mean per group (`sum / count`).
    case mean
    /// Count of non-NA values per group.
    case count
    /// Minimum value per group.
    case min
    /// Maximum value per group.
    case max
}

/// A lazy grouping object for split-apply-combine aggregation, analogous
/// to ``pandas.DataFrame.groupby()``.
///
/// ## Lifecycle
///
/// 1. **Construction** (`init`) — The group-by columns are *factorised*
///    (mapped to dense integer codes via a hash table) **once**.  For a
///    single group column the factorisation delegates to the column's own
///    ``NullableArray.factorize()`` / ``StringArray.factorize()``.  For
///    multiple columns a mixed-radix composite code is built
///    (`code = code * nUnique_col + col_code`).  NA rows receive a code
///    of `-1` and are excluded from all aggregations.
///
/// 2. **Compaction** — Composite codes are remapped to a dense
///    `0..<nGroups` range, and the first row index for each group is
///    recorded (used later to extract group key labels).  Groups are then
///    sorted by their key values so that the output DataFrame has a
///    natural ordering.
///
/// 3. **Aggregation** (`.sum()`, `.mean()`, …) — Each call invokes
///    ``fastAggregate(_:)`` which iterates over all rows in a single pass,
///    accumulating into group-indexed buffers.  Two code paths exist:
///
///    - **Fully-valid fast path** (`allRowsValid && allColValid`): Uses
///      `UnsafeMutablePointer` accumulators for maximum throughput —
///      no bounds checking, no mask checks, optimal cache-line usage.
///    - **NA-aware slow path**: Uses Swift `[Double]` arrays with
///      per-element mask and group-code guards.
///
///    For large datasets, a Metal GPU fast path is attempted first (see
///    ``MetalGroupBy``); if unavailable or below the row-count threshold,
///    the CPU path runs.
///
/// ## Thread Safety
///
/// `GroupBy` is `Sendable`.  All mutable state is confined to `init`; the
/// aggregation methods are pure functions over the immutable cached fields.
public struct GroupBy: Sendable {
    /// The source DataFrame being grouped.
    public let dataFrame: DataFrame

    /// The column name(s) used for grouping.
    public let by: [String]

    /// Dense integer group code for each row (length == `dataFrame.rowCount`).
    /// Rows with NA in any group column have code `-1`.
    private let _groupCodes: [Int]

    /// The total number of distinct groups (excluding NA).
    private let _nGroups: Int

    /// Maps each dense group code `g` to the index of the first row that
    /// belongs to group `g`.  Used to extract group-key labels for the
    /// result index without re-scanning the data.
    private let _firstRowForGroup: [Int]

    /// A permutation of `0..<_nGroups` that orders the groups by their key
    /// values (lexicographic for strings, numeric order for numbers).  The
    /// output DataFrame's rows follow this ordering.
    private let _sortedGroupIndices: [Int]

    /// `true` if at least one row has an NA value in a group column (and
    /// therefore received a group code of `-1`).
    private let _hasNA: Bool

    /// Creates a ``GroupBy`` by factorising the specified group columns.
    ///
    /// Factorisation, code compaction, and group sorting all happen eagerly
    /// in this initializer so that subsequent aggregation calls are cheap
    /// single-pass operations.
    ///
    /// - Parameters:
    ///   - dataFrame: The source ``DataFrame``.
    ///   - by: Column name(s) to group by.
    public init(dataFrame: DataFrame, by: [String]) {
        self.dataFrame = dataFrame
        self.by = by

        let n = dataFrame.rowCount
        guard n > 0 else {
            _groupCodes = []
            _nGroups = 0
            _firstRowForGroup = []
            _sortedGroupIndices = []
            _hasNA = false
            return
        }

        // Factorize group columns to integer codes (computed once)
        var groupCodes: [Int]
        var nGroups: Int
        var hasNA = false

        if by.count == 1 {
            guard let col = dataFrame.columns[by[0]] else {
                _groupCodes = [Int](repeating: 0, count: n)
                _nGroups = 0
                _firstRowForGroup = []
                _sortedGroupIndices = []
                _hasNA = false
                return
            }
            let (codes, nUnique): ([Int], Int)
            switch col {
            case .double(let a):
                let f = a.factorize()
                codes = f.codes; nUnique = f.uniques.count
            case .string(let a):
                let f = a.factorize()
                codes = f.codes; nUnique = f.uniques.count
            case .int64(let a):
                let f = a.factorize()
                codes = f.codes; nUnique = f.uniques.count
            default:
                codes = [Int](repeating: 0, count: n); nUnique = 1
            }
            groupCodes = codes
            nGroups = nUnique
            for c in codes where c < 0 { hasNA = true; break }
        } else {
            groupCodes = [Int](repeating: 0, count: n)
            nGroups = 1
            var validRow = [Bool](repeating: true, count: n)
            for colName in by {
                guard let col = dataFrame.columns[colName] else { continue }
                let (codes, nUnique): ([Int], Int)
                switch col {
                case .double(let a):
                    let f = a.factorize()
                    codes = f.codes; nUnique = f.uniques.count
                case .string(let a):
                    let f = a.factorize()
                    codes = f.codes; nUnique = f.uniques.count
                case .int64(let a):
                    let f = a.factorize()
                    codes = f.codes; nUnique = f.uniques.count
                default:
                    codes = [Int](repeating: 0, count: n); nUnique = 1
                }
                for i in 0..<n {
                    if codes[i] < 0 { validRow[i] = false }
                    else { groupCodes[i] = groupCodes[i] * nUnique + codes[i] }
                }
                nGroups *= nUnique
            }
            hasNA = !validRow.allSatisfy { $0 }
            if hasNA {
                for i in 0..<n where !validRow[i] { groupCodes[i] = -1 }
            }
        }

        // Compact codes and find first row per group
        let actualGroups: Int
        var firstRowForGroup: [Int]

        if by.count == 1 && !hasNA {
            actualGroups = nGroups
            firstRowForGroup = [Int](repeating: -1, count: actualGroups)
            groupCodes.withUnsafeBufferPointer { codesBuf in
                for i in 0..<n {
                    let g = codesBuf[i]
                    if firstRowForGroup[g] < 0 { firstRowForGroup[g] = i }
                }
            }
        } else {
            var codeMap = [Int: Int]()
            var denseCode = 0
            firstRowForGroup = [Int]()
            for i in 0..<n {
                let code = groupCodes[i]
                guard code >= 0 else { continue }
                if codeMap[code] == nil {
                    codeMap[code] = denseCode
                    firstRowForGroup.append(i)
                    denseCode += 1
                }
                groupCodes[i] = codeMap[code]!
            }
            actualGroups = denseCode
        }

        // Sort groups by their key values
        let sortedGroupIndices: [Int]
        if actualGroups > 0, by.count == 1, let col = dataFrame.columns[by[0]] {
            switch col {
            case .string(let a):
                let groupKeyValues = firstRowForGroup.map { a[$0] ?? "" }
                sortedGroupIndices = (0..<actualGroups).sorted { groupKeyValues[$0] < groupKeyValues[$1] }
            case .double(let a):
                let groupKeyValues = firstRowForGroup.map { a.data[$0] }
                sortedGroupIndices = (0..<actualGroups).sorted { groupKeyValues[$0] < groupKeyValues[$1] }
            case .int64(let a):
                let groupKeyValues = firstRowForGroup.map { a.data[$0] }
                sortedGroupIndices = (0..<actualGroups).sorted { groupKeyValues[$0] < groupKeyValues[$1] }
            default:
                let groupKeyValues = firstRowForGroup.map { col.formattedValue(at: $0) }
                sortedGroupIndices = (0..<actualGroups).sorted { groupKeyValues[$0] < groupKeyValues[$1] }
            }
        } else {
            sortedGroupIndices = Array(0..<actualGroups)
        }

        _groupCodes = groupCodes
        _nGroups = actualGroups
        _firstRowForGroup = firstRowForGroup
        _sortedGroupIndices = sortedGroupIndices
        _hasNA = hasNA
    }

    /// A dictionary mapping composite group-key strings to their constituent
    /// row indices, analogous to ``pandas.GroupBy.groups``.
    ///
    /// Composite keys are formed by joining formatted column values with a
    /// tab character.  Rows containing NA in any group column are excluded.
    ///
    /// - Note: This property re-scans the DataFrame on every access (it is
    ///   not cached).  Prefer the fast-aggregate methods for production
    ///   workloads.
    public var groups: [String: [Int]] {
        var result = [String: [Int]]()
        for i in 0..<dataFrame.rowCount {
            let keyParts = by.map { dataFrame.columns[$0]!.formattedValue(at: i) }
            if keyParts.contains("NA") { continue }
            let key = keyParts.joined(separator: "\t")
            result[key, default: []].append(i)
        }
        return result
    }

    /// Computes the sum of each numeric column within each group.
    ///
    /// Attempts Metal GPU acceleration first; falls back to
    /// ``fastAggregate(_:)`` on the CPU.
    ///
    /// - Returns: A ``DataFrame`` with one row per group and one column per
    ///   numeric column, indexed by group key values.
    public func sum() -> DataFrame {
        if let result = gpuAggregate(.sum) { return result }
        return fastAggregate(.sum)
    }

    /// Computes the arithmetic mean of each numeric column within each
    /// group (`sum / count`).
    ///
    /// Attempts Metal GPU acceleration first; falls back to CPU.
    ///
    /// - Returns: A ``DataFrame`` of per-group means.
    public func mean() -> DataFrame {
        if let result = gpuAggregate(.mean) { return result }
        return fastAggregate(.mean)
    }

    /// Counts the number of non-NA values in each numeric column within
    /// each group.
    ///
    /// Always runs on the CPU — the counting loop is memory-bound and does
    /// not benefit from GPU offload.
    ///
    /// - Returns: A ``DataFrame`` of per-group counts.
    public func count() -> DataFrame {
        return fastAggregate(.count)
    }

    /// Computes the minimum of each numeric column within each group.
    ///
    /// Attempts Metal GPU acceleration first; falls back to CPU.
    ///
    /// - Returns: A ``DataFrame`` of per-group minimums.
    public func min() -> DataFrame {
        if let result = gpuAggregate(.min) { return result }
        return fastAggregate(.min)
    }

    /// Computes the maximum of each numeric column within each group.
    ///
    /// Attempts Metal GPU acceleration first; falls back to CPU.
    ///
    /// - Returns: A ``DataFrame`` of per-group maximums.
    public func max() -> DataFrame {
        if let result = gpuAggregate(.max) { return result }
        return fastAggregate(.max)
    }

    /// Attempts GPU-accelerated aggregation via ``MetalGroupBy``.
    ///
    /// Returns `nil` if Metal is unavailable, the dataset is below the
    /// GPU-dispatch row-count threshold, or the GPU kernel fails for any
    /// reason — the caller should then fall back to ``fastAggregate(_:)``.
    private func gpuAggregate(_ op: MetalGroupBy.AggOp) -> DataFrame? {
        guard MetalDispatch.shouldUseGPU(
            rowCount: dataFrame.rowCount,
            threshold: MetalDispatch.groupByThreshold
        ) else { return nil }
        return MetalGroupBy.aggregate(dataFrame: dataFrame, by: by, op: op)
    }

    // MARK: - Fast Integer-Coded Aggregation

    /// Performs a single-pass aggregation over all numeric columns using the
    /// pre-computed group codes cached in ``init(dataFrame:by:)``.
    ///
    /// ## Two-Pass Design
    ///
    /// 1. **Pass 1 (in `init`)** — Factorize group columns to dense integer
    ///    codes.  This is O(n) and happens once, regardless of how many
    ///    aggregation calls follow.
    /// 2. **Pass 2 (here)** — For each numeric column, iterate over all rows
    ///    and accumulate into group-indexed buffers using the cached codes.
    ///
    /// ## Fast Path: Raw-Pointer Accumulators
    ///
    /// When *both* the group codes and the data column are fully valid (no NA
    /// anywhere), the inner loop uses `UnsafeMutablePointer<Double>` buffers
    /// accessed through `UnsafeBufferPointer` views of the source data.
    /// This eliminates:
    /// - Swift array bounds checking on every iteration.
    /// - Per-element mask lookups.
    /// - Retain/release traffic on reference-counted storage.
    ///
    /// The pointers are allocated with `allocate(capacity:)` and explicitly
    /// deallocated after results are extracted.
    ///
    /// ## Slow Path: Mask-Checked Swift Arrays
    ///
    /// When NA values are present (either in group codes or in the data
    /// column), the loop falls back to `[Double]` accumulators with explicit
    /// `guard g >= 0 && colData.mask[i]` checks.
    ///
    /// - Parameter op: The ``GroupByAggOp`` to perform.
    /// - Returns: A ``DataFrame`` with one row per group, columns for each
    ///   numeric column, and an index derived from the group key values.
    private func fastAggregate(_ op: GroupByAggOp) -> DataFrame {
        let n = dataFrame.rowCount
        let actualGroups = _nGroups

        guard actualGroups > 0 else {
            return DataFrame(columns: by.map { ($0, dataFrame.columns[$0]!.take(indices: [])) })
        }

        // Direct accumulation using cached codes — tight loop, no string processing
        let bySet = Set(by)
        let numericCols = dataFrame.columnNames.filter {
            !bySet.contains($0) && dataFrame.columns[$0]!.isNumeric
        }

        var resultCols = [(String, Column)]()
        resultCols.reserveCapacity(by.count + numericCols.count)

        let sortedFirstRows = _sortedGroupIndices.map { _firstRowForGroup[$0] }
        if by.count > 1 {
            for groupCol in by {
                resultCols.append((groupCol, dataFrame.columns[groupCol]!.take(indices: sortedFirstRows)))
            }
        }

        let allRowsValid = !_hasNA

        for colName in numericCols {
            guard let colData = dataFrame.columns[colName]!.asDouble() else { continue }
            let values: [Double]

            let allColValid = colData.mask.allValid
            let fullyValid = allRowsValid && allColValid

            if fullyValid {
                values = colData.data.withUnsafeBufferPointer { dataBuf in
                    _groupCodes.withUnsafeBufferPointer { codesBuf in
                        switch op {
                        case .sum:
                            let sums = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            sums.initialize(repeating: 0, count: actualGroups)
                            for i in 0..<n { sums[codesBuf[i]] += dataBuf[i] }
                            let result = _sortedGroupIndices.map { sums[$0] }
                            sums.deallocate()
                            return result
                        case .mean:
                            let sums = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            let counts = UnsafeMutablePointer<Int>.allocate(capacity: actualGroups)
                            sums.initialize(repeating: 0, count: actualGroups)
                            counts.initialize(repeating: 0, count: actualGroups)
                            for i in 0..<n {
                                let g = codesBuf[i]
                                sums[g] += dataBuf[i]
                                counts[g] &+= 1
                            }
                            let result = _sortedGroupIndices.map { g in
                                counts[g] > 0 ? sums[g] / Double(counts[g]) : .nan
                            }
                            sums.deallocate(); counts.deallocate()
                            return result
                        case .count:
                            let counts = UnsafeMutablePointer<Int>.allocate(capacity: actualGroups)
                            counts.initialize(repeating: 0, count: actualGroups)
                            for i in 0..<n { counts[codesBuf[i]] &+= 1 }
                            let result = _sortedGroupIndices.map { Double(counts[$0]) }
                            counts.deallocate()
                            return result
                        case .min:
                            let mins = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            mins.initialize(repeating: .infinity, count: actualGroups)
                            for i in 0..<n {
                                let g = codesBuf[i]
                                let v = dataBuf[i]
                                if v < mins[g] { mins[g] = v }
                            }
                            let result = _sortedGroupIndices.map { mins[$0] == .infinity ? .nan : mins[$0] }
                            mins.deallocate()
                            return result
                        case .max:
                            let maxs = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            maxs.initialize(repeating: -.infinity, count: actualGroups)
                            for i in 0..<n {
                                let g = codesBuf[i]
                                let v = dataBuf[i]
                                if v > maxs[g] { maxs[g] = v }
                            }
                            let result = _sortedGroupIndices.map { maxs[$0] == -.infinity ? .nan : maxs[$0] }
                            maxs.deallocate()
                            return result
                        }
                    }
                }
            } else {
                switch op {
                case .sum:
                    var sums = [Double](repeating: 0, count: actualGroups)
                    for i in 0..<n {
                        let g = _groupCodes[i]
                        if g >= 0 && colData.mask[i] { sums[g] += colData.data[i] }
                    }
                    values = _sortedGroupIndices.map { sums[$0] }
                case .mean:
                    var sums = [Double](repeating: 0, count: actualGroups)
                    var counts = [Int](repeating: 0, count: actualGroups)
                    for i in 0..<n {
                        let g = _groupCodes[i]
                        if g >= 0 && colData.mask[i] {
                            sums[g] += colData.data[i]
                            counts[g] += 1
                        }
                    }
                    values = _sortedGroupIndices.map { g in
                        counts[g] > 0 ? sums[g] / Double(counts[g]) : .nan
                    }
                case .count:
                    var counts = [Int](repeating: 0, count: actualGroups)
                    for i in 0..<n {
                        let g = _groupCodes[i]
                        if g >= 0 && colData.mask[i] { counts[g] += 1 }
                    }
                    values = _sortedGroupIndices.map { Double(counts[$0]) }
                case .min:
                    var mins = [Double](repeating: .infinity, count: actualGroups)
                    for i in 0..<n {
                        let g = _groupCodes[i]
                        if g >= 0 && colData.mask[i] && colData.data[i] < mins[g] { mins[g] = colData.data[i] }
                    }
                    values = _sortedGroupIndices.map { mins[$0] == .infinity ? .nan : mins[$0] }
                case .max:
                    var maxs = [Double](repeating: -.infinity, count: actualGroups)
                    for i in 0..<n {
                        let g = _groupCodes[i]
                        if g >= 0 && colData.mask[i] && colData.data[i] > maxs[g] { maxs[g] = colData.data[i] }
                    }
                    values = _sortedGroupIndices.map { maxs[$0] == -.infinity ? .nan : maxs[$0] }
                }
            }

            resultCols.append((colName, .fromDoubles(values)))
        }

        let index: [String]
        if by.count == 1, let col = dataFrame.columns[by[0]] {
            switch col {
            case .string(let a):
                index = sortedFirstRows.map { a[$0] ?? "NA" }
            default:
                index = sortedFirstRows.map { col.formattedValue(at: $0) }
            }
        } else {
            index = (0..<actualGroups).map { "\($0)" }
        }

        return DataFrame(columns: resultCols, index: index)
    }
}
