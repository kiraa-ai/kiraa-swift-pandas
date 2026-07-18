// ===----------------------------------------------------------------------===//
//
// CSVLine.swift
// SwiftPandas — CSV I/O
//
// THE canonical RFC-4180 record codec. Every hand-rolled "split on comma
// unless quoted" helper should be replaced by `CSVLine.parse`, and every
// hand-rolled field escaper by `CSVLine.escapeField` / `CSVLine.format`.
// Having exactly one implementation is a byte-parity guarantee: two stages
// that both use CSVLine agree on every corner case (embedded separators,
// doubled quotes, embedded newlines) by construction.
//
// ===----------------------------------------------------------------------===//

import Foundation

/// Field-quoting policy for CSV output.
///
/// Both modes exist in the wild in the same pipeline, so both are named,
/// documented modes here rather than ad-hoc conventions:
///
/// - ``minimal`` — RFC 4180: a field is quoted only when it contains the
///   separator, a double quote, CR, or LF. Unquoted fields are emitted
///   byte-for-byte.
/// - ``all`` — Python `csv.QUOTE_ALL`: every field (including header names)
///   is wrapped in double quotes, whether it needs them or not.
///
/// In both modes a double quote inside a quoted field is escaped by
/// doubling (`"` → `""`), exactly per RFC 4180. Round-trip byte
/// compatibility: for any field list, `CSVLine.parse(CSVLine.format(f, q))`
/// returns `f` for either quoting mode, and parsing does not care which
/// mode produced the input.
public enum CSVQuoting: Sendable {
    /// RFC 4180 minimal quoting: quote only fields containing the
    /// separator, `"`, `\n`, or `\r`.
    case minimal
    /// `QUOTE_ALL`: quote every field unconditionally.
    case all
}

/// The canonical RFC-4180 record parser/formatter.
///
/// A "line" here is one logical CSV **record** — it may legally contain
/// embedded newlines inside quoted fields. `parse` and `format` are exact
/// inverses for any field content, in either quoting mode.
public enum CSVLine {
    /// Parses one CSV record into its fields (RFC 4180, comma separator).
    ///
    /// Rules applied:
    /// - Fields are separated by `,` outside quotes.
    /// - A field beginning with `"` is quoted: its content runs to the
    ///   matching close quote and may contain commas, newlines, and doubled
    ///   quotes (`""` → `"`).
    /// - Quotes appearing mid-field in an unquoted field are kept literally
    ///   (lenient, matching common parser behavior).
    /// - A single trailing `\r` (from a CRLF record split on `\n`) is
    ///   dropped from the last field.
    /// - The empty record parses to `[""]` — one empty field, per RFC 4180.
    ///
    /// - Parameter line: One record, without its terminating LF.
    /// - Returns: The record's fields, unescaped.
    public static func parse(_ line: Substring) -> [String] {
        parse(line, separator: ",")
    }

    /// Separator-generalized variant of ``parse(_:)`` used by readers with
    /// non-comma separators. Identical semantics otherwise.
    public static func parse(_ line: Substring, separator: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        let end = line.endIndex

        while i < end {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < end && line[next] == "\"" {
                        current.append("\"")
                        i = line.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else if ch == "\"" && current.isEmpty {
                inQuotes = true
            } else if ch == separator {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        if current.hasSuffix("\r") { current.removeLast() }
        fields.append(current)
        return fields
    }

    /// Formats fields as one CSV record (comma separator, no trailing
    /// newline), applying the given quoting mode via ``escapeField(_:quoting:)``.
    public static func format(_ fields: [String], quoting: CSVQuoting) -> String {
        fields.map { escapeField($0, quoting: quoting) }.joined(separator: ",")
    }

    /// Escapes one field per the quoting mode.
    ///
    /// - ``CSVQuoting/all``: always `"..."` with internal quotes doubled.
    /// - ``CSVQuoting/minimal``: quoted (with internal quotes doubled) only
    ///   when the field contains `,`, `"`, `\n`, or `\r`; otherwise the
    ///   field's bytes are emitted unchanged.
    public static func escapeField(_ f: String, quoting: CSVQuoting) -> String {
        switch quoting {
        case .all:
            return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .minimal:
            if f.contains(",") || f.contains("\"") || f.contains("\n") || f.contains("\r") {
                return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return f
        }
    }
}
