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

    /// Select rows by boolean mask.
    public func filter(mask: [Bool]) -> DataFrame {
        precondition(mask.count == rowCount, "Mask must have same length as DataFrame")
        let indices = mask.enumerated().compactMap { $1 ? $0 : nil }
        return takeRows(indices)
    }

    /// Take rows at specified integer positions.
    public func takeRows(_ indices: [Int]) -> DataFrame {
        var newColumns = [(String, Column)]()
        for name in columnNames {
            newColumns.append((name, columns[name]!.take(indices: indices)))
        }
        let newIndex = indices.map { indexLabels[$0] }
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

    /// Describe all numeric columns.
    public func describe() -> DataFrame {
        let numericCols = columnNames.filter { columns[$0]!.isNumeric }
        var resultCols = [(String, Column)]()

        for colName in numericCols {
            guard let doubles = columns[colName]!.asDouble() else { continue }
            let stats: [Double] = [
                Double(doubles.validCount),
                doubles.mean() ?? .nan,
                doubles.std(ddof: 1) ?? .nan,
                doubles.min() ?? .nan,
                doubles.max() ?? .nan,
            ]
            resultCols.append((colName, .fromDoubles(stats)))
        }

        return DataFrame(
            columns: resultCols,
            index: ["count", "mean", "std", "min", "max"]
        )
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

    /// Concatenate DataFrames vertically.
    public static func concat(_ frames: [DataFrame]) -> DataFrame {
        guard let first = frames.first else { return DataFrame() }
        let colNames = first.columnNames

        var resultCols = [(String, Column)]()
        var resultIndex = [String]()

        for name in colNames {
            var allValues = [Double?]()
            for frame in frames {
                guard case .double(let arr) = frame.columns[name] else { continue }
                for i in 0..<arr.count {
                    allValues.append(arr[i])
                }
            }
            resultCols.append((name, .fromOptionalDoubles(allValues)))
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

        // Build lookup from right key -> [row indices]
        var rightLookup = [String: [Int]]()
        for i in 0..<right.rowCount {
            let k = rightCol.formattedValue(at: i)
            rightLookup[k, default: []].append(i)
        }

        var leftIndices = [Int]()
        var rightIndices = [Int]()

        for i in 0..<rowCount {
            let k = leftCol.formattedValue(at: i)
            if let matches = rightLookup[k] {
                for j in matches {
                    leftIndices.append(i)
                    rightIndices.append(j)
                }
            } else if how == .left || how == .outer {
                leftIndices.append(i)
                rightIndices.append(-1)
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

    /// Group by a column, returning a GroupBy object.
    public func groupBy(_ column: String) -> GroupBy {
        GroupBy(dataFrame: self, by: column)
    }

    // MARK: - Description

    public var description: String {
        guard !isEmpty else { return "Empty DataFrame" }

        // Calculate column widths
        var colWidths = [String: Int]()
        for name in columnNames {
            colWidths[name] = name.count
        }
        let maxRows = Swift.min(rowCount, 20)
        for i in 0..<maxRows {
            for name in columnNames {
                let val = columns[name]!.formattedValue(at: i)
                colWidths[name] = Swift.max(colWidths[name]!, val.count)
            }
        }

        let indexWidth = indexLabels.prefix(maxRows).map { $0.count }.max() ?? 0

        // Header
        var lines = [String]()
        let header = String(repeating: " ", count: indexWidth + 2) +
            columnNames.map { $0.padding(toLength: colWidths[$0]!, withPad: " ", startingAt: 0) }
            .joined(separator: "  ")
        lines.append(header)

        // Rows
        for i in 0..<maxRows {
            let idx = indexLabels[i].padding(toLength: indexWidth, withPad: " ", startingAt: 0)
            let vals = columnNames.map { name in
                columns[name]!.formattedValue(at: i)
                    .padding(toLength: colWidths[name]!, withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
            lines.append("\(idx)  \(vals)")
        }

        if rowCount > maxRows {
            lines.append("... (\(rowCount) rows x \(columnCount) columns)")
        }

        lines.append("\n[\(rowCount) rows x \(columnCount) columns]")
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

/// GroupBy object for split-apply-combine operations.
public struct GroupBy: Sendable {
    public let dataFrame: DataFrame
    public let by: String

    /// The group keys and their row indices.
    public var groups: [String: [Int]] {
        var result = [String: [Int]]()
        guard let col = dataFrame.columns[by] else { return result }
        for i in 0..<dataFrame.rowCount {
            let key = col.formattedValue(at: i)
            if key != "NA" {
                result[key, default: []].append(i)
            }
        }
        return result
    }

    /// Aggregate with sum.
    public func sum() -> DataFrame {
        aggregate { $0.sum() ?? .nan }
    }

    /// Aggregate with mean.
    public func mean() -> DataFrame {
        aggregate { $0.mean() ?? .nan }
    }

    /// Aggregate with count.
    public func count() -> DataFrame {
        aggregate { Double($0.validCount) }
    }

    /// Aggregate with min.
    public func min() -> DataFrame {
        aggregate { $0.min() ?? .nan }
    }

    /// Aggregate with max.
    public func max() -> DataFrame {
        aggregate { $0.max() ?? .nan }
    }

    /// Generic aggregation.
    private func aggregate(_ fn: (NullableArray<Double>) -> Double) -> DataFrame {
        let grps = groups
        let sortedKeys = grps.keys.sorted()
        let numericCols = dataFrame.columnNames.filter {
            $0 != by && dataFrame.columns[$0]!.isNumeric
        }

        var resultCols = [(String, Column)]()
        for colName in numericCols {
            guard let colData = dataFrame.columns[colName]!.asDouble() else { continue }
            var values = [Double]()
            for key in sortedKeys {
                let indices = grps[key]!
                let groupValues: [Double?] = indices.map { colData[$0] }
                let groupArray = NullableArray<Double>(groupValues)
                values.append(fn(groupArray))
            }
            resultCols.append((colName, .fromDoubles(values)))
        }

        return DataFrame(columns: resultCols, index: sortedKeys)
    }
}
