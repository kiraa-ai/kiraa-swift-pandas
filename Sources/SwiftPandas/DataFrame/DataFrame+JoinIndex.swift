// ===----------------------------------------------------------------------===//
//
// DataFrame+JoinIndex.swift
// SwiftPandas
//
// Join-index utilities: O(1)-lookup dictionaries built from key columns.
// These replace hand-rolled per-consumer join dictionaries (the
// `[String: [String: String]]` pattern built by re-walking CSV rows) with
// one canonical, documented implementation.
//
// ## Last-row-wins — a byte-parity-relevant guarantee
//
// When the same key value occurs on multiple rows, the LAST row's data
// wins in every API in this file. That matches the semantics of building a
// dictionary in file order (`dict[key] = value` per row), which is what
// hand-rolled loaders do — so replacing them with these APIs preserves
// output byte-for-byte.
//
// ## Key stringification
//
// Keys and looked-up values are the cell's CSV text: string cells verbatim,
// numeric cells in ``CSVWriter`` format (integral doubles print without a
// decimal point: 42.0 → "42"), bools as "True"/"False", and NA as the empty
// string — the same text a CSV round-trip would produce, so an index built
// from a parsed frame agrees with one built from the raw file.
//
// ===----------------------------------------------------------------------===//

import Foundation

extension DataFrame {
    /// Builds a row index over a key column: key text → row position.
    ///
    /// Duplicate keys resolve **last-row-wins** (see the file-level note; a
    /// consumer that previously built `dict[row[key]] = rowIndex` in file
    /// order gets identical results). NA keys index under the empty string.
    ///
    /// - Parameter keyColumn: Name of the column to index on.
    /// - Returns: A dictionary from key text to zero-based row index.
    ///   Empty when the column does not exist.
    public func index(on keyColumn: String) -> [String: Int] {
        guard let col = columns[keyColumn] else { return [:] }
        var result = [String: Int](minimumCapacity: rowCount)
        for row in 0..<rowCount {
            result[Self.joinKeyText(col, row)] = row
        }
        return result
    }

    /// Builds a row index over a composite key: the key texts of
    /// `keyColumns` joined by `separator` → row position.
    ///
    /// Duplicate composite keys resolve **last-row-wins**. Missing columns
    /// contribute an empty component (so the arity of the composite key is
    /// stable); NA cells likewise render as the empty string. Choose a
    /// `separator` that cannot occur inside key values.
    ///
    /// - Parameters:
    ///   - keyColumns: Ordered column names forming the composite key.
    ///   - separator: Joiner between key components. Defaults to `"|"`.
    /// - Returns: A dictionary from joined key text to zero-based row index.
    ///   Empty when `keyColumns` is empty.
    public func index(on keyColumns: [String], separator: String = "|") -> [String: Int] {
        guard !keyColumns.isEmpty else { return [:] }
        let cols = keyColumns.map { columns[$0] }
        var result = [String: Int](minimumCapacity: rowCount)
        for row in 0..<rowCount {
            let key = cols
                .map { $0.map { Self.joinKeyText($0, row) } ?? "" }
                .joined(separator: separator)
            result[key] = row
        }
        return result
    }

    /// Builds a lookup table mapping one column's text to another's:
    /// `key` column text → `value` column text.
    ///
    /// This is the canonical replacement for the per-consumer
    /// `[String: String]` join dictionaries built by re-walking CSV rows.
    /// Duplicate keys resolve **last-row-wins**; NA cells (key or value)
    /// render as the empty string, matching what those cells look like in
    /// the CSV file itself.
    ///
    /// - Parameters:
    ///   - key: Name of the column supplying dictionary keys.
    ///   - value: Name of the column supplying dictionary values.
    /// - Returns: The lookup dictionary. Empty when either column is missing.
    public func lookupTable(key: String, value: String) -> [String: String] {
        guard let keyCol = columns[key], let valueCol = columns[value] else { return [:] }
        var result = [String: String](minimumCapacity: rowCount)
        for row in 0..<rowCount {
            result[Self.joinKeyText(keyCol, row)] = Self.joinKeyText(valueCol, row)
        }
        return result
    }

    /// The canonical cell-to-text rule for join keys and lookup values:
    /// CSV-round-trip text. String cells verbatim; doubles via the
    /// ``CSVWriter`` integral-collapse rule (42.0 → "42"); Int64 as plain
    /// digits; bools as "True"/"False"; NA as "".
    internal static func joinKeyText(_ col: Column, _ row: Int) -> String {
        switch col {
        case .string(let a):
            return a[row] ?? ""
        case .double(let a):
            guard let v = a[row] else { return "" }
            if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
                return String(Int64(v))
            }
            return String(v)
        case .int64(let a):
            guard let v = a[row] else { return "" }
            return String(v)
        case .bool(let a):
            guard let v = a[row] else { return "" }
            return v ? "True" : "False"
        case .floatVector:
            // Vector columns are rejected as join keys before any key-text
            // path runs (merge throws VectorError.unsupportedOperation); this
            // arm exists only to keep the switch exhaustive without `default:`.
            return ""
        }
    }
}
