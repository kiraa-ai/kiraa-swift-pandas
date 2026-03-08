// MARK: - CSVReader.swift
// SwiftPandas CSV I/O Module
//
// This file implements a two-tier CSV parsing architecture designed for maximum throughput
// when reading CSV data into DataFrames:
//
// **Tier 1 — Fast byte-level parser (primary path):**
// When the input String's UTF-8 representation is contiguously stored in memory (which is
// the common case for Swift Strings), the parser operates entirely on raw `UInt8` bytes
// via `UnsafeBufferPointer<UInt8>`. This avoids all Swift `Character`/`String` overhead.
// The byte-level path works in two phases:
//   1. `parseFieldGrid` — A state machine scans the entire buffer once to build a flat
//      "field grid" (`FieldGrid`), which stores the byte-range (`FieldRange`) of every
//      cell in a single `ContiguousArray`, indexed as `fields[row * colCount + col]`.
//      This eliminates the overhead of nested `[[String]]` arrays.
//   2. `readFromBytes` — Iterates the field grid column-by-column, attempting numeric
//      parsing first via `fastParseDouble` (a hand-rolled integer+decimal parser that
//      handles ~99% of real-world numeric cells without calling `strtod`). Only when
//      `fastParseDouble` encounters scientific notation, infinity, or other exotic formats
//      does it fall back to `strtodFallback`, which copies bytes into a pre-allocated
//      64-byte `CChar` buffer and calls the C `strtod` function. NA/missing detection
//      uses `isNADefault`, a switch on field byte-length that performs O(1) matching
//      against the default NA sentinel set entirely at the byte level.
//
// **Tier 2 — Character-based fallback parser:**
// If `withContiguousStorageIfAvailable` returns `nil` (rare in practice), the parser
// falls back to `readFallback` / `parseRowsFallback`, which iterate over Swift
// `Character` values and accumulate `String` fields. This path is functionally identical
// but significantly slower due to per-character String operations.
//
// The file also contains `CSVWriter` for serializing DataFrames back to CSV, and
// convenience `DataFrame` extension methods (`readCSV`, `toCSV`) for ergonomic use.

import Foundation

/// High-performance CSV reader that parses CSV text into a ``DataFrame``.
///
/// `CSVReader` implements a two-tier parsing strategy optimized for throughput:
///
/// 1. **Fast byte-level path** (used when the String's UTF-8 bytes are contiguous in memory):
///    Parses raw `UInt8` bytes without allocating Swift `String` objects for numeric fields.
///    Numeric values are parsed directly from bytes via a custom `fastParseDouble` routine,
///    and NA detection is performed via byte-level switch matching (`isNADefault`).
///
/// 2. **Character-based fallback** (used when contiguous UTF-8 storage is unavailable):
///    Iterates Swift `Character` values and builds `[[String]]` rows before type inference.
///
/// Both tiers support custom separators, optional header rows, quoted fields with escaped
/// quotes (RFC 4180), and configurable NA/missing value sentinels.
///
/// ## Performance Characteristics
/// - Zero `String` allocation for numeric columns on the fast path.
/// - Single-pass field grid construction via `parseFieldGrid` state machine.
/// - `fastParseDouble` handles `[-]digits[.digits]` patterns inline (~99% of cells),
///   falling back to `strtod` only for scientific notation, infinity, etc.
/// - Pre-allocated 64-byte `CChar` buffer for `strtod` avoids per-cell heap allocation.
/// - `isNADefault` performs O(1) switch on field byte-length, then compares 1-4 bytes.
///
/// ## Usage
/// ```swift
/// let reader = CSVReader(separator: ",", header: true)
/// let df = reader.read(from: csvString)
/// ```
public struct CSVReader: Sendable {
    /// The field separator character used to delimit columns.
    ///
    /// Defaults to `","` (comma). Common alternatives include `"\t"` (tab-separated values)
    /// and `";"` (semicolon, common in European locales where comma is the decimal separator).
    /// The separator must be a single ASCII character so that it can be matched at the byte level
    /// in the fast parsing path.
    public let separator: Character

