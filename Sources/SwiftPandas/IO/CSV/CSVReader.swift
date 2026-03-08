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

    /// Byte range of a field within the UTF-8 buffer.
    private struct FieldRange {
        let start: Int
        let end: Int
        let hasEscapedQuotes: Bool
    }

    /// Flat grid of field ranges: fields[row * colCount + col].
    private struct FieldGrid {
        var fields: ContiguousArray<FieldRange>
        var rowCount: Int
        var colCount: Int

        @inline(__always)
        func field(row: Int, col: Int) -> FieldRange {
            fields[row &* colCount &+ col]
        }
    }

    // MARK: - Parsing

    /// Parse CSV text into a DataFrame.
    public func read(from text: String) -> DataFrame {
        // Fast path: use byte-level parsing with field ranges (no String allocation)
        if let result = text.utf8.withContiguousStorageIfAvailable({ utf8Buf -> DataFrame in
            return readFromBytes(utf8Buf)
        }) {
            return result
        }
        // Fallback: character-based parsing
        return readFallback(text)
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

    // MARK: - Fast byte-level parsing

    /// Strip quotes from a field range, returning adjusted start/end.
    @inline(__always)
    private static func stripQuotes(
        _ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int
    ) -> (Int, Int) {
        var s = start
        var e = end
        if e > s && bytes[s] == 0x22 {
            s += 1
            if e > s && bytes[e - 1] == 0x22 { e -= 1 }
        }
        return (s, e)
    }

    /// Parse CSV from a contiguous UTF-8 buffer using byte ranges (no String allocation for numeric fields).
    private func readFromBytes(_ bytes: UnsafeBufferPointer<UInt8>) -> DataFrame {
        let grid = parseFieldGrid(bytes)
        guard grid.rowCount > 0 else { return DataFrame() }

        let columnNames: [String]
        let dataStartRow: Int

        if header {
            columnNames = (0..<grid.colCount).map { extractString(bytes, field: grid.field(row: 0, col: $0)) }
            dataStartRow = 1
        } else {
            columnNames = (0..<grid.colCount).map { "col_\($0)" }
            dataStartRow = 0
        }

        let rowCount = grid.rowCount - dataStartRow
        guard rowCount > 0 else {
            return DataFrame(columns: columnNames.map { ($0, Column.fromDoubles([])) })
        }

        // Allocate a reusable buffer for strtod fallback (avoids per-cell allocation)
        let strtodBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { strtodBuf.deallocate() }

        // Build columns with fast type inference
        var resultColumns = [(String, Column)]()
        resultColumns.reserveCapacity(columnNames.count)

        // Check if using default NA values for fast-path matching
        let useDefaultNA = (naValues == ["", "NA", "N/A", "NaN", "nan", "null", "NULL", "None", "none", "."])

        // Pre-compute NA byte patterns only if non-default
        let naBytePatterns: [[UInt8]] = useDefaultNA ? [] : naValues.map { Array($0.utf8) }

        let colCount = grid.colCount

        for (colIdx, name) in columnNames.enumerated() {
            guard colIdx < colCount else { continue }

            var allNumeric = true
            var doubles = ContiguousArray<Double>()
            doubles.reserveCapacity(rowCount)
            var hasNA = false
            var naRows = ContiguousArray<Int>()

            for rowIdx in 0..<rowCount {
                let field = grid.field(row: dataStartRow + rowIdx, col: colIdx)
                let (s, e) = Self.stripQuotes(bytes, start: field.start, end: field.end)
                let fieldLen = e - s

                let isNA: Bool
                if useDefaultNA {
                    isNA = Self.isNADefault(bytes, start: s, length: fieldLen)
                } else {
                    isNA = fieldLen == 0 || Self.isNACustom(bytes, start: s, length: fieldLen, patterns: naBytePatterns)
                }

                if isNA {
                    doubles.append(0.0)
                    naRows.append(rowIdx)
                    hasNA = true
                } else {
                    let (success, value) = Self.fastParseDouble(bytes, start: s, end: e, strtodBuf: strtodBuf)
                    if success {
                        doubles.append(value)
                    } else {
                        allNumeric = false
                        break
                    }
                }
            }

            if allNumeric {
                let mask: BitVector
                if hasNA {
                    var bits = BitVector(repeating: true, count: rowCount)
                    for idx in naRows { bits[idx] = false }
                    mask = bits
                } else {
                    mask = BitVector(repeating: true, count: rowCount)
                }
                let na = NullableArray(data: NativeArray(doubles), mask: mask)
                resultColumns.append((name, .double(na)))
            } else {
                var stringValues = [String?]()
                stringValues.reserveCapacity(rowCount)
                for rowIdx in 0..<rowCount {
                    let field = grid.field(row: dataStartRow + rowIdx, col: colIdx)
                    let (s, e) = Self.stripQuotes(bytes, start: field.start, end: field.end)
                    let fieldLen = e - s

                    let isNA: Bool
                    if useDefaultNA {
                        isNA = Self.isNADefault(bytes, start: s, length: fieldLen)
                    } else {
                        isNA = fieldLen == 0 || Self.isNACustom(bytes, start: s, length: fieldLen, patterns: naBytePatterns)
                    }

                    if isNA {
                        stringValues.append(nil)
                    } else {
                        stringValues.append(extractString(bytes, field: field))
                    }
                }
                resultColumns.append((name, .fromOptionalStrings(stringValues)))
            }
        }

        return DataFrame(columns: resultColumns)
    }

    /// Fast double parser for common `[-]digits[.digits]` patterns.
    /// Falls back to strtod for scientific notation, infinity, etc.
    @inline(__always)
    private static func fastParseDouble(
        _ bytes: UnsafeBufferPointer<UInt8>, start s: Int, end e: Int,
        strtodBuf: UnsafeMutablePointer<CChar>
    ) -> (Bool, Double) {
        let fieldLen = e - s
        guard fieldLen > 0 else { return (false, 0) }

        // Try fast path: [-]digits[.digits]
        var i = s
        var negative = false

        if bytes[i] == 0x2D { // '-'
            negative = true
            i += 1
            guard i < e else { return (false, 0) }
        }

        // Must start with a digit
        guard bytes[i] >= 0x30 && bytes[i] <= 0x39 else {
            // Not a simple number — fall back to strtod
            return strtodFallback(bytes, start: s, end: e, strtodBuf: strtodBuf)
        }

        // Parse integer part
        var intPart: UInt64 = UInt64(bytes[i] - 0x30)
        i += 1
        while i < e {
            let b = bytes[i]
            guard b >= 0x30 && b <= 0x39 else { break }
            intPart = intPart &* 10 &+ UInt64(b - 0x30)
            i += 1
        }

        // Check if we consumed everything (integer only)
        if i == e {
            let result = negative ? -Double(intPart) : Double(intPart)
            return (true, result)
        }

        // Check for decimal point
        if bytes[i] == 0x2E { // '.'
            i += 1
            var fracPart: UInt64 = 0
            var fracDigits = 0
            while i < e {
                let b = bytes[i]
                guard b >= 0x30 && b <= 0x39 else { break }
                fracPart = fracPart &* 10 &+ UInt64(b - 0x30)
                fracDigits += 1
                i += 1
            }

            if i == e && fracDigits > 0 {
                // Simple decimal number
                let pow10: Double
                switch fracDigits {
                case 1: pow10 = 10.0
                case 2: pow10 = 100.0
                case 3: pow10 = 1000.0
                case 4: pow10 = 10000.0
                case 5: pow10 = 100000.0
                case 6: pow10 = 1000000.0
                default: pow10 = Double(truncating: NSDecimalNumber(decimal: pow(10, fracDigits)))
                }
                var result = Double(intPart) + Double(fracPart) / pow10
                if negative { result = -result }
                return (true, result)
            }
        }

        // Has trailing non-digit chars (scientific notation, etc.) — fallback
        return strtodFallback(bytes, start: s, end: e, strtodBuf: strtodBuf)
    }

    /// strtod fallback using a pre-allocated reusable buffer.
    @inline(__always)
    private static func strtodFallback(
        _ bytes: UnsafeBufferPointer<UInt8>, start s: Int, end e: Int,
        strtodBuf: UnsafeMutablePointer<CChar>
    ) -> (Bool, Double) {
        let fieldLen = e - s
        guard fieldLen > 0 && fieldLen < 64 else { return (false, 0) }

        for j in 0..<fieldLen {
            strtodBuf[j] = CChar(bitPattern: bytes[s + j])
        }
        strtodBuf[fieldLen] = 0
        var endPtr: UnsafeMutablePointer<CChar>?
        let d = strtod(strtodBuf, &endPtr)
        let parsed = endPtr == strtodBuf + fieldLen
        return (parsed, d)
    }

    /// Switch-based NA matching for default NA values (fast path).
    @inline(__always)
    private static func isNADefault(
        _ bytes: UnsafeBufferPointer<UInt8>, start s: Int, length: Int
    ) -> Bool {
        switch length {
        case 0:
            return true // ""
        case 1:
            return bytes[s] == 0x2E // "."
        case 2:
            // "NA"
            return bytes[s] == 0x4E && bytes[s+1] == 0x41
        case 3:
            let b0 = bytes[s], b1 = bytes[s+1], b2 = bytes[s+2]
            // "N/A"
            if b0 == 0x4E && b1 == 0x2F && b2 == 0x41 { return true }
            // "NaN"
            if b0 == 0x4E && b1 == 0x61 && b2 == 0x4E { return true }
            // "nan"
            if b0 == 0x6E && b1 == 0x61 && b2 == 0x6E { return true }
            return false
        case 4:
            let b0 = bytes[s], b1 = bytes[s+1], b2 = bytes[s+2], b3 = bytes[s+3]
            // "null"
            if b0 == 0x6E && b1 == 0x75 && b2 == 0x6C && b3 == 0x6C { return true }
            // "NULL"
            if b0 == 0x4E && b1 == 0x55 && b2 == 0x4C && b3 == 0x4C { return true }
            // "None"
            if b0 == 0x4E && b1 == 0x6F && b2 == 0x6E && b3 == 0x65 { return true }
            // "none"
            if b0 == 0x6E && b1 == 0x6F && b2 == 0x6E && b3 == 0x65 { return true }
            return false
        default:
            return false
        }
    }

    /// Custom NA pattern matching (fallback for non-default NA values).
    private static func isNACustom(
        _ bytes: UnsafeBufferPointer<UInt8>, start s: Int, length: Int,
        patterns: [[UInt8]]
    ) -> Bool {
        for pattern in patterns {
            if pattern.count == length {
                var match = true
                for j in 0..<length {
                    if bytes[s + j] != pattern[j] { match = false; break }
                }
                if match { return true }
            }
        }
        return false
    }

    /// Extract a String from a field range.
    private func extractString(_ bytes: UnsafeBufferPointer<UInt8>, field: FieldRange) -> String {
        var s = field.start
        var e = field.end
        if e > s && bytes[s] == 0x22 {
            s += 1
            if e > s && bytes[e - 1] == 0x22 { e -= 1 }
        }
        guard s < e else { return "" }

        if field.hasEscapedQuotes {
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

        return String(bytes: UnsafeBufferPointer(rebasing: bytes[s..<e]), encoding: .utf8) ?? ""
    }

    // MARK: - Field range parsing

    /// Parse CSV bytes into a flat grid of field ranges (eliminates 2D array overhead).
    private func parseFieldGrid(_ bytes: UnsafeBufferPointer<UInt8>) -> FieldGrid {
        let sepByte = separator.asciiValue!
        let count = bytes.count

        // Pre-count newlines to estimate row count
        var newlineCount = 0
        for i in 0..<count {
            if bytes[i] == 0x0A { newlineCount += 1 }
        }

        // First, scan the header/first row to determine column count
        var colCount = 1
        var scanI = 0
        var scanInQuotes = false
        while scanI < count {
            let b = bytes[scanI]
            if scanInQuotes {
                if b == 0x22 {
                    if scanI + 1 < count && bytes[scanI + 1] == 0x22 {
                        scanI += 2; continue
                    } else {
                        scanInQuotes = false
                    }
                }
                scanI += 1; continue
            }
            if b == 0x22 { scanInQuotes = true; scanI += 1; continue }
            if b == sepByte { colCount += 1; scanI += 1; continue }
            if b == 0x0A { break }
            scanI += 1
        }

        let estimatedRows = newlineCount + 1
        var fields = ContiguousArray<FieldRange>()
        fields.reserveCapacity(estimatedRows * colCount)

        var currentColInRow = 0
        var fieldStart = 0
        var inQuotes = false
        var hasQuotes = false
        var i = 0
        var rowCount = 0

        while i < count {
            let b = bytes[i]

            if inQuotes {
                if b == 0x22 { // "
                    if i + 1 < count && bytes[i + 1] == 0x22 {
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

            if b == 0x22 && (i == fieldStart || (i == fieldStart + 1 && i > 0 && bytes[fieldStart] == 0x0D)) {
                inQuotes = true
                i += 1
                continue
            }

            if b == sepByte {
                fields.append(FieldRange(start: fieldStart, end: i, hasEscapedQuotes: hasQuotes))
                currentColInRow += 1
                fieldStart = i + 1
                hasQuotes = false
                i += 1
                continue
            }

            if b == 0x0A { // \n
                var end = i
                if end > fieldStart && bytes[end - 1] == 0x0D { end -= 1 }
                fields.append(FieldRange(start: fieldStart, end: end, hasEscapedQuotes: hasQuotes))
                currentColInRow += 1
                // Pad if row has fewer columns than expected
                while currentColInRow < colCount {
                    fields.append(FieldRange(start: end, end: end, hasEscapedQuotes: false))
                    currentColInRow += 1
                }
                rowCount += 1
                currentColInRow = 0
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
            if fieldStart < end || currentColInRow > 0 {
                fields.append(FieldRange(start: fieldStart, end: end, hasEscapedQuotes: hasQuotes))
                currentColInRow += 1
                while currentColInRow < colCount {
                    fields.append(FieldRange(start: end, end: end, hasEscapedQuotes: false))
                    currentColInRow += 1
                }
                rowCount += 1
            }
        }

        return FieldGrid(fields: fields, rowCount: rowCount, colCount: colCount)
    }

    // MARK: - Fallback parsing

    /// Fallback parser for when contiguous UTF-8 storage is unavailable.
    private func readFallback(_ text: String) -> DataFrame {
        let rows = parseRowsFallback(text)
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

        var resultColumns = [(String, Column)]()
        resultColumns.reserveCapacity(columnNames.count)
        for (colIdx, name) in columnNames.enumerated() {
            var allNumeric = true
            var doubles = ContiguousArray<Double>()
            doubles.reserveCapacity(dataRows.count)
            var hasNA = false
            var validBits = BitVector(repeating: true, count: dataRows.count)

            for (rowIdx, row) in dataRows.enumerated() {
                let val = colIdx < row.count ? row[colIdx] : ""
                if val.isEmpty || naValues.contains(val) {
                    doubles.append(0.0)
                    validBits[rowIdx] = false
                    hasNA = true
                } else if let d = Double(val) {
                    doubles.append(d)
                } else {
                    allNumeric = false
                    break
                }
            }

            if allNumeric {
                let mask = hasNA ? validBits : BitVector(repeating: true, count: dataRows.count)
                let na = NullableArray(data: NativeArray(doubles), mask: mask)
                resultColumns.append((name, .double(na)))
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
        let rowCount = df.rowCount
        guard rowCount > 0 else {
            if includeHeader {
                return df.columnNames.joined(separator: separator) + "\n"
            }
            return ""
        }

        // Step 1: Pre-format all columns in bulk (column-wise, not row-wise)
        let colCount = df.columnNames.count
        var formattedCols = [[String]]()
        formattedCols.reserveCapacity(colCount)
        var needsQuoting = [Bool]()  // track which columns might need quoting

        for name in df.columnNames {
            let col = df.columns[name]!
            switch col {
            case .double(let arr):
                var strs = [String]()
                strs.reserveCapacity(rowCount)
                if arr.mask.allValid {
                    arr.data.withUnsafeBufferPointer { buf in
                        for i in 0..<rowCount {
                            strs.append(formatDouble(buf[i]))
                        }
                    }
                } else {
                    arr.data.withUnsafeBufferPointer { buf in
                        for i in 0..<rowCount {
                            if arr.mask[i] {
                                strs.append(formatDouble(buf[i]))
                            } else {
                                strs.append(naRepresentation)
                            }
                        }
                    }
                }
                formattedCols.append(strs)
                needsQuoting.append(false) // numbers never need quoting

            case .int64(let arr):
                var strs = [String]()
                strs.reserveCapacity(rowCount)
                for i in 0..<rowCount {
                    if let v = arr[i] {
                        strs.append("\(v)")
                    } else {
                        strs.append(naRepresentation)
                    }
                }
                formattedCols.append(strs)
                needsQuoting.append(false)

            case .bool(let arr):
                var strs = [String]()
                strs.reserveCapacity(rowCount)
                for i in 0..<rowCount {
                    if let v = arr[i] {
                        strs.append(v ? "True" : "False")
                    } else {
                        strs.append(naRepresentation)
                    }
                }
                formattedCols.append(strs)
                needsQuoting.append(false)

            case .string(let arr):
                var strs = [String]()
                strs.reserveCapacity(rowCount)
                for i in 0..<rowCount {
                    if let v = arr[i] {
                        strs.append(v)
                    } else {
                        strs.append(naRepresentation)
                    }
                }
                formattedCols.append(strs)
                needsQuoting.append(true) // string columns may need quoting
            }
        }

        // Step 2: Estimate total size and pre-allocate
        var estimatedSize = 0
        if includeHeader {
            for name in df.columnNames { estimatedSize += name.utf8.count + 1 }
            estimatedSize += 1 // newline
        }
        for colIdx in 0..<colCount {
            for rowIdx in 0..<rowCount {
                estimatedSize += formattedCols[colIdx][rowIdx].utf8.count + 1
            }
        }
        estimatedSize += rowCount // newlines

        var result = ""
        result.reserveCapacity(estimatedSize)

        // Step 3: Write header
        if includeHeader {
            if includeIndex {
                result.append(separator)
            }
            for (colIdx, name) in df.columnNames.enumerated() {
                if colIdx > 0 { result.append(separator) }
                result.append(name)
            }
            result.append("\n")
        }

        // Step 4: Write data rows from pre-formatted columns
        for i in 0..<rowCount {
            if includeIndex {
                result.append(df.indexLabels[i])
                result.append(separator)
            }
            for colIdx in 0..<colCount {
                if colIdx > 0 { result.append(separator) }
                let val = formattedCols[colIdx][i]
                if needsQuoting[colIdx] && (val.contains(separator) || val.contains("\"") || val.contains("\n")) {
                    result.append("\"")
                    result.append(val.replacingOccurrences(of: "\"", with: "\"\""))
                    result.append("\"")
                } else {
                    result.append(val)
                }
            }
            result.append("\n")
        }

        return result
    }

    /// Fast double-to-string conversion (avoids String(format:) overhead).
    private func formatDouble(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(v)
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
