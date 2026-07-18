import XCTest
import Foundation
@testable import SwiftPandas

// ===----------------------------------------------------------------------===//
// Tests for contract-driven CSV parsing (strict / allStrings), the canonical
// RFC-4180 CSVLine codec, writer quoting modes, and the streaming row /
// dimensions APIs.
// ===----------------------------------------------------------------------===//

final class CSVStrictReaderTests: XCTestCase {

    /// THE numerification regression test: all-digit identifiers must stay
    /// strings — leading zeros and 16+ digit IDs must survive verbatim.
    func test_allDigitIDs_stayStrings_underContract() {
        let csv = """
        customer_id,sku,amount
        0012345,00099,10.5
        9007199254740993,00100,20.25
        """
        let reader = CSVReader.strict(columnTypes: ["amount": .float64])
        let df = reader.read(from: csv)

        guard case .string(let ids)? = df.columns["customer_id"] else {
            return XCTFail("undeclared customer_id column must stay .string, got \(String(describing: df.columns["customer_id"]?.dtype))")
        }
        XCTAssertEqual(ids[0], "0012345", "leading zeros must survive: strict mode never numerifies")
        XCTAssertEqual(ids[1], "9007199254740993", "IDs beyond Double's integer precision must survive verbatim")
        guard case .string(let skus)? = df.columns["sku"] else {
            return XCTFail("undeclared sku column must stay .string")
        }
        XCTAssertEqual(skus[0], "00099", "all-digit SKU must not lose its leading zeros")
        XCTAssertEqual(df.columns["amount"]?.dtype, .float64, "declared float column must parse as .double")
    }

    func test_allStrings_everyColumnIsString() {
        let csv = "a,b,c\n1,2.5,x\n3,4.5,y\n"
        let df = CSVReader.allStrings.read(from: csv)
        for name in df.columnNames {
            XCTAssertEqual(df.columns[name]?.dtype, .string,
                           "allStrings mode must keep column '\(name)' as .string")
        }
        guard case .string(let a)? = df.columns["a"] else { return XCTFail("column a missing") }
        XCTAssertEqual(a[0], "1", "allStrings must preserve cell text verbatim")
    }

    func test_declaredDtypes_parseToDeclaredStorage() {
        let csv = """
        id,qty,price,active,note
        A1,3,9.99,true,hello
        A2,-7,0.5,false,world
        """
        let reader = CSVReader.strict(columnTypes: [
            "qty": .int64, "price": .float64, "active": .bool,
        ])
        let df = reader.read(from: csv)
        XCTAssertEqual(df.columns["qty"]?.dtype, .int64, "declared int64 must store as .int64")
        XCTAssertEqual(df.columns["price"]?.dtype, .float64, "declared float64 must store as .double")
        XCTAssertEqual(df.columns["active"]?.dtype, .bool, "declared bool must store as .bool")
        XCTAssertEqual(df.columns["id"]?.dtype, .string, "unlisted column must stay .string")
        guard case .int64(let qty)? = df.columns["qty"] else { return XCTFail("qty missing") }
        XCTAssertEqual(qty[1], -7, "negative integers must parse")
        guard case .bool(let active)? = df.columns["active"] else { return XCTFail("active missing") }
        XCTAssertEqual(active[0], true, "bool 'true' must parse")
        XCTAssertEqual(active[1], false, "bool 'false' must parse")
    }

    func test_parseFailures_becomeNA_andAreReported() {
        let csv = """
        qty,price
        3,1.5
        oops,2.5
        NA,not-a-number
        9,also-bad
        """
        let reader = CSVReader.strict(columnTypes: ["qty": .int64, "price": .float64])
        let (df, failures) = reader.readWithReport(from: csv)

        guard case .int64(let qty)? = df.columns["qty"] else { return XCTFail("qty missing") }
        XCTAssertNil(qty[1], "a failed int parse must become NA")
        XCTAssertNil(qty[2], "a declared NA sentinel must be NA (and not counted as a failure)")
        XCTAssertEqual(qty[3], 9, "valid cells after a failure must still parse")

        XCTAssertEqual(failures.count, 2, "one report entry per column with failures, got \(failures)")
        let qtyFail = failures.first { $0.column == "qty" }
        XCTAssertEqual(qtyFail?.failedCount, 1, "qty had exactly one failing cell ('oops'), NA sentinels don't count")
        XCTAssertEqual(qtyFail?.firstFailedRow, 1, "first qty failure is data row 1")
        XCTAssertEqual(qtyFail?.firstFailedValue, "oops", "the report must carry the offending text")
        XCTAssertEqual(qtyFail?.declaredType, .int64, "the report must carry the declared dtype")
        let priceFail = failures.first { $0.column == "price" }
        XCTAssertEqual(priceFail?.failedCount, 2, "price had two failing cells")
    }