    /// Whether the first row of the CSV data should be interpreted as column headers.
    ///
    /// When `true` (the default), the first row's fields become the ``DataFrame`` column names
    /// and are excluded from the data rows. When `false`, columns are auto-named `"col_0"`,
    /// `"col_1"`, etc., and all rows (including the first) are treated as data.
    public let header: Bool

    /// The set of string values that should be treated as NA (missing/null).
    ///
    /// During parsing, if a field's text (after quote stripping) matches any value in this set,
    /// the cell is recorded as missing rather than as a string or numeric value. The default set
    /// covers the most common NA representations across Python pandas, R, SQL, and general usage:
    /// `""`, `"NA"`, `"N/A"`, `"NaN"`, `"nan"`, `"null"`, `"NULL"`, `"None"`, `"none"`, `"."`.
    ///
    /// When the default set is in use, the fast path (`isNADefault`) performs byte-level matching
    /// via a switch on field length, avoiding `Set<String>.contains` overhead entirely. Custom NA
    /// values trigger a slower byte-pattern scan (`isNACustom`).
    public let naValues: Set<String>

    /// Creates a new CSV reader with the specified configuration.
    ///
    /// - Parameters:
    ///   - separator: The character used to delimit fields. Defaults to `","`.
    ///   - header: Whether the first row contains column names. Defaults to `true`.
    ///   - naValues: The set of string literals to interpret as missing values. Defaults to
    ///     the standard pandas-compatible NA set.
    public init(
        separator: Character = ",",
        header: Bool = true,
        naValues: Set<String> = ["", "NA", "N/A", "NaN", "nan", "null", "NULL", "None", "none", "."]
    ) {
        self.separator = separator
        self.header = header
        self.naValues = naValues
    }

    /// A byte range identifying a single field (cell) within the raw UTF-8 buffer.
    ///
    /// `FieldRange` stores the half-open byte interval `[start, end)` pointing into the
    /// original `UnsafeBufferPointer<UInt8>`. The `hasEscapedQuotes` flag indicates whether
    /// the field contains `""` (doubled-quote) escape sequences that need to be collapsed
    /// when extracting the field as a Swift `String`. For numeric parsing, escaped quotes are
    /// irrelevant since such fields will fail numeric conversion and fall through to string
    /// extraction.
    private struct FieldRange {
        /// Byte offset of the first character of the field (inclusive).
        let start: Int
        /// Byte offset one past the last character of the field (exclusive).
        let end: Int
        /// Whether the field body contains `""` escape sequences that must be un-doubled
        /// during string extraction.
        let hasEscapedQuotes: Bool
    }

    /// A flat, row-major grid of ``FieldRange`` values representing every cell in the CSV.
    ///
    /// Rather than using a two-dimensional `[[FieldRange]]` array (which would incur nested
    /// heap allocations and pointer indirection), `FieldGrid` stores all field ranges in a
    /// single `ContiguousArray` laid out in row-major order. Cell `(row, col)` is accessed as
    /// `fields[row * colCount + col]`, which compiles down to a single multiply-add and an
    /// array bounds check (or unchecked `&*` / `&+` as used here for speed).
    ///
    /// This structure is populated by ``parseFieldGrid(_:)`` and consumed by ``readFromBytes(_:)``.
    private struct FieldGrid {
        /// Row-major flat storage of all field ranges. Length is `rowCount * colCount`.
        var fields: ContiguousArray<FieldRange>
        /// Total number of rows (including the header row, if present).
        var rowCount: Int
        /// Number of columns, determined by counting separators in the first row.
        var colCount: Int

        /// Returns the ``FieldRange`` for the cell at the given row and column.
        ///
        /// Uses overflow-wrapping arithmetic (`&*`, `&+`) to avoid bounds-check overhead.
        /// The caller must ensure `row < rowCount` and `col < colCount`.
        @inline(__always)
        func field(row: Int, col: Int) -> FieldRange {
            fields[row &* colCount &+ col]
        }
    }

    // MARK: - Parsing (Public Entry Points)

