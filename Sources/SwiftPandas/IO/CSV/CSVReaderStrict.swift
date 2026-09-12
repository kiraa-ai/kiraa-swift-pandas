// ===----------------------------------------------------------------------===//
//
// CSVReaderStrict.swift
// SwiftPandas — CSV I/O
//
// Contract-driven (strict / all-strings) parsing for CSVReader, the
// per-column parse-failure report, and the throwing read that refuses a
// frame whose contract was violated. This is the upstreamed replacement for
// engine-side "makeColumn" loaders: dtype decisions come from a declared
// contract, never from inference, so all-digit identifier columns can never
// silently numerify.
//
// The strict path reuses the same byte-level machinery as the inference
// path (parseFieldGrid, fastParseDouble, NA matchers), so its throughput
// characteristics — and its NA and quote semantics — are identical.
//
// ===----------------------------------------------------------------------===//

import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

/// A per-column report of cells that failed their declared dtype parse
/// during a strict CSV load.
///
/// Failed cells are stored as NA in the resulting frame; the report is how
/// a caller distinguishes "declared NA sentinel" from "value that did not
/// parse". One `ColumnParseFailure` is produced per column that had at
/// least one failing cell.
public struct ColumnParseFailure: Equatable, Sendable {
    /// The column (header name) the failures occurred in.
    public let column: String
    /// The dtype the contract declared for this column.
    public let declaredType: DTypeEnum
    /// How many cells in this column failed to parse.
    public let failedCount: Int
    /// Zero-based data-row index (header excluded) of the first failure.
    public let firstFailedRow: Int
    /// The raw cell text (quotes stripped, escapes resolved) of the first
    /// failure — for error messages.
    public let firstFailedValue: String

    /// Creates a failure report entry.
    public init(column: String, declaredType: DTypeEnum, failedCount: Int,
                firstFailedRow: Int, firstFailedValue: String) {
        self.column = column
        self.declaredType = declaredType
        self.failedCount = failedCount
        self.firstFailedRow = firstFailedRow
        self.firstFailedValue = firstFailedValue
    }
}

/// A strict read failed its declared contract: at least one cell in a
/// declared column did not parse as its dtype. Carries the per-column report
/// so the message names every offender.
public struct CSVContractError: Error, LocalizedError, CustomStringConvertible, Sendable {
    /// One entry per column that had at least one cell fail its declared
    /// dtype, in header order.
    public let failures: [ColumnParseFailure]

    /// Creates an error from the per-column report of a strict read.
    public init(failures: [ColumnParseFailure]) {
        self.failures = failures
    }

    /// Every failing column on one line: its name, how many cells failed,
    /// the declared dtype, and the first offending cell with its row.
    public var description: String {
        failures.map {
            "\($0.column): \($0.failedCount) \($0.failedCount == 1 ? "cell" : "cells") failed \($0.declaredType) "
            + "(first '\($0.firstFailedValue)' at row \($0.firstFailedRow))"
        }.joined(separator: "; ")
    }

    /// The same text as ``description``, so `localizedDescription` names
    /// every offender rather than a generic operation-failed message.
    public var errorDescription: String? { description }
}

extension CSVReader {
    // MARK: - Public entry points

    /// Parses CSV text under this reader's ``ParseMode`` and returns the
    /// frame together with the per-column parse-failure report.
    ///
    /// For ``ParseMode/infer`` and ``ParseMode/allStrings`` the report is
    /// always empty (nothing can fail: inference falls back to string, and
    /// all-strings never parses). For ``ParseMode/strict(_:)`` each column
    /// with at least one cell that failed its declared dtype contributes one
    /// ``ColumnParseFailure``; the failing cells are NA in the frame.
    public func readWithReport(from text: String) -> (frame: DataFrame, failures: [ColumnParseFailure]) {
        if case .infer = mode {
            return (read(from: text), [])
        }
        var t = text
        return t.withUTF8 { buf in
            readTypedFromBytes(buf)
        }
    }

