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

        // Build columns with fast type inference
        var resultColumns = [(String, Column)]()
        resultColumns.reserveCapacity(columnNames.count)
        for (colIdx, name) in columnNames.enumerated() {
            // Try to parse as numeric (Double)
            var allNumeric = true
            var doubleValues = [Double?]()
            doubleValues.reserveCapacity(dataRows.count)

            for row in dataRows {
                let val = colIdx < row.count ? row[colIdx] : ""
                if val.isEmpty || naValues.contains(val) {
                    doubleValues.append(nil)
                } else if let d = Double(val) {
                    doubleValues.append(d)
                } else {
                    allNumeric = false
                    break
                }
            }

            if allNumeric {
                resultColumns.append((name, .fromOptionalDoubles(doubleValues)))
            } else {
                var stringValues = [String?]()
                stringValues.reserveCapacity(dataRows.count)
                for row in dataRows {
                    let val = colIdx < row.count ? row[colIdx] : ""
                    stringValues.append(val.isEmpty || naValues.contains(val) ? nil : val)
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

    /// Parse CSV text into rows of string fields using byte-level UTF-8 scanning.
    /// Operates on raw bytes for speed — avoids Character conversion overhead.
    private func parseRows(_ text: String) -> [[String]] {
        let sepByte = separator.asciiValue!

        return text.utf8.withContiguousStorageIfAvailable { utf8Buf -> [[String]] in
            let bytes = utf8Buf
            let count = bytes.count
            var rows = [[String]]()
            rows.reserveCapacity(count / 40 + 1) // estimate ~40 bytes per row
            var currentRow = [String]()
            var fieldStart = 0
            var inQuotes = false
            var hasQuotes = false // whether current field contains escaped quotes
            var i = 0

            while i < count {
                let b = bytes[i]

                if inQuotes {
                    if b == 0x22 { // "
                        if i + 1 < count && bytes[i + 1] == 0x22 {
                            // Escaped quote ""
                            hasQuotes = true
                            i += 2
                            continue
                        } else {
                            inQuotes = false
                        }
                    }
                    i += 1
                    continue
                }

                if b == 0x22 && (i == fieldStart || (i == fieldStart + 1 && i > 0 && bytes[fieldStart] == 0x0D)) { // " at field start
                    inQuotes = true
                    i += 1
                    continue
                }

                if b == sepByte {
                    currentRow.append(extractField(bytes, from: fieldStart, to: i, hasEscapedQuotes: hasQuotes))
                    fieldStart = i + 1
                    hasQuotes = false
                    i += 1
                    continue
                }

                if b == 0x0A { // \n
                    var end = i
                    if end > fieldStart && bytes[end - 1] == 0x0D { end -= 1 } // \r\n
                    currentRow.append(extractField(bytes, from: fieldStart, to: end, hasEscapedQuotes: hasQuotes))
                    if !currentRow.allSatisfy({ $0.isEmpty }) || !rows.isEmpty {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    fieldStart = i + 1
                    hasQuotes = false
                    i += 1
                    continue
                }

                i += 1
            }

            // Handle last field/row
            if fieldStart <= count {
                var end = count
                if end > fieldStart && bytes[end - 1] == 0x0D { end -= 1 }
                let field = fieldStart < end ? extractField(bytes, from: fieldStart, to: end, hasEscapedQuotes: hasQuotes) : ""
                if !field.isEmpty || !currentRow.isEmpty {
                    currentRow.append(field)
                    rows.append(currentRow)
                }
            }

            return rows
        } ?? parseRowsFallback(text)
    }

    /// Extract a field from byte range, handling quoted fields.
    private func extractField(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int, to end: Int,
        hasEscapedQuotes: Bool
    ) -> String {
        var s = start
        var e = end
        // Strip surrounding quotes
        if e > s && bytes[s] == 0x22 {
            s += 1
            if e > s && bytes[e - 1] == 0x22 { e -= 1 }
        }
        guard s < e else { return "" }

        if hasEscapedQuotes {
            // Replace "" with " in the field
            var result = [UInt8]()
            result.reserveCapacity(e - s)
            var j = s
            while j < e {
                if bytes[j] == 0x22 && j + 1 < e && bytes[j + 1] == 0x22 {
                    result.append(0x22)
                    j += 2
                } else {
                    result.append(bytes[j])
                    j += 1
                }
            }
            return String(bytes: result, encoding: .utf8) ?? ""
        }

        // Fast path: no escaped quotes, just create string from byte range
        return String(bytes: UnsafeBufferPointer(rebasing: bytes[s..<e]), encoding: .utf8) ?? ""
    }

    /// Fallback Character-based parser when contiguous UTF-8 storage is unavailable.
    private func parseRowsFallback(_ text: String) -> [[String]] {
        var rows = [[String]]()
        var currentField = ""
        var currentRow = [String]()
        var inQuotes = false
        var previousWasQuote = false
        let sep = separator

        for ch in text {
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                    previousWasQuote = true
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
                    // skip
                } else {
                    currentField.append(ch)
                    previousWasQuote = false
                }
            }
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            if currentField.hasSuffix("\r") { currentField.removeLast() }
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