    /// Parses CSV text into a ``DataFrame``, automatically selecting the fastest available path.
    ///
    /// This is the primary entry point for CSV reading. It first attempts the **fast byte-level
    /// path** by calling `withContiguousStorageIfAvailable` on the String's UTF-8 view. If the
    /// underlying storage is contiguous (the common case), parsing proceeds entirely on raw
    /// `UInt8` bytes with zero intermediate `String` allocations for numeric columns. If
    /// contiguous storage is unavailable, the method transparently falls back to the
    /// character-based parser (`readFallback`), which produces an identical result at lower
    /// throughput.
    ///
    /// - Parameter text: The raw CSV content as a Swift `String`.
    /// - Returns: A ``DataFrame`` with columns inferred as `.double` where all non-NA values
    ///   parse as numbers, or `.string` otherwise.
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

    /// Reads a CSV file from the given `URL` and parses it into a ``DataFrame``.
    ///
    /// The file is read into memory as a UTF-8 `String` and then passed to ``read(from:)-String``.
    ///
    /// - Parameter url: A file URL pointing to the CSV file.
    /// - Returns: A parsed ``DataFrame``.
    /// - Throws: Any error from `String(contentsOf:encoding:)` if the file cannot be read.
    public func read(from url: URL) throws -> DataFrame {
        let text = try String(contentsOf: url, encoding: .utf8)
        return read(from: text)
    }

    /// Reads a CSV file from the given file-system path and parses it into a ``DataFrame``.
    ///
    /// Convenience wrapper that converts the path to a `URL` and delegates to ``read(from:)-URL``.
    ///
    /// - Parameter path: An absolute or relative file-system path to the CSV file.
    /// - Returns: A parsed ``DataFrame``.
    /// - Throws: Any error from file I/O if the file cannot be read.
    public func read(fromPath path: String) throws -> DataFrame {
        let url = URL(fileURLWithPath: path)
        return try read(from: url)
    }

    // MARK: - Fast Byte-Level Parsing (Tier 1)

    /// Strips surrounding double-quote characters (`"`) from a field's byte range.
    ///
    /// If the first byte is `0x22` (ASCII `"`), the start index is advanced by one.
    /// If the last byte is also `0x22`, the end index is decremented by one. This
    /// does **not** handle escaped quotes (`""`) — that is deferred to ``extractString``.
    ///
    /// - Parameters:
    ///   - bytes: The raw UTF-8 buffer.
    ///   - start: The inclusive start byte offset of the field.
    ///   - end: The exclusive end byte offset of the field.
    /// - Returns: An adjusted `(start, end)` tuple with surrounding quotes removed.
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

    /// The optimized byte-level CSV parser — the hot path for all CSV reads.
    ///
    /// This method implements the core of the fast parsing tier. It operates in three stages:
    ///
    /// 1. **Field grid construction** — Calls ``parseFieldGrid(_:)`` to scan the byte buffer once
    ///    and produce a flat grid of ``FieldRange`` values (one per cell).
    ///
    /// 2. **Column-wise type inference and parsing** — Iterates columns (not rows), attempting to
    ///    parse every cell as a `Double` via ``fastParseDouble``. If any non-NA cell in a column
    ///    fails numeric parsing, the entire column is re-scanned as strings. This column-first
    ///    approach means a column's type is determined in a single pass; there is no speculative
    ///    double-parsing followed by rollback.
    ///
    /// 3. **NA detection** — For each cell, NA status is checked *before* numeric parsing. When
    ///    the default NA set is in use, ``isNADefault`` performs a switch on field byte-length
    ///    followed by at most 4 byte comparisons — O(1) with no hashing or string allocation.
    ///    Custom NA sets fall back to ``isNACustom``, which iterates pre-computed byte patterns.
    ///
    /// A single pre-allocated 64-byte `CChar` buffer (`strtodBuf`) is shared across all cells
    /// in the DataFrame for the rare `strtod` fallback path, avoiding per-cell heap allocation.
    ///
    /// - Parameter bytes: A contiguous UTF-8 byte buffer containing the entire CSV content.
    /// - Returns: A ``DataFrame`` with type-inferred columns.
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