    func test_duplicateHeaders_lastWins() {
        let csv = """
        id,value,value
        A,first,second
        B,one,two
        """
        let df = CSVReader.allStrings.read(from: csv)
        XCTAssertEqual(df.columnNames, ["id", "value"], "duplicate headers must merge to a single column")
        guard case .string(let v)? = df.columns["value"] else { return XCTFail("value missing") }
        XCTAssertEqual(v[0], "second", "last occurrence's data must win (columnDTypeMap semantics)")
        XCTAssertEqual(v[1], "two", "last-wins must apply to every row")
    }

    func test_int64Contract_rejectsNonIntegerForms() {
        let csv = "n\n1.0\n1e3\n+42\n"
        let (df, failures) = CSVReader.strict(columnTypes: ["n": .int64]).readWithReport(from: csv)
        guard case .int64(let n)? = df.columns["n"] else { return XCTFail("n missing") }
        XCTAssertNil(n[0], "'1.0' is not a strict integer")
        XCTAssertNil(n[1], "'1e3' is not a strict integer")
        XCTAssertEqual(n[2], 42, "an explicit plus sign is accepted")
        XCTAssertEqual(failures.first?.failedCount, 2, "exactly the two non-integer cells must be reported")
    }
}

final class CSVLineRoundTripTests: XCTestCase {

    /// Fields covering every RFC-4180 corner: embedded separator, embedded
    /// quotes, embedded newlines, CRLF, empties, plain text.
    private static let gnarly: [[String]] = [
        ["plain", "with,comma", "with \"quotes\"", "line\nbreak", "crlf\r\nend", "", "trailing space "],
        ["", "", ""],
        ["only-one"],
        ["\"", "\"\"", ",\n\""],
    ]

    func test_roundTrip_minimalQuoting() {
        for fields in Self.gnarly {
            let record = CSVLine.format(fields, quoting: .minimal)
            let back = CSVLine.parse(Substring(record))
            XCTAssertEqual(back, fields, "minimal-quoting round trip must be lossless for \(fields)")
        }
    }

    func test_roundTrip_quoteAll() {
        for fields in Self.gnarly {
            let record = CSVLine.format(fields, quoting: .all)
            let back = CSVLine.parse(Substring(record))
            XCTAssertEqual(back, fields, "QUOTE_ALL round trip must be lossless for \(fields)")
        }
    }

    func test_minimal_quotesOnlyWhenNeeded() {
        XCTAssertEqual(CSVLine.escapeField("plain", quoting: .minimal), "plain",
                       "a field with no special characters must pass through byte-for-byte")
        XCTAssertEqual(CSVLine.escapeField("a,b", quoting: .minimal), "\"a,b\"",
                       "a separator forces quoting")
        XCTAssertEqual(CSVLine.escapeField("say \"hi\"", quoting: .minimal), "\"say \"\"hi\"\"\"",
                       "internal quotes must double")
        XCTAssertEqual(CSVLine.escapeField("cr\rhere", quoting: .minimal), "\"cr\rhere\"",
                       "a bare CR forces quoting")
    }

    func test_quoteAll_quotesEverything() {
        XCTAssertEqual(CSVLine.escapeField("plain", quoting: .all), "\"plain\"",
                       "QUOTE_ALL must quote even plain fields")
        XCTAssertEqual(CSVLine.format(["1", "x"], quoting: .all), "\"1\",\"x\"",
                       "QUOTE_ALL must quote numeric-looking fields too")
    }

    func test_parse_handlesTrailingCR() {
        XCTAssertEqual(CSVLine.parse(Substring("a,b\r")), ["a", "b"],
                       "a trailing CR (CRLF record split on LF) must be stripped from the last field")
    }

    func test_emptyRecord_isOneEmptyField() {
        XCTAssertEqual(CSVLine.parse(Substring("")), [""],
                       "per RFC 4180 the empty record is one empty field")
    }

