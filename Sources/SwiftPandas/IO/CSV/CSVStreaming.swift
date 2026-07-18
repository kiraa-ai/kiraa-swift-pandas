// ===----------------------------------------------------------------------===//
//
// CSVStreaming.swift
// SwiftPandas — CSV I/O
//
// Row-streaming access to CSV files. For GB-scale files where the caller
// only needs to walk rows (or just count them), fully parsing into a
// DataFrame wastes memory and time. These APIs iterate a memory-mapped view
// of the file: the kernel pages bytes in on demand, only one row of Swift
// Strings is materialized at a time, and dimension counting never parses a
// single cell.
//
// ===----------------------------------------------------------------------===//

import Foundation

extension CSVReader {
    /// Opens a streaming row sequence over the CSV file at `url`.
    ///
    /// The file is memory-mapped, not loaded: iterating never materializes
    /// more than one row's fields at a time, so GB-scale files stream in
    /// constant memory. Rows are yielded as `[String]` field arrays with
    /// RFC-4180 semantics identical to a full ``read(from:)-8ce0j`` — quoted
    /// fields may contain separators and newlines, doubled quotes collapse,
    /// CRLF line endings are handled, and rows shorter than the header are
    /// padded with empty fields to the sequence's ``CSVRowSequence/columnCount``.
    ///
    /// When this reader has `header == true`, the header row is consumed up
    /// front (exposed as ``CSVRowSequence/header``) and iteration yields
    /// data rows only — exactly the rows a full read would place in the
    /// frame.
    ///
    /// - Throws: Only errors from opening/mapping the file.
    public func rows(url: URL) throws -> CSVRowSequence {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return CSVRowSequence(data: data, separator: separator, hasHeader: header)
    }

    /// Counts a CSV file's dimensions in a single streaming pass, without
    /// parsing any cell values.
    ///
    /// This replaces the "re-read the file you just wrote only to count
    /// rows and columns" pattern: one quote-aware byte scan over a
    /// memory-mapped view. Semantics match a full parse: `cols` is the
    /// field count of the first record; `rows` is the number of data
    /// records (the header record is excluded when this reader has
    /// `header == true`); a trailing newline does not create a phantom row.
    ///
    /// - Throws: Only errors from opening/mapping the file.
    public static func dimensions(url: URL) throws -> (rows: Int, cols: Int) {
        try dimensions(url: url, separator: ",", header: true)
    }

    /// Separator/header-generalized variant of ``dimensions(url:)``.
    public static func dimensions(
        url: URL, separator: Character, header: Bool
    ) throws -> (rows: Int, cols: Int) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { return (0, 0) }
        let sepByte = separator.asciiValue ?? UInt8(ascii: ",")

        return data.withUnsafeBytes { raw -> (Int, Int) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var records = 0
            var cols = 1
            var inQuotes = false
            var recordHasContent = false
            var inFirstRecord = true
            var i = 0
            let n = bytes.count
            while i < n {
                let b = bytes[i]
                if inQuotes {
                    if b == 0x22 {
                        if i + 1 < n && bytes[i + 1] == 0x22 { i += 2; continue }
                        inQuotes = false
                    }
                    i += 1
                    continue
                }
                switch b {
                case 0x22:
                    inQuotes = true
                    recordHasContent = true
                case sepByte:
                    if inFirstRecord { cols += 1 }
                    recordHasContent = true
                case 0x0A:
                    records += 1
                    recordHasContent = false
                    inFirstRecord = false
                case 0x0D:
                    break // CR before LF: not content on its own
                default:
                    recordHasContent = true
                }
                i += 1
            }
            if recordHasContent { records += 1 } // final record without trailing \n
            let dataRows = header ? max(0, records - 1) : records
            return (dataRows, records == 0 ? 0 : cols)
        }
    }
}

/// A constant-memory sequence of CSV rows over a memory-mapped file.
///
/// Produced by ``CSVReader/rows(url:)``. Each iteration scans forward to
/// the next record boundary (quote-aware, so embedded newlines are safe),
/// decodes just that record, and parses it with the canonical ``CSVLine``
/// codec. The sequence can be iterated multiple times; each iterator is
/// independent.
public struct CSVRowSequence: Sequence {
    private let data: Data
    private let separator: Character
    private let hasHeader: Bool

    /// The header row's fields, or `nil` when the reader was configured
    /// with `header == false` or the file is empty.
    public let header: [String]?

    /// The column count rows are padded to: the field count of the file's
    /// first record (header or first data row), or 0 for an empty file.
    public let columnCount: Int

    internal init(data: Data, separator: Character, hasHeader: Bool) {
        self.data = data
        self.separator = separator
        self.hasHeader = hasHeader
        let first = Self.record(in: data, from: 0)
        if let first {
            let fields = CSVLine.parse(Substring(first.text), separator: separator)
            self.columnCount = fields.count
            self.header = hasHeader ? fields : nil
        } else {
            self.columnCount = 0
            self.header = nil
        }
    }

    public func makeIterator() -> Iterator {
        var start = 0
        if hasHeader, let first = Self.record(in: data, from: 0) {
            start = first.nextOffset
        }
        return Iterator(data: data, separator: separator,
                        offset: start, columnCount: columnCount)
    }

    /// Iterates data rows as `[String]` field arrays.
    public struct Iterator: IteratorProtocol {
        private let data: Data
        private let separator: Character
        private var offset: Int
        private let columnCount: Int

        internal init(data: Data, separator: Character, offset: Int, columnCount: Int) {
            self.data = data
            self.separator = separator
            self.offset = offset
            self.columnCount = columnCount
        }

        public mutating func next() -> [String]? {
            guard let rec = CSVRowSequence.record(in: data, from: offset) else { return nil }
            offset = rec.nextOffset
            var fields = CSVLine.parse(Substring(rec.text), separator: separator)
            // Match full-parse grid semantics: short rows pad with empties.
            while fields.count < columnCount { fields.append("") }
            return fields
        }
    }

    /// Scans for the next complete record starting at `from`, honoring
    /// quotes (a newline inside a quoted field does not end the record).
    /// Returns the record's decoded text (without its terminating LF; a
    /// trailing CR is left for ``CSVLine/parse(_:)`` to strip) and the
    /// offset just past its terminator — or `nil` at end of data or when
    /// only a bare trailing newline remains.
    fileprivate static func record(in data: Data, from: Int) -> (text: String, nextOffset: Int)? {
        data.withUnsafeBytes { raw -> (String, Int)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            guard from < n else { return nil }
            var i = from
            var inQuotes = false
            while i < n {
                let b = bytes[i]
                if inQuotes {
                    if b == 0x22 {
                        if i + 1 < n && bytes[i + 1] == 0x22 { i += 2; continue }
                        inQuotes = false
                    }
                } else if b == 0x22 {
                    inQuotes = true
                } else if b == 0x0A {
                    break
                }
                i += 1
            }
            let slice = UnsafeBufferPointer(rebasing: bytes[from..<i])
            let text = String(decoding: slice, as: UTF8.self)
            // Nothing between the last newline and end-of-file is the
            // artifact of a trailing newline, not a row.
            if i >= n && text.isEmpty { return nil }
            return (text, i + 1)
        }
    }
}