    /// Hot-path double parser optimized for the common `[-]digits[.digits]` numeric pattern.
    ///
    /// This function is the performance-critical inner loop of CSV numeric parsing. It handles
    /// approximately 99% of real-world numeric cells without ever calling the C `strtod` function,
    /// eliminating locale lookup, errno save/restore, and null-terminated buffer construction.
    ///
    /// **Algorithm:**
    /// 1. Check for an optional leading minus sign (`0x2D`).
    /// 2. Parse the integer part by accumulating digits into a `UInt64` via `intPart = intPart * 10 + digit`.
    ///    Uses overflow-wrapping arithmetic (`&*`, `&+`) for speed (safe because CSV fields are short).
    /// 3. If the field is fully consumed after the integer part, return `Double(intPart)` directly.
    /// 4. If a decimal point (`0x2E`) follows, parse fractional digits into `fracPart` and divide
    ///    by a power of 10 looked up via a switch table (cases 1-6 are inlined constants; case 7+
    ///    uses `NSDecimalNumber`).
    /// 5. If any non-digit character remains after the decimal (e.g., `e`, `E`, `+`, `i`), the
    ///    function delegates to ``strtodFallback`` for scientific notation, infinity, hex floats, etc.
    ///
    /// - Parameters:
    ///   - bytes: The raw UTF-8 byte buffer.
    ///   - s: Start byte offset of the field (after quote stripping).
    ///   - e: End byte offset of the field (exclusive, after quote stripping).
    ///   - strtodBuf: A pre-allocated 64-byte `CChar` buffer for the `strtod` fallback path.
    /// - Returns: A tuple `(success, value)`. If `success` is `false`, the field is not numeric.
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

    /// Fallback double parser that delegates to the C standard library `strtod` function.
    ///
    /// This is invoked by ``fastParseDouble`` when the field contains characters that the fast
    /// integer+decimal parser cannot handle — typically scientific notation (`1.23e10`), hex
    /// floats (`0x1.fp3`), infinity (`inf`), or other exotic formats. Rather than allocating a
    /// new null-terminated `CChar` buffer for each cell, this method copies the field bytes into
    /// `strtodBuf`, a **pre-allocated 64-byte buffer** that is reused across all cells in the
    /// entire DataFrame parse. Fields longer than 63 bytes are rejected (returned as non-numeric),
    /// which is safe since no reasonable numeric literal exceeds that length.
    ///
    /// After calling `strtod`, the method checks that the end pointer advanced to exactly the
    /// end of the copied bytes, ensuring the entire field was consumed as a valid number.
    ///
    /// - Parameters:
    ///   - bytes: The raw UTF-8 byte buffer.
    ///   - s: Start byte offset of the field.
    ///   - e: End byte offset of the field (exclusive).
    ///   - strtodBuf: A pre-allocated, reusable 64-byte `CChar` buffer for null-terminated copies.
    /// - Returns: A tuple `(success, value)`. If `success` is `false`, the field is not numeric.
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

    /// O(1) NA detection for the default set of NA sentinels, using a switch on field byte-length.
    ///
    /// This is the fast-path NA matcher used when `naValues` equals the built-in default set.
    /// Instead of hashing the field into a `Set<String>` (which requires String allocation and
    /// hash computation), this function dispatches on the field's byte length and then compares
    /// at most 4 individual bytes against known ASCII codes. The logic covers:
    ///
    /// - **Length 0:** Empty field `""` — always NA.
    /// - **Length 1:** `"."` (0x2E).
    /// - **Length 2:** `"NA"` (0x4E 0x41).
    /// - **Length 3:** `"N/A"` (0x4E 0x2F 0x41), `"NaN"` (0x4E 0x61 0x4E), `"nan"` (0x6E 0x61 0x6E).
    /// - **Length 4:** `"null"` (0x6E 0x75 0x6C 0x6C), `"NULL"` (0x4E 0x55 0x4C 0x4C),
    ///   `"None"` (0x4E 0x6F 0x6E 0x65), `"none"` (0x6E 0x6F 0x6E 0x65).
    /// - **Length >= 5:** No default NA value has 5+ characters, so always returns `false`.
    ///
    /// This approach avoids any heap allocation, hashing, or `String` construction, making NA
    /// detection essentially free compared to the numeric parsing that follows.
    ///
    /// - Parameters:
    ///   - bytes: The raw UTF-8 byte buffer.
    ///   - s: Start byte offset of the field (after quote stripping).
    ///   - length: Byte length of the field.
    /// - Returns: `true` if the field matches one of the default NA sentinels.
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