    /// File variant of ``readWithReport(from:)-(String)``. Reads the file
    /// bytes with `.mappedIfSafe` (no intermediate String) and parses under
    /// this reader's mode.
    ///
    /// - Throws: Only errors from reading the file.
    public func readWithReport(from url: URL) throws -> (frame: DataFrame, failures: [ColumnParseFailure]) {
        if case .infer = mode {
            return (try read(from: url), [])
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.isEmpty { return (DataFrame(), []) }
        return data.withUnsafeBytes { rawBuf in
            readTypedFromBytes(rawBuf.bindMemory(to: UInt8.self))
        }
    }

    /// ``readWithReport(from:)-(String)`` with the report enforced: a frame is
    /// returned only when it is empty, so a corrupt cell can never pass as NA.
    /// - Parameter text: The CSV text to parse.
    /// - Returns: The parsed frame.
    /// - Throws: `CSVContractError` when any float, integer, or bool contract
    ///   column had a cell that failed to parse. Never throws under
    ///   ``ParseMode/infer`` or ``ParseMode/allStrings``.
    public func readValidated(from text: String) throws -> DataFrame {
        let (frame, failures) = readWithReport(from: text)
        guard failures.isEmpty else { throw CSVContractError(failures: failures) }
        return frame
    }

    // MARK: - Typed column building

    /// The declared storage for a column under the current mode.
    private enum TypedTarget {
        case double
        case int64
        case bool
        case string
        /// `.declared` mode, column not in the contract: run the historical
        /// inference (shared `inferColumn`) — never fails, never reports.
        case inferred
    }

    private func target(for name: String) -> (TypedTarget, DTypeEnum) {
        switch mode {
        case .infer, .allStrings:
            return (.string, .string)
        case .strict(let contract):
            guard let declared = contract[name] else { return (.string, .string) }
            return Self.contractTarget(declared)
        case .declared(let contract):
            guard let declared = contract[name] else { return (.inferred, .string) }
            return Self.contractTarget(declared)
        }
    }

    /// Shared declared-dtype → storage mapping for `.strict` and `.declared`.
    private static func contractTarget(_ declared: DTypeEnum) -> (TypedTarget, DTypeEnum) {
        if declared.isFloat { return (.double, declared) }
        if declared.isInteger { return (.int64, declared) }
        if declared == .bool { return (.bool, declared) }
        return (.string, declared)
    }

    /// Contract-driven column builder over the shared field grid.
    ///
    /// Duplicate header names are merged **last-wins**: the last occurrence
    /// supplies both the data and the column position. This matches
    /// last-wins dictionary-merge semantics and is a documented
    /// byte-compatibility guarantee.
    internal func readTypedFromBytes(
        _ bytes: UnsafeBufferPointer<UInt8>
    ) -> (frame: DataFrame, failures: [ColumnParseFailure]) {
        let grid = parseFieldGrid(bytes)
        guard grid.rowCount > 0 else { return (DataFrame(), []) }

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
        let useDefaultNA = (naValues == ["", "NA", "N/A", "NaN", "nan", "null", "NULL", "None", "none", "."])
        let naBytePatterns: [[UInt8]] = useDefaultNA ? [] : naValues.map { Array($0.utf8) }

        guard rowCount > 0 else {
            let empty: [(String, Column)] = columnNames.map { name in
                switch target(for: name).0 {
                case .double: return (name, Column.fromDoubles([]))
                case .int64: return (name, Column.fromInts([]))
                case .bool: return (name, Column.fromBools([]))
                case .string: return (name, Column.fromStrings([]))
                // Matches the infer path's zero-row column dtype.
                case .inferred: return (name, Column.fromDoubles([]))
                }
            }
            return (DataFrame(columns: Self.dedupeLastWins(empty)), [])
        }

        /// Builds one column (and its optional failure report) — the unit
        /// of work for both the serial and column-parallel drives below.
        func buildColumn(
            colIdx: Int, name: String, strtodBuf: UnsafeMutablePointer<CChar>
        ) -> (column: (String, Column), failure: ColumnParseFailure?) {
            let (storage, declared) = target(for: name)

            var failCount = 0
            var firstFailRow = -1
            var firstFailValue = ""

            func noteFailure(_ rowIdx: Int, _ field: FieldRange) {
                if failCount == 0 {
                    firstFailRow = rowIdx
                    firstFailValue = extractString(bytes, field: field)
                }
                failCount += 1
            }

            func isNACell(_ s: Int, _ len: Int) -> Bool {
                if useDefaultNA {
                    return Self.isNADefault(bytes, start: s, length: len)
                }
                return len == 0 || Self.isNACustom(bytes, start: s, length: len, patterns: naBytePatterns)
            }

            let column: Column
            switch storage {
            case .inferred:
                column = inferColumn(
                    bytes, grid: grid, colIdx: colIdx, dataStartRow: dataStartRow,
                    rowCount: rowCount, useDefaultNA: useDefaultNA,
                    naBytePatterns: naBytePatterns, strtodBuf: strtodBuf)

            case .string:
                var values = [String?]()
                values.reserveCapacity(rowCount)
                for rowIdx in 0..<rowCount {
                    let field = grid.field(row: dataStartRow + rowIdx, col: colIdx)
                    let (s, e) = Self.stripQuotes(bytes, start: field.start, end: field.end)
                    values.append(isNACell(s, e - s) ? nil : extractString(bytes, field: field))
                }
                column = .fromOptionalStrings(values)

            case .double:
                var data = ContiguousArray<Double>(repeating: 0, count: rowCount)
                var valid = BitVector(repeating: true, count: rowCount)
                for rowIdx in 0..<rowCount {
                    let field = grid.field(row: dataStartRow + rowIdx, col: colIdx)
                    let (s, e) = Self.stripQuotes(bytes, start: field.start, end: field.end)
                    if isNACell(s, e - s) {
                        valid[rowIdx] = false
                    } else {
                        let (ok, v) = Self.fastParseDouble(bytes, start: s, end: e, strtodBuf: strtodBuf)
                        if ok {
                            data[rowIdx] = v
                        } else {
                            valid[rowIdx] = false
                            noteFailure(rowIdx, field)
                        }
                    }
                }
                column = .double(NullableArray(data: NativeArray(data), mask: valid))

            case .int64:
                var data = ContiguousArray<Int64>(repeating: 0, count: rowCount)
                var valid = BitVector(repeating: true, count: rowCount)
                for rowIdx in 0..<rowCount {
                    let field = grid.field(row: dataStartRow + rowIdx, col: colIdx)
                    let (s, e) = Self.stripQuotes(bytes, start: field.start, end: field.end)
                    if isNACell(s, e - s) {
                        valid[rowIdx] = false
                    } else {
                        let (ok, v) = Self.fastParseInt64(bytes, start: s, end: e)
                        if ok {
                            data[rowIdx] = v
                        } else {
                            valid[rowIdx] = false
                            noteFailure(rowIdx, field)
                        }
                    }
                }
                column = .int64(NullableArray(data: NativeArray(data), mask: valid))

            case .bool:
                var data = ContiguousArray<Bool>(repeating: false, count: rowCount)
                var valid = BitVector(repeating: true, count: rowCount)
                for rowIdx in 0..<rowCount {
                    let field = grid.field(row: dataStartRow + rowIdx, col: colIdx)
                    let (s, e) = Self.stripQuotes(bytes, start: field.start, end: field.end)
                    if isNACell(s, e - s) {
                        valid[rowIdx] = false
                    } else if let b = Self.parseBool(extractString(bytes, field: field)) {
                        data[rowIdx] = b
                    } else {
                        valid[rowIdx] = false
                        noteFailure(rowIdx, field)
                    }
                }
                column = .bool(NullableArray(data: NativeArray(data), mask: valid))
            }

            let failure = failCount > 0 ? ColumnParseFailure(
                column: name, declaredType: declared, failedCount: failCount,
                firstFailedRow: firstFailRow, firstFailedValue: firstFailValue
            ) : nil
            return ((name, column), failure)
        }

        var resultColumns: [(String, Column)]
        var failures: [ColumnParseFailure]

        if CSVReader.shouldParallelizeColumns(rows: rowCount, cols: grid.colCount) {
            // Columns are independent over the shared read-only grid; each
            // iteration owns one slot and its own strtod scratch. Slot-order
            // assembly keeps columns and failure reports deterministic.
            var slots = [((String, Column), ColumnParseFailure?)?](
                repeating: nil, count: columnNames.count)
            slots.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: columnNames.count) { colIdx in
                    guard colIdx < grid.colCount else { return }
                    let strtodBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
                    defer { strtodBuf.deallocate() }
                    buf[colIdx] = buildColumn(colIdx: colIdx, name: columnNames[colIdx],
                                              strtodBuf: strtodBuf)
                }
            }
            let built = slots.compactMap { $0 }
            resultColumns = built.map { $0.0 }
            failures = built.compactMap { $0.1 }
        } else {
            let strtodBuf = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
            defer { strtodBuf.deallocate() }
            resultColumns = []
            resultColumns.reserveCapacity(columnNames.count)
            failures = []
            for (colIdx, name) in columnNames.enumerated() {
                guard colIdx < grid.colCount else { continue }
                let (col, failure) = buildColumn(colIdx: colIdx, name: name,
                                                 strtodBuf: strtodBuf)
                resultColumns.append(col)
                if let failure { failures.append(failure) }
            }
        }