    func test_writer_quoteAll_roundTripsThroughReader() {
        let df = DataFrame(columns: [
            ("id", .fromStrings(["0012345", "a,b", "q\"q"])),
            ("v", .fromDoubles([1, 2.5, 3])),
        ])
        let quoted = df.toCSV(quoting: .all)
        XCTAssertTrue(quoted.hasPrefix("\"id\",\"v\"\n"), "QUOTE_ALL must quote header names, got: \(quoted.prefix(20))")
        let back = CSVReader.allStrings.read(from: quoted)
        guard case .string(let ids)? = back.columns["id"] else { return XCTFail("id missing") }
        XCTAssertEqual(ids[0], "0012345", "QUOTE_ALL output must parse back losslessly")
        XCTAssertEqual(ids[1], "a,b", "embedded separators must survive the round trip")
        XCTAssertEqual(ids[2], "q\"q", "embedded quotes must survive the round trip")
    }

    func test_writer_minimal_unchangedFieldsPassThrough() {
        let df = DataFrame(columns: [("v", .fromDoubles([1, 2]))])
        XCTAssertEqual(df.toCSV(), "v\n1\n2\n",
                       "minimal quoting must not quote fields that need no quoting (RFC 4180)")
    }
}

final class CSVStreamingTests: XCTestCase {

    private func tempCSV(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftpandas-stream-\(UUID().uuidString).csv")
        try content.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A quoted fixture with embedded newlines, commas, and escaped quotes —
    /// everything the grid parser handles.
    private static let quotedFixture =
        "name,desc,qty\n"
        + "widget,\"a, plain one\",3\n"
        + "gadget,\"multi\nline \"\"desc\"\"\",7\n"
        + "short,,"

    func test_rows_yieldExactlyTheRowsOfAFullRead() throws {
        let url = try tempCSV(Self.quotedFixture)
        let reader = CSVReader()
        let full = try reader.read(from: url)
        let streamed = Array(try reader.rows(url: url))

        XCTAssertEqual(streamed.count, full.rowCount,
                       "streaming must yield exactly the data-row count of a full read")
        for (rowIdx, fields) in streamed.enumerated() {
            for (colIdx, name) in full.columnNames.enumerated() {
                let cell = full.columns[name]!.value(at: rowIdx)
                let expected: String
                switch cell {
                case let s as String: expected = s
                case let d as Double: expected = d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(d)) : String(d)
                case nil: expected = ""
                default: expected = "\(cell!)"
                }
                XCTAssertEqual(fields[colIdx], expected,
                               "row \(rowIdx) col '\(name)': streamed field must match the full parse")
            }
        }
    }

    func test_rows_exposesHeaderAndSkipsIt() throws {
        let url = try tempCSV("a,b\n1,2\n3,4\n")
        let seq = try CSVReader().rows(url: url)
        XCTAssertEqual(seq.header, ["a", "b"], "the header row must be exposed, not yielded")
        XCTAssertEqual(Array(seq), [["1", "2"], ["3", "4"]], "iteration must yield data rows only")
    }

    func test_rows_headerFalse_yieldsAllRecords() throws {
        let url = try tempCSV("1,2\n3,4\n")
        let seq = try CSVReader(header: false).rows(url: url)
        XCTAssertNil(seq.header, "header:false must expose no header")
        XCTAssertEqual(Array(seq).count, 2, "header:false must yield every record")
    }

    func test_rows_isRepeatable() throws {
        let url = try tempCSV("a\n1\n2\n")
        let seq = try CSVReader().rows(url: url)
        XCTAssertEqual(Array(seq), Array(seq), "each makeIterator() must start a fresh pass")
    }

    func test_dimensions_matchFullParse_onQuotedFixture() throws {
        let url = try tempCSV(Self.quotedFixture)
        let full = try CSVReader().read(from: url)
        let dims = try CSVReader.dimensions(url: url)
        XCTAssertEqual(dims.rows, full.rowCount,
                       "dimensions row count must match a full parse (quoted newlines must not split records)")
        XCTAssertEqual(dims.cols, full.columnNames.count,
                       "dimensions column count must match a full parse")
    }

    func test_dimensions_noTrailingNewline_countsLastRow() throws {
        let url = try tempCSV("a,b\n1,2\n3,4")
        let dims = try CSVReader.dimensions(url: url)
        XCTAssertEqual(dims.rows, 2, "a final record without trailing newline must count")
        XCTAssertEqual(dims.cols, 2, "column count comes from the first record")
    }

    func test_dimensions_emptyFile_isZeroZero() throws {
        let url = try tempCSV("")
        let dims = try CSVReader.dimensions(url: url)
        XCTAssertEqual(dims.rows, 0, "an empty file has no rows")
        XCTAssertEqual(dims.cols, 0, "an empty file has no columns")
    }
}
