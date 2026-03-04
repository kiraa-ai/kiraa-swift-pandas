import Foundation

/// CSV reader that parses CSV text into a DataFrame.
///
/// Supports:
/// - Custom separators (comma, tab, semicolon, etc.)
/// - Optional header row
/// - Automatic type inference (numeric vs string columns)
/// - Quoted fields with escaped quotes
/// - NA/missing value handling
public struct CSVReader: Sendable {
    /// The field separator character.
    public let separator: Character

    /// Whether the first row is a header.
    public let header: Bool

    /// Values to treat as NA/missing.
    public let naValues: Set<String>

    public init(
        separator: Character = ",",
        header: Bool = true,
        naValues: Set<String> = ["", "NA", "N/A", "NaN", "nan", "null", "NULL", "None", "none", "."]
    ) {
        self.separator = separator
        self.header = header
        self.naValues = naValues
    }

    // MARK: - Parsing

    /// Parse CSV text into a DataFrame.
    public func read(from text: String) -> DataFrame {
        let rows = parseRows(text)
        guard !rows.isEmpty else { return DataFrame() }

        let columnNames: [String]
        let dataRows: [[String]]

        if header {
            columnNames = rows[0]
            dataRows = Array(rows.dropFirst())
        } else {
            columnNames = (0..<rows[0].count).map { "col_\($0)" }
            dataRows = rows
        }

        guard !dataRows.isEmpty else {
            return DataFrame(columns: columnNames.map { ($0, Column.fromDoubles([])) })
        }

        // Build columns
        var resultColumns = [(String, Column)]()
        for (colIdx, name) in columnNames.enumerated() {
            let rawValues = dataRows.map { colIdx < $0.count ? $0[colIdx] : "" }

            // Try to parse as numeric (Double)
            var allNumeric = true
            var doubleValues = [Double?]()
            doubleValues.reserveCapacity(rawValues.count)

            for val in rawValues {
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                if naValues.contains(trimmed) {
                    doubleValues.append(nil)
                } else if let d = Double(trimmed) {
                    doubleValues.append(d)
                } else {
                    allNumeric = false
                    break
                }
            }

            if allNumeric {
                resultColumns.append((name, .fromOptionalDoubles(doubleValues)))
            } else {
                let stringValues: [String?] = rawValues.map { val in
                    let trimmed = val.trimmingCharacters(in: .whitespaces)
                    return naValues.contains(trimmed) ? nil : trimmed
                }
                resultColumns.append((name, .fromOptionalStrings(stringValues)))
            }
        }

        return DataFrame(columns: resultColumns)
    }

    /// Parse CSV text from a file URL.
    public func read(from url: URL) throws -> DataFrame {
        let text = try String(contentsOf: url, encoding: .utf8)
        return read(from: text)
    }

    /// Parse CSV text from a file path.
    public func read(fromPath path: String) throws -> DataFrame {
        let url = URL(fileURLWithPath: path)
        return try read(from: url)
    }

    // MARK: - Row parsing

    /// Parse CSV text into rows of string fields, handling quoted fields.
    private func parseRows(_ text: String) -> [[String]] {
        var rows = [[String]]()
        var currentField = ""
        var currentRow = [String]()
        var inQuotes = false
        var previousWasQuote = false
        let sep = separator

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]

            if inQuotes {
                if ch == "\"" {
                    // Check for escaped quote ("")
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        previousWasQuote = true
                    }
                } else {
                    currentField.append(ch)
                }
            } else {
                if ch == "\"" && currentField.isEmpty && !previousWasQuote {
                    inQuotes = true
                } else if ch == sep {
                    currentRow.append(currentField)
                    currentField = ""
                    previousWasQuote = false
                } else if ch == "\n" {
                    // Handle \r\n
                    if !currentField.isEmpty && currentField.last == "\r" {
                        currentField.removeLast()
                    }
                    currentRow.append(currentField)
                    if !currentRow.allSatisfy({ $0.isEmpty }) || !rows.isEmpty {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                    previousWasQuote = false
                } else if ch == "\r" {
                    // Skip standalone \r, will be handled with \n or end
                } else {
                    currentField.append(ch)
                    previousWasQuote = false
                }
            }
            i += 1
        }

        // Handle last field/row
        if !currentField.isEmpty || !currentRow.isEmpty {
            if currentField.hasSuffix("\r") {
                currentField.removeLast()
            }
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows
    }
}

// MARK: - CSVWriter

/// Writes a DataFrame to CSV format.
public struct CSVWriter: Sendable {
    public let separator: String
    public let includeHeader: Bool
    public let includeIndex: Bool
    public let naRepresentation: String

    public init(
        separator: String = ",",
        includeHeader: Bool = true,
        includeIndex: Bool = false,
        naRepresentation: String = ""
    ) {
        self.separator = separator
        self.includeHeader = includeHeader
        self.includeIndex = includeIndex
        self.naRepresentation = naRepresentation
    }

    /// Write a DataFrame to CSV text.
    public func write(_ df: DataFrame) -> String {
        var lines = [String]()

        // Header
        if includeHeader {
            var headerParts = [String]()
            if includeIndex { headerParts.append("") }
            headerParts.append(contentsOf: df.columnNames)
            lines.append(headerParts.joined(separator: separator))
        }

        // Data rows
        for i in 0..<df.rowCount {
            var parts = [String]()
            if includeIndex {
                parts.append(df.indexLabels[i])
            }
            for name in df.columnNames {
                let col = df.columns[name]!
                let val = col.formattedValue(at: i)
                if val == "NA" {
                    parts.append(naRepresentation)
                } else if val.contains(separator) || val.contains("\"") || val.contains("\n") {
                    parts.append("\"\(val.replacingOccurrences(of: "\"", with: "\"\""))\"")
                } else {
                    parts.append(val)
                }
            }
            lines.append(parts.joined(separator: separator))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Write a DataFrame to a file.
    public func write(_ df: DataFrame, to url: URL) throws {
        let text = write(df)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Write a DataFrame to a file path.
    public func write(_ df: DataFrame, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try write(df, to: url)
    }
}

// MARK: - DataFrame convenience methods

extension DataFrame {
    /// Read a DataFrame from CSV text.
    public static func readCSV(
        _ text: String,
        separator: Character = ",",
        header: Bool = true
    ) -> DataFrame {
        let reader = CSVReader(separator: separator, header: header)
        return reader.read(from: text)
    }

    /// Read a DataFrame from a CSV file path.
    public static func readCSV(
        path: String,
        separator: Character = ",",
        header: Bool = true
    ) throws -> DataFrame {
        let reader = CSVReader(separator: separator, header: header)
        return try reader.read(fromPath: path)
    }

    /// Write this DataFrame to CSV text.
    public func toCSV(
        separator: String = ",",
        header: Bool = true,
        index: Bool = false
    ) -> String {
        let writer = CSVWriter(separator: separator, includeHeader: header, includeIndex: index)
        return writer.write(self)
    }

    /// Write this DataFrame to a CSV file path.
    public func toCSV(
        path: String,
        separator: String = ",",
        header: Bool = true,
        index: Bool = false
    ) throws {
        let writer = CSVWriter(separator: separator, includeHeader: header, includeIndex: index)
        try writer.write(self, toPath: path)
    }
}