        // Last-wins can drop a duplicate column; drop its failure entry too
        // so the report only describes columns present in the frame.
        let deduped = Self.dedupeLastWins(resultColumns)
        if deduped.count != resultColumns.count {
            // Keep only the LAST failure entry per duplicated column name.
            var lastByName: [String: ColumnParseFailure] = [:]
            for f in failures { lastByName[f.column] = f }
            failures = deduped.compactMap { lastByName[$0.0] }
        }
        return (DataFrame(columns: deduped), failures)
    }

    // MARK: - Scalar parsers

    /// Byte-level Int64 parser: optional sign, decimal digits only,
    /// overflow-checked. Rejects anything else ("1.0", "1e3", hex, spaces),
    /// matching strict integer contracts.
    internal static func fastParseInt64(
        _ bytes: UnsafeBufferPointer<UInt8>, start s: Int, end e: Int
    ) -> (Bool, Int64) {
        var i = s
        guard i < e else { return (false, 0) }
        var negative = false
        if bytes[i] == 0x2D { negative = true; i += 1 }
        else if bytes[i] == 0x2B { i += 1 }
        guard i < e else { return (false, 0) }

        var magnitude: UInt64 = 0
        var digits = 0
        while i < e {
            let b = bytes[i]
            guard b >= 0x30, b <= 0x39 else { return (false, 0) }
            magnitude = magnitude &* 10 &+ UInt64(b - 0x30)
            digits += 1
            if digits > 19 { return (false, 0) } // > Int64 range for sure
            i += 1
        }
        guard digits > 0 else { return (false, 0) }
        if negative {
            guard magnitude <= UInt64(Int64.max) &+ 1 else { return (false, 0) }
            if magnitude == UInt64(Int64.max) &+ 1 { return (true, Int64.min) }
            return (true, -Int64(magnitude))
        }
        guard magnitude <= UInt64(Int64.max) else { return (false, 0) }
        return (true, Int64(magnitude))
    }

    /// Boolean cell parser for strict `.bool` contracts. Accepts the common
    /// CSV spellings: `true/false` in any letter case, plus `1`/`0`.
    internal static func parseBool(_ s: String) -> Bool? {
        switch s {
        case "1", "true", "True", "TRUE": return true
        case "0", "false", "False", "FALSE": return false
        default:
            let lower = s.lowercased()
            if lower == "true" { return true }
            if lower == "false" { return false }
            return nil
        }
    }

    // MARK: - Duplicate headers

    /// Merges duplicate column names **last-wins**: when a header name
    /// appears more than once, the last occurrence supplies the surviving
    /// column's data and position. Applied by every read path (infer,
    /// strict, all-strings) so a frame never carries two columns with the
    /// same name. This mirrors last-wins dictionary-merge semantics and is
    /// a documented byte-compatibility guarantee.
    internal static func dedupeLastWins(_ columns: [(String, Column)]) -> [(String, Column)] {
        var seen = Set<String>()
        var reversedKept: [(String, Column)] = []
        for (name, col) in columns.reversed() {
            if seen.insert(name).inserted {
                reversedKept.append((name, col))
            }
        }
        return reversedKept.reversed()
    }
}
