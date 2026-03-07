/// 2D labeled tabular data structure — the Swift equivalent of pandas.DataFrame.
///
/// Stores data in column-oriented format. Each column is a `Column` enum
/// (defaulting to Double for numeric data). Uses value semantics with
/// copy-on-write for efficient passing.
public struct DataFrame: CustomStringConvertible, Sendable {
    /// Ordered column names.
    public private(set) var columnNames: [String]

    /// Column data keyed by name.
    internal var columns: [String: Column]

    /// Row index labels.
    public var indexLabels: [String]

    // MARK: - Initializers

    /// Create an empty DataFrame.
    public init() {
        self.columnNames = []
        self.columns = [:]
        self.indexLabels = []
    }

    /// Create from a dictionary of Double arrays.
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
        self.indexLabels = (0..<rowCount).map { "\($0)" }
    }

    /// Create from a dictionary of optional Double arrays.
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
        self.indexLabels = (0..<rowCount).map { "\($0)" }
    }

    /// Create from explicit columns and index.
    public init(columns: [(String, Column)], index: [String]? = nil) {
        let rowCount = columns.first?.1.count ?? 0
        self.columnNames = columns.map { $0.0 }
        self.columns = [:]
        for (name, col) in columns {
            precondition(col.count == rowCount, "All columns must have same length")
            self.columns[name] = col
        }
        self.indexLabels = index ?? (0..<rowCount).map { "\($0)" }
    }

    /// Create from an array of dictionaries (records).
    public init(records: [[String: Double]]) {
        let allKeys = records.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
        let sortedKeys = allKeys.sorted()

        self.columnNames = sortedKeys
        self.columns = [:]

        for key in sortedKeys {
            let values: [Double?] = records.map { $0[key] }
            self.columns[key] = .fromOptionalDoubles(values)
        }
        self.indexLabels = (0..<records.count).map { "\($0)" }
    }

    // MARK: - Shape

    /// Number of rows.
    public var rowCount: Int {
        columns.values.first?.count ?? 0
    }

    /// Number of columns.
    public var columnCount: Int {
        columnNames.count
    }

    /// Shape as (rows, columns).
    public var shape: (rows: Int, columns: Int) {
        (rowCount, columnCount)
    }

    /// Whether the DataFrame is empty.
    public var isEmpty: Bool {
        rowCount == 0 || columnCount == 0
    }

    /// Dtypes for each column.
    public var dtypes: [(name: String, dtype: DTypeEnum)] {
        columnNames.map { ($0, columns[$0]!.dtype) }
    }

    // MARK: - Column access

    /// Access a column by name, returning a Series.
    public subscript(column: String) -> Series {
        get {
            guard let col = columns[column] else {
                fatalError("Column '\(column)' not found")
            }
            return Series(data: col, index: indexLabels, name: column)
        }
        set {
            precondition(newValue.count == rowCount || columnCount == 0,
                        "New column must have same length as DataFrame")
            if !columnNames.contains(column) {
                columnNames.append(column)
            }
            columns[column] = newValue.data
            if columnCount == 1 {
                indexLabels = newValue.indexLabels
            }
        }
    }

    /// Select multiple columns, returning a new DataFrame.
    public func select(columns names: [String]) -> DataFrame {
        var result = DataFrame()
        result.indexLabels = indexLabels
        result.columnNames = names
        for name in names {
            guard let col = columns[name] else {
                fatalError("Column '\(name)' not found")
            }
            result.columns[name] = col
        }
        return result
    }

    /// Drop columns by name.
    public func drop(columns names: [String]) -> DataFrame {
        let remaining = columnNames.filter { !names.contains($0) }
        return select(columns: remaining)
    }

    /// Rename columns.
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

    // MARK: - Row access (iloc)

    /// Select rows by integer position range.
    public func iloc(_ range: Range<Int>) -> DataFrame {
        let indices = Array(range)
        return takeRows(indices)
    }

    /// Select a single row by integer position, returning a dictionary.
    public func iloc(_ position: Int) -> [String: Any?] {
        precondition(position >= 0 && position < rowCount, "Position out of range")
        var row = [String: Any?]()
        for name in columnNames {
            row[name] = columns[name]!.value(at: position)
        }
        return row
    }

    // MARK: - Row access (loc — label-based)

    /// Select a single row by label, returning a dictionary.
    public func loc(_ label: String) -> [String: Any?]? {
        guard let pos = indexLabels.firstIndex(of: label) else { return nil }
        return iloc(pos)
    }

    /// Select multiple rows by labels.
    public func loc(_ labels: [String]) -> DataFrame {
        let indices = labels.compactMap { label in indexLabels.firstIndex(of: label) }
        return takeRows(indices)
    }

    // MARK: - Boolean mask filtering

    /// Select rows by boolean mask.
    public func filter(mask: [Bool]) -> DataFrame {
        precondition(mask.count == rowCount, "Mask must have same length as DataFrame")
        // Scan the branchy mask ONCE to build sorted indices.
        // Reuse indices for all columns — avoids N+1 misprediction-heavy mask scans.
        var trueCount = 0
        mask.withUnsafeBufferPointer { m in
            for i in 0..<m.count { if m[i] { trueCount += 1 } }
        }
        let indices = [Int](unsafeUninitializedCapacity: trueCount) { dst, count in
            mask.withUnsafeBufferPointer { m in
                var j = 0
                for i in 0..<m.count {
                    if m[i] {
                        (dst.baseAddress! + j).initialize(to: i)
                        j += 1
                    }
                }
                count = j
            }
        }
        return takeRows(indices)
    }

    /// Subscript with a boolean mask — enables `df[df["age"] > 30]` syntax.
    public subscript(mask: [Bool]) -> DataFrame {
        filter(mask: mask)
    }

    /// Take rows at specified integer positions.
    public func takeRows(_ indices: [Int]) -> DataFrame {
        var newColumns = [(String, Column)]()
        newColumns.reserveCapacity(columnNames.count)
        for name in columnNames {
            newColumns.append((name, columns[name]!.take(indices: indices)))
        }
        // Gather index labels with raw pointer access on indices
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

    public func head(_ n: Int = 5) -> DataFrame {
        iloc(0..<Swift.min(n, rowCount))
    }

    public func tail(_ n: Int = 5) -> DataFrame {
        let start = Swift.max(0, rowCount - n)
        return iloc(start..<rowCount)
    }

    // MARK: - Sorting

    /// Sort by values in multiple columns (leftmost column is primary sort key).
    public func sortValues(by sortColumns: [String], ascending: [Bool]? = nil) -> DataFrame {
        let ascFlags = ascending ?? [Bool](repeating: true, count: sortColumns.count)
        precondition(ascFlags.count == sortColumns.count, "ascending array must match columns count")

        let indices = Array(0..<rowCount).sorted { i, j in
            for (colIdx, colName) in sortColumns.enumerated() {
                guard let col = columns[colName] else { continue }
                let asc = ascFlags[colIdx]
                switch col {
                case .double(let a):
                    let iValid = a.mask[i], jValid = a.mask[j]
                    if !iValid && !jValid { continue }
                    if !iValid { return false } // NAs to end
                    if !jValid { return true }
                    if a.data[i] != a.data[j] {
                        return asc ? a.data[i] < a.data[j] : a.data[i] > a.data[j]
                    }
                case .string(let a):
                    let iVal = a[i], jVal = a[j]
                    if iVal == nil && jVal == nil { continue }
                    if iVal == nil { return false }
                    if jVal == nil { return true }
                    if iVal! != jVal! {
                        return asc ? iVal! < jVal! : iVal! > jVal!
                    }
                case .int64(let a):
                    let iValid = a.mask[i], jValid = a.mask[j]
                    if !iValid && !jValid { continue }
                    if !iValid { return false }
                    if !jValid { return true }
                    if a.data[i] != a.data[j] {
                        return asc ? a.data[i] < a.data[j] : a.data[i] > a.data[j]
                    }
                default:
                    continue
                }
            }
            return false // equal on all sort keys
        }
        return takeRows(indices)
    }

    /// Sort by values in a column.
    public func sortValues(by column: String, ascending: Bool = true) -> DataFrame {
        guard let col = columns[column] else {
            fatalError("Column '\(column)' not found")
        }
        let indices: [Int]
        switch col {
        case .double(let a):
            let validPositions = (0..<a.count).filter { a.mask[$0] }
            let naPositions = (0..<a.count).filter { !a.mask[$0] }
            let validValues = validPositions.map { a.data[$0] }
            let sortedValid = validValues.enumerated()
                .sorted { ascending ? $0.element < $1.element : $0.element > $1.element }
                .map { validPositions[$0.offset] }
            indices = sortedValid + naPositions
        case .string(let a):
            indices = a.argsort(ascending: ascending)
        case .int64(let a):
            let validPositions = (0..<a.count).filter { a.mask[$0] }
            let naPositions = (0..<a.count).filter { !a.mask[$0] }
            let validValues = validPositions.map { a.data[$0] }
            let sortedValid = validValues.enumerated()
                .sorted { ascending ? $0.element < $1.element : $0.element > $1.element }
                .map { validPositions[$0.offset] }
            indices = sortedValid + naPositions
        default:
            return self
        }
        return takeRows(indices)
    }

    // MARK: - Aggregations

    /// Sum of each numeric column.
    public func sum() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.sum() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Mean of each numeric column.
    public func mean() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.mean() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Std of each numeric column.
    public func std(ddof: Int = 1) -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.std(ddof: ddof) ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Min of each numeric column.
    public func min() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.min() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Max of each numeric column.
    public func max() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { columns[$0]!.max() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Median of each numeric column.
    public func median() -> Series {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        let values = numericCols.map { self[$0].median() ?? .nan }
        return Series(data: .fromDoubles(values), index: numericCols, name: nil)
    }

    /// Describe all numeric columns (with quartiles like pandas).
    public func describe() -> DataFrame {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        var resultCols = [(String, Column)]()

        for colName in numericCols {
            let s = self[colName]
            guard let doubles = columns[colName]!.asDouble() else { continue }
            let stats: [Double] = [
                Double(doubles.validCount),
                doubles.mean() ?? .nan,
                doubles.std(ddof: 1) ?? .nan,
                doubles.min() ?? .nan,
                s.quantile(0.25) ?? .nan,
                s.median() ?? .nan,
                s.quantile(0.75) ?? .nan,
                doubles.max() ?? .nan,
            ]
            resultCols.append((colName, .fromDoubles(stats)))
        }

        return DataFrame(
            columns: resultCols,
            index: ["count", "mean", "std", "min", "25%", "50%", "75%", "max"]
        )
    }

    // MARK: - Duplicates

    /// Boolean mask: true where the row is a duplicate based on the given columns.
    public func duplicated(subset: [String]? = nil) -> [Bool] {
        let cols = subset ?? columnNames
        var seen = Set<String>()
        return (0..<rowCount).map { i in
            let key = cols.map { columns[$0]!.formattedValue(at: i) }.joined(separator: "\t")
            return !seen.insert(key).inserted
        }
    }

    /// Drop duplicate rows, keeping first occurrence.
    public func dropDuplicates(subset: [String]? = nil) -> DataFrame {
        let dupes = duplicated(subset: subset)
        let keepIndices = dupes.enumerated().compactMap { !$1 ? $0 : nil }
        return takeRows(keepIndices)
    }

    // MARK: - Apply

    /// Apply a function to each column.
    public func apply(_ transform: (Series) -> Series) -> DataFrame {
        var resultCols = [(String, Column)]()
        for name in columnNames {
            let series = self[name]
            let transformed = transform(series)
            resultCols.append((name, transformed.data))
        }
        return DataFrame(columns: resultCols, index: indexLabels)
    }

    // MARK: - Concat

    /// Concatenate DataFrames vertically (supports all column types).
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

        for frame in frames {
            resultIndex.append(contentsOf: frame.indexLabels)
        }

        return DataFrame(columns: resultCols, index: resultIndex)
    }

    // MARK: - Merge

    /// Merge with another DataFrame on a key column (inner join by default).
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

    /// Group by a single column, returning a GroupBy object.
    public func groupBy(_ column: String) -> GroupBy {
        GroupBy(dataFrame: self, by: [column])
    }

    /// Group by multiple columns, returning a GroupBy object.
    public func groupBy(_ groupColumns: [String]) -> GroupBy {
        GroupBy(dataFrame: self, by: groupColumns)
    }

    // MARK: - Description

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

// MARK: - Merge type

public enum MergeHow: Sendable {
    case inner
    case left
    case right
    case outer
}

// MARK: - GroupBy

/// Aggregation operation type for optimized GroupBy.
public enum GroupByAggOp: Sendable {
    case sum, mean, count, min, max
}

/// GroupBy object for split-apply-combine operations.
/// Supports grouping by one or more columns.
/// Uses integer-coded factorize for fast hashing instead of string keys.
public struct GroupBy: Sendable {
    public let dataFrame: DataFrame
    public let by: [String]

    /// The group keys (composite key string) and their row indices.
    /// Retained for backward compatibility; internal fast paths use factorize.
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

    /// Aggregate with sum.
    public func sum() -> DataFrame {
        if let result = gpuAggregate(.sum) { return result }
        return fastAggregate(.sum)
    }

    /// Aggregate with mean.
    public func mean() -> DataFrame {
        if let result = gpuAggregate(.mean) { return result }
        return fastAggregate(.mean)
    }

    /// Aggregate with count. CPU-only (no GPU overhead for simple counting).
    public func count() -> DataFrame {
        return fastAggregate(.count)
    }

    /// Aggregate with min.
    public func min() -> DataFrame {
        if let result = gpuAggregate(.min) { return result }
        return fastAggregate(.min)
    }

    /// Aggregate with max.
    public func max() -> DataFrame {
        if let result = gpuAggregate(.max) { return result }
        return fastAggregate(.max)
    }

    /// Try GPU-accelerated aggregation; returns nil if unavailable or below threshold.
    private func gpuAggregate(_ op: MetalGroupBy.AggOp) -> DataFrame? {
        guard MetalDispatch.shouldUseGPU(
            rowCount: dataFrame.rowCount,
            threshold: MetalDispatch.groupByThreshold
        ) else { return nil }
        return MetalGroupBy.aggregate(dataFrame: dataFrame, by: by, op: op)
    }

    // MARK: - Fast integer-coded aggregation

    /// Factorize group columns to integer codes, then aggregate with direct accumulation.
    private func fastAggregate(_ op: GroupByAggOp) -> DataFrame {
        let n = dataFrame.rowCount

        // Step 1: Factorize group columns to integer codes
        var groupCodes: [Int]
        var nGroups: Int
        var hasNA = false

        if by.count == 1 {
            // Single-column fast path: codes are already dense [0, nUnique)
            guard let col = dataFrame.columns[by[0]] else {
                return DataFrame(columns: by.map { ($0, dataFrame.columns[$0]!.take(indices: [])) })
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
            // Check for NAs (code == -1)
            for c in codes where c < 0 { hasNA = true; break }
        } else {
            // Multi-column: build composite codes
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
            // Mark NA rows with -1 code
            if hasNA {
                for i in 0..<n where !validRow[i] { groupCodes[i] = -1 }
            }
        }

        // Step 2: Compact group codes to dense range [0, actualGroups)
        // For single-column groupby, codes are already dense — skip dictionary compaction
        let actualGroups: Int
        var firstRowForGroup: [Int]

        if by.count == 1 && !hasNA {
            // Codes are already [0, nGroups) — just find first row per group
            actualGroups = nGroups
            firstRowForGroup = [Int](repeating: -1, count: actualGroups)
            groupCodes.withUnsafeBufferPointer { codesBuf in
                for i in 0..<n {
                    let g = codesBuf[i]
                    if firstRowForGroup[g] < 0 { firstRowForGroup[g] = i }
                }
            }
        } else {
            // General case: compact sparse composite codes via dictionary
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

        guard actualGroups > 0 else {
            return DataFrame(columns: by.map { ($0, dataFrame.columns[$0]!.take(indices: [])) })
        }

        // Step 3: Sort groups by their key values for consistent output
        let sortedGroupIndices: [Int]
        if by.count == 1, let col = dataFrame.columns[by[0]] {
            // Sort by native typed values to avoid String conversion
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
        // Build reverse mapping: sortedPosition[originalDenseCode] = position in output
        var reverseSortMap = [Int](repeating: 0, count: actualGroups)
        for (pos, origIdx) in sortedGroupIndices.enumerated() {
            reverseSortMap[origIdx] = pos
        }

        // Step 4: Direct accumulation — single pass over data per column
        let numericCols = dataFrame.columnNames.filter {
            !by.contains($0) && dataFrame.columns[$0]!.isNumeric
        }

        var resultCols = [(String, Column)]()

        // Build group key columns using sorted firstRowForGroup
        let sortedFirstRows = sortedGroupIndices.map { firstRowForGroup[$0] }
        if by.count > 1 {
            for groupCol in by {
                resultCols.append((groupCol, dataFrame.columns[groupCol]!.take(indices: sortedFirstRows)))
            }
        }

        // Check if all rows have valid keys (common case: no NA in group columns)
        let allRowsValid = !hasNA

        for colName in numericCols {
            guard let colData = dataFrame.columns[colName]!.asDouble() else { continue }
            let values: [Double]

            // Fast-path: no NA keys AND no NA values → skip all validity checks
            let allColValid = colData.mask.allValid
            let fullyValid = allRowsValid && allColValid

            if fullyValid {
                // Fastest path: raw pointers throughout, no bounds checks
                values = colData.data.withUnsafeBufferPointer { dataBuf in
                    groupCodes.withUnsafeBufferPointer { codesBuf in
                        switch op {
                        case .sum:
                            let sums = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            sums.initialize(repeating: 0, count: actualGroups)
                            for i in 0..<n { sums[codesBuf[i]] += dataBuf[i] }
                            let result = sortedGroupIndices.map { sums[$0] }
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
                                counts[g] += 1
                            }
                            let result = sortedGroupIndices.map { g in
                                counts[g] > 0 ? sums[g] / Double(counts[g]) : .nan
                            }
                            sums.deallocate(); counts.deallocate()
                            return result
                        case .count:
                            let counts = UnsafeMutablePointer<Int>.allocate(capacity: actualGroups)
                            counts.initialize(repeating: 0, count: actualGroups)
                            for i in 0..<n { counts[codesBuf[i]] += 1 }
                            let result = sortedGroupIndices.map { Double(counts[$0]) }
                            counts.deallocate()
                            return result
                        case .min:
                            let mins = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            mins.initialize(repeating: .infinity, count: actualGroups)
                            for i in 0..<n {
                                let g = codesBuf[i]
                                if dataBuf[i] < mins[g] { mins[g] = dataBuf[i] }
                            }
                            let result = sortedGroupIndices.map { mins[$0] == .infinity ? .nan : mins[$0] }
                            mins.deallocate()
                            return result
                        case .max:
                            let maxs = UnsafeMutablePointer<Double>.allocate(capacity: actualGroups)
                            maxs.initialize(repeating: -.infinity, count: actualGroups)
                            for i in 0..<n {
                                let g = codesBuf[i]
                                if dataBuf[i] > maxs[g] { maxs[g] = dataBuf[i] }
                            }
                            let result = sortedGroupIndices.map { maxs[$0] == -.infinity ? .nan : maxs[$0] }
                            maxs.deallocate()
                            return result
                        }
                    }
                }
            } else {
                // Slow path: check validity per element (NA keys have code -1)
                switch op {
                case .sum:
                    var sums = [Double](repeating: 0, count: actualGroups)
                    for i in 0..<n {
                        let g = groupCodes[i]
                        if g >= 0 && colData.mask[i] { sums[g] += colData.data[i] }
                    }
                    values = sortedGroupIndices.map { sums[$0] }
                case .mean:
                    var sums = [Double](repeating: 0, count: actualGroups)
                    var counts = [Int](repeating: 0, count: actualGroups)
                    for i in 0..<n {
                        let g = groupCodes[i]
                        if g >= 0 && colData.mask[i] {
                            sums[g] += colData.data[i]
                            counts[g] += 1
                        }
                    }
                    values = sortedGroupIndices.map { g in
                        counts[g] > 0 ? sums[g] / Double(counts[g]) : .nan
                    }
                case .count:
                    var counts = [Int](repeating: 0, count: actualGroups)
                    for i in 0..<n {
                        let g = groupCodes[i]
                        if g >= 0 && colData.mask[i] { counts[g] += 1 }
                    }
                    values = sortedGroupIndices.map { Double(counts[$0]) }
                case .min:
                    var mins = [Double](repeating: .infinity, count: actualGroups)
                    for i in 0..<n {
                        let g = groupCodes[i]
                        if g >= 0 && colData.mask[i] && colData.data[i] < mins[g] { mins[g] = colData.data[i] }
                    }
                    values = sortedGroupIndices.map { mins[$0] == .infinity ? .nan : mins[$0] }
                case .max:
                    var maxs = [Double](repeating: -.infinity, count: actualGroups)
                    for i in 0..<n {
                        let g = groupCodes[i]
                        if g >= 0 && colData.mask[i] && colData.data[i] > maxs[g] { maxs[g] = colData.data[i] }
                    }
                    values = sortedGroupIndices.map { maxs[$0] == -.infinity ? .nan : maxs[$0] }
                }
            }

            resultCols.append((colName, .fromDoubles(values)))
        }

        // For single-column groupBy, use the group key values as the index
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