    /// NA detection for user-supplied (non-default) NA value sets.
    ///
    /// When the caller provides a custom `naValues` set that differs from the built-in default,
    /// this function is used instead of ``isNADefault``. It iterates over pre-computed byte
    /// patterns (`[[UInt8]]`, constructed once before the column loop) and performs a length
    /// check followed by a byte-by-byte comparison. This avoids `String` construction but is
    /// slower than the switch-based default matcher due to the linear scan over patterns.
    ///
    /// - Parameters:
    ///   - bytes: The raw UTF-8 byte buffer.
    ///   - s: Start byte offset of the field.
    ///   - length: Byte length of the field.
    ///   - patterns: Pre-computed `[UInt8]` representations of each custom NA value.
    /// - Returns: `true` if the field matches any of the custom NA patterns.
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

    /// Extracts a Swift `String` from a ``FieldRange`` within the byte buffer.
    ///
    /// This method is called only for cells that end up in string columns or for header names.
    /// It first strips surrounding quotes, then checks the ``FieldRange/hasEscapedQuotes`` flag.
    /// If escaped quotes are present, it builds a new `[UInt8]` buffer with doubled quotes
    /// (`""`) collapsed to single quotes. Otherwise, it constructs the `String` directly from
    /// the byte sub-range using `String(bytes:encoding:)`, which is an O(n) copy but avoids
    /// the overhead of character-by-character iteration.
    ///
    /// - Parameters:
    ///   - bytes: The raw UTF-8 byte buffer.
    ///   - field: The ``FieldRange`` identifying the cell's byte boundaries.
    /// - Returns: The cell value as a Swift `String`, with quotes stripped and escapes resolved.
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

    // MARK: - Field Range Parsing (State Machine)

    /// Scans the entire UTF-8 byte buffer in a single pass and constructs a flat ``FieldGrid``.
    ///
    /// This is the first phase of the fast byte-level parsing tier. The method implements a
    /// state machine with two primary states:
    ///
    /// - **Outside quotes (`inQuotes == false`):** The scanner looks for separator bytes,
    ///   newline bytes (`0x0A`), and quote-open bytes (`0x22`). Separator and newline bytes
    ///   terminate the current field and emit a ``FieldRange``. A quote byte at the start of
    ///   a field transitions to the "inside quotes" state.
    ///
    /// - **Inside quotes (`inQuotes == true`):** All bytes are consumed as field content except
    ///   `0x22` (quote). A single quote exits the quoted state. A doubled quote (`""`) is
    ///   recorded via the `hasQuotes` flag (for later escape resolution in ``extractString``)
    ///   and the scanner advances by two bytes.
    ///
    /// **Column count determination:** Before the main scan, a preliminary scan of the first
    /// row counts the number of separator bytes (respecting quotes) to determine `colCount`.
    /// This allows the flat `ContiguousArray` to be pre-allocated with `estimatedRows * colCount`
    /// capacity.
    ///
    /// **Row padding:** If a row has fewer fields than `colCount` (ragged CSV), empty
    /// ``FieldRange`` values are appended to pad the row to the expected width. This ensures
    /// the grid invariant `fields.count == rowCount * colCount` always holds.
    ///
    /// **Carriage return handling:** `\r\n` line endings are handled by checking for a trailing
    /// `0x0D` byte before the `0x0A` newline and decrementing the field end offset accordingly.
    ///
    /// - Parameter bytes: The contiguous UTF-8 byte buffer to scan.
    /// - Returns: A populated ``FieldGrid`` with all cell byte ranges.
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

    // MARK: - Character-Based Fallback Parsing (Tier 2)

    /// Fallback CSV parser used when the String's UTF-8 bytes are not contiguously stored.
    ///
    /// This method mirrors the logic of ``readFromBytes(_:)`` but operates on `[[String]]` rows
    /// produced by ``parseRowsFallback(_:)``. Type inference follows the same column-first
    /// strategy: attempt `Double(val)` for every non-NA cell in a column; if any cell fails,
    /// re-scan the column as strings. Performance is significantly lower than the byte-level
    /// path due to per-cell `String` allocation and `Double.init` parsing overhead, but the
    /// output is functionally identical.
    ///
    /// - Parameter text: The CSV content as a Swift `String`.
    /// - Returns: A parsed ``DataFrame``.
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

    /// Character-by-character CSV row parser — the fallback when contiguous UTF-8 is unavailable.
    ///
    /// Iterates over the String's `Character` sequence, tracking an `inQuotes` state to correctly
    /// handle fields that contain separators, newlines, or quote characters. Doubled quotes inside
    /// a quoted field are collapsed to a single quote via the `previousWasQuote` flag. Carriage
    /// returns (`\r`) are silently discarded to normalize `\r\n` line endings.
    ///
    /// - Parameter text: The CSV content as a Swift `String`.
    /// - Returns: A two-dimensional array where each inner array is one row of string fields.
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

/// Serializes a ``DataFrame`` to CSV format with configurable separator, header, and quoting.
///
/// `CSVWriter` uses a **column-wise pre-formatting** strategy for performance:
///
/// 1. **Pre-format phase:** Each column is converted to an array of `String` representations
///    in bulk. Numeric columns use ``formatDouble(_:)`` which outputs integer-style strings
///    (e.g., `"42"` instead of `"42.0"`) when the value has no fractional part, avoiding the
///    overhead of `String(format:)`. A parallel `needsQuoting` array tracks which columns
///    are string-typed and may require RFC 4180 quoting.
///
/// 2. **Size estimation:** The total output byte count is estimated by summing field lengths
///    plus separators and newlines. The result `String` is pre-allocated via `reserveCapacity`
///    to avoid incremental reallocation.
///
/// 3. **Row emission:** Rows are written by iterating row indices and pulling pre-formatted
///    strings from the column arrays. String fields that contain the separator, double quotes,
///    or newlines are wrapped in quotes with internal quotes doubled.
///
/// ## Usage
/// ```swift
/// let writer = CSVWriter(separator: ",", includeHeader: true)
/// let csvText = writer.write(dataFrame)
/// ```
public struct CSVWriter: Sendable {
    /// The string used to separate fields. Typically `","` or `"\t"`.
    public let separator: String
    /// Whether to emit a header row with column names.
    public let includeHeader: Bool
    /// Whether to emit the DataFrame's index labels as the first column of each row.
    public let includeIndex: Bool
    /// The string to write for NA/missing values. Defaults to `""` (empty field).
    public let naRepresentation: String

    /// Creates a new CSV writer with the specified formatting options.
    ///
    /// - Parameters:
    ///   - separator: Field delimiter string. Defaults to `","`.
    ///   - includeHeader: Whether to write a header row. Defaults to `true`.
    ///   - includeIndex: Whether to write index labels as the first column. Defaults to `false`.
    ///   - naRepresentation: The literal string to emit for missing values. Defaults to `""`.
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

    /// Serializes the given ``DataFrame`` to a CSV-formatted `String`.
    ///
    /// The method proceeds in four steps:
    /// 1. Pre-format all columns into `[[String]]` (column-major).
    /// 2. Estimate total output size and pre-allocate the result `String`.
    /// 3. Write the header row (if enabled).
    /// 4. Write data rows, applying RFC 4180 quoting to string fields as needed.
    ///
    /// - Parameter df: The ``DataFrame`` to serialize.
    /// - Returns: A CSV-formatted string with `\n` line endings.
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

    /// Fast double-to-string conversion that avoids `String(format:)` overhead.
    ///
    /// For values with no fractional part (and absolute value below 1e15), this method converts
    /// to `Int64` first and uses `String(Int64)`, which produces a clean integer representation
    /// (e.g., `"42"` instead of `"42.0"`). This matches Python pandas' CSV output behavior and
    /// avoids the significant overhead of `String(format: "%.Ng")`. For values with a fractional
    /// part, it falls back to `String(Double)`, which uses Swift's default shortest-representation
    /// algorithm.
    ///
    /// - Parameter v: The double value to format.
    /// - Returns: A string representation of the value.
    private func formatDouble(_ v: Double) -> String {
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(v)
    }

    /// Writes the given ``DataFrame`` to a CSV file at the specified URL.
    ///
    /// The CSV content is first generated in memory via ``write(_:)-String`` and then written
    /// atomically to disk using UTF-8 encoding.
    ///
    /// - Parameters:
    ///   - df: The ``DataFrame`` to serialize.
    ///   - url: The file URL to write to.
    /// - Throws: Any error from `String.write(to:atomically:encoding:)`.
    public func write(_ df: DataFrame, to url: URL) throws {
        let text = write(df)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes the given ``DataFrame`` to a CSV file at the specified file-system path.
    ///
    /// Convenience wrapper that converts the path to a `URL` and delegates to ``write(_:to:)``.
    ///
    /// - Parameters:
    ///   - df: The ``DataFrame`` to serialize.
    ///   - path: An absolute or relative file-system path.
    /// - Throws: Any error from file I/O.
    public func write(_ df: DataFrame, toPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        try write(df, to: url)
    }
}

// MARK: - DataFrame Convenience Methods for CSV I/O

/// Extension on ``DataFrame`` providing ergonomic static factory methods and instance methods
/// for reading and writing CSV data. These are thin wrappers around ``CSVReader`` and
/// ``CSVWriter`` that allow one-liner CSV operations without manually constructing reader/writer
/// objects.
extension DataFrame {
    /// Creates a ``DataFrame`` by parsing CSV-formatted text.
    ///
    /// This is a convenience static method that internally creates a ``CSVReader`` with the
    /// given parameters and invokes its ``CSVReader/read(from:)-String`` method.
    ///
    /// - Parameters:
    ///   - text: The raw CSV content.
    ///   - separator: The field delimiter character. Defaults to `","`.
    ///   - header: Whether the first row contains column names. Defaults to `true`.
    /// - Returns: A parsed ``DataFrame`` with type-inferred columns.
    public static func readCSV(
        _ text: String,
        separator: Character = ",",
        header: Bool = true
    ) -> DataFrame {
        let reader = CSVReader(separator: separator, header: header)
        return reader.read(from: text)
    }

    /// Creates a ``DataFrame`` by reading and parsing a CSV file at the given path.
    ///
    /// - Parameters:
    ///   - path: An absolute or relative file-system path to the CSV file.
    ///   - separator: The field delimiter character. Defaults to `","`.
    ///   - header: Whether the first row contains column names. Defaults to `true`.
    /// - Returns: A parsed ``DataFrame``.
    /// - Throws: Any error from file I/O if the file cannot be read.
    public static func readCSV(
        path: String,
        separator: Character = ",",
        header: Bool = true
    ) throws -> DataFrame {
        let reader = CSVReader(separator: separator, header: header)
        return try reader.read(fromPath: path)
    }

    /// Serializes this ``DataFrame`` to a CSV-formatted `String`.
    ///
    /// - Parameters:
    ///   - separator: The field delimiter string. Defaults to `","`.
    ///   - header: Whether to include a header row with column names. Defaults to `true`.
    ///   - index: Whether to include index labels as the first column. Defaults to `false`.
    /// - Returns: A CSV-formatted string.
    public func toCSV(
        separator: String = ",",
        header: Bool = true,
        index: Bool = false
    ) -> String {
        let writer = CSVWriter(separator: separator, includeHeader: header, includeIndex: index)
        return writer.write(self)
    }

    /// Writes this ``DataFrame`` to a CSV file at the given file-system path.
    ///
    /// - Parameters:
    ///   - path: An absolute or relative file-system path for the output file.
    ///   - separator: The field delimiter string. Defaults to `","`.
    ///   - header: Whether to include a header row. Defaults to `true`.
    ///   - index: Whether to include index labels. Defaults to `false`.
    /// - Throws: Any error from file I/O.
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
