import XCTest
import Foundation
@testable import SwiftPandas

/// The CSV writer's output contract, tested directly:
///
/// 1. **Pinned outputs** — exact expected CSV for the semantic matrix:
///    RFC 4180 quoting (minimal and QUOTE_ALL), numeric formatting, NA
///    representation, header/index options, separators (single- and
///    multi-byte).
/// 2. **Reader round-trip** — what the writer emits, `CSVReader` parses
///    back to the same values; that is the interoperability promise.
/// 3. **Chunked = sequential** — writing a frame whole equals writing its
///    row ranges separately and concatenating, which is the property the
///    concurrent chunk path relies on.
/// 4. **File output** — bytes on disk equal the in-memory serialization.
final class CSVWriterTests: XCTestCase {

    // MARK: - Column construction helpers

    private func doubles(_ v: [Double?]) -> Column { .double(NullableArray<Double>(v)) }
    /// All-valid doubles — the way to build a *valid* NaN/inf cell.
    private func validDoubles(_ v: [Double]) -> Column { .double(NullableArray(NativeArray(v))) }
    private func ints(_ v: [Int64?]) -> Column { .int64(NullableArray<Int64>(v)) }
    private func bools(_ v: [Bool?]) -> Column { .bool(NullableArray<Bool>(v, naPlaceholder: false)) }
    private func strings(_ v: [String?]) -> Column { .string(StringArray(v)) }

    private var sampleFrame: DataFrame {
        DataFrame(columns: [
            ("id", ints([1, nil, -3])),
            ("name", strings(["plain", "a,b", nil])),
            ("score", validDoubles([1.5, -0.0, 2.0])),
            ("ok", bools([true, false, nil])),
        ])
    }

    // MARK: - 1. Pinned outputs

    func testDefaultOptions() {
        let expected = """
        id,name,score,ok
        1,plain,1.5,True
        ,"a,b",0,False
        -3,,2,

        """
        XCTAssertEqual(CSVWriter().write(sampleFrame), expected)
    }

    func testQuoteAll() {
        let expected = """
        "id","name","score","ok"
        "1","plain","1.5","True"
        "","a,b","0","False"
        "-3","","2",""

        """
        XCTAssertEqual(CSVWriter(quoting: .all).write(sampleFrame), expected)
    }

    func testEmbeddedQuotesAreDoubled() {
        let df = DataFrame(columns: [("q", strings(["say \"hi\""]))])
        XCTAssertEqual(CSVWriter().write(df), "q\n\"say \"\"hi\"\"\"\n")
    }

    func testNumericFormatting() {
        // Integral doubles below 1e15 print as integers (pandas style);
        // fractional, huge, and non-finite values use Swift's shortest
        // representation. -0.0 prints as 0.
        let df = DataFrame(columns: [
            ("d", validDoubles([0.0, -0.0, 0.1, 1e15, 999_999_999_999_999.0,
                                Double.nan, .infinity, -.infinity])),
        ])
        XCTAssertEqual(CSVWriter().write(df),
                       "d\n0\n0\n0.1\n1000000000000000.0\n999999999999999\nnan\ninf\n-inf\n")
    }

    func testInt64Bounds() {
        let df = DataFrame(columns: [("i", ints([0, Int64.max, Int64.min]))])
        XCTAssertEqual(CSVWriter().write(df),
                       "i\n0\n9223372036854775807\n-9223372036854775808\n")
    }

    func testNARepresentation() {
        let df = DataFrame(columns: [
            ("s", strings([nil, "x"])),
            ("d", doubles([nil, 1.0])),
        ])
        XCTAssertEqual(CSVWriter(naRepresentation: "NULL").write(df),
                       "s,d\nNULL,NULL\nx,1\n")
        // NA text containing the separator is quoted in string columns but
        // emitted raw in numeric columns, where nothing is ever quoted in
        // minimal mode.
        XCTAssertEqual(CSVWriter(naRepresentation: "n,a").write(df),
                       "s,d\n\"n,a\",n,a\nx,1\n")
    }

    func testHeaderAndIndexOptions() {
        let df = DataFrame(columns: [("a", strings(["x", "y"]))])
        XCTAssertEqual(CSVWriter(includeHeader: false).write(df), "x\ny\n")
        XCTAssertEqual(CSVWriter(includeIndex: true).write(df), ",a\n0,x\n1,y\n")
    }

    func testZeroRowFrame() {
        let df = DataFrame(columns: [("a", ints([])), ("b,comma", strings([]))])
        XCTAssertEqual(CSVWriter().write(df), "a,\"b,comma\"\n")
        XCTAssertEqual(CSVWriter(includeHeader: false).write(df), "")
    }

    func testSeparators() {
        let df = DataFrame(columns: [
            ("a", strings(["x", "has;semi"])),
            ("b", strings(["y", "z"])),
        ])
        XCTAssertEqual(CSVWriter(separator: ";").write(df),
                       "a;b\nx;y\n\"has;semi\";z\n")
        XCTAssertEqual(CSVWriter(separator: "\t").write(df),
                       "a\tb\nx\ty\nhas;semi\tz\n")
        // Multi-byte separators: emitted between fields, and a field
        // containing the separator sequence is quoted.
        let df2 = DataFrame(columns: [
            ("a", strings(["x", "has||pipes"])),
            ("b", strings(["y", "z"])),
        ])
        XCTAssertEqual(CSVWriter(separator: "||").write(df2),
                       "a||b\nx||y\n\"has||pipes\"||z\n")
    }

    /// Special bytes hiding inside a grapheme cluster must still trigger
    /// quoting: `"\r\n"` is one cluster, and a separator or quote followed
    /// by a combining mark stops being its own cluster — a byte-level scan
    /// catches all of them, a grapheme-level search does not.
    func testGraphemeClusteredSpecialsAreQuoted() {
        XCTAssertEqual(
            CSVWriter().write(DataFrame(columns: [("s", strings(["a\r\nb"]))])),
            "s\n\"a\r\nb\"\n")
        XCTAssertEqual(
            CSVWriter().write(DataFrame(columns: [("s", strings(["a,\u{0308}b"]))])),
            "s\n\"a,\u{0308}b\"\n")
        XCTAssertEqual(
            CSVWriter().write(DataFrame(columns: [("s", strings(["q\"\u{0301}x"]))])),
            "s\n\"q\"\"\u{0301}x\"\n")
    }

    // MARK: - 2. Reader round-trip

    /// What the writer emits, the reader parses back to the same values —
    /// including quoted separators, escaped quotes, embedded newlines,
    /// unicode, and NA cells.
    func testReaderRoundTrip_strings() {
        let values: [String?] = ["plain", "a,b", "say \"hi\"", "line\nbreak",
                                 "héllo", "🦀", nil, "  padded  "]
        let df = DataFrame(columns: [("s", strings(values))])
        let back = CSVReader().read(from: CSVWriter().write(df))
        guard case .string(let col) = back.columns["s"]! else {
            return XCTFail("string column did not round-trip as string")
        }
        XCTAssertEqual((0..<col.count).map { col[$0] }, values)
    }

    func testReaderRoundTrip_numerics() {
        let values: [Double] = [0, 0.5, -2.75, 1e14, 123.456, 1e-300, 1e300]
        let df = DataFrame(columns: [("d", validDoubles(values))])
        let back = CSVReader().read(from: CSVWriter().write(df))
        guard case .double(let col) = back.columns["d"]! else {
            return XCTFail("numeric column did not round-trip as numeric")
        }
        XCTAssertEqual((0..<col.count).map { col[$0] }, values.map { $0 })
    }

    /// Seeded randomized round-trip. The value pool avoids the documented
    /// read-side asymmetries (NA sentinels like "NA"/"" parse back as NA;
    /// "nan" is an NA sentinel; all-numeric string columns infer numeric),
    /// so equality is exact.
    func testReaderRoundTrip_randomized() {
        struct LCG {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return state
            }
            mutating func below(_ n: Int) -> Int { Int((next() >> 33) % UInt64(n)) }
        }
        let pool: [String?] = ["plain", "a,b", "q\"uote", "nl\nx", "cr\rx", nil,
                               "héllo", "🙂🦀", "  spaced  ", "semi;colon", "tab\tsep"]
        var rng = LCG(state: 0xC5C5)
        for iteration in 0..<25 {
            let rows = 1 + rng.below(40)
            // Anchor row: a column of only NAs would legitimately infer
            // numeric on read-back, which is not what this test is about.
            var s: [String?] = ["anchor"], d: [Double] = [0.5]
            for _ in 0..<rows {
                s.append(pool[rng.below(pool.count)])
                d.append(Double(rng.below(1 << 40)) / 1024)
            }
            let df = DataFrame(columns: [("s", strings(s)), ("d", validDoubles(d))])
            let back = CSVReader().read(from: CSVWriter().write(df))
            guard case .string(let sCol) = back.columns["s"]!,
                  case .double(let dCol) = back.columns["d"]! else {
                return XCTFail("iteration \(iteration): dtypes changed in round-trip")
            }
            XCTAssertEqual((0..<sCol.count).map { sCol[$0] }, s, "iteration \(iteration)")
            XCTAssertEqual((0..<dCol.count).map { dCol[$0] }, d.map { $0 }, "iteration \(iteration)")
        }
    }

    // MARK: - 3. Chunked = sequential

    /// Formatting is pure per-row, so writing the whole frame (which uses
    /// the concurrent chunk path above 2^16 rows) must equal the header
    /// plus each row range written independently.
    func testWholeFrameEqualsConcatenatedRowRanges() {
        let rows = 70_000
        let split = 31_337
        var s = [String?](), d = [Double](), iv = [Int64?]()
        let pool: [String?] = ["alpha", "beta,comma", nil, "q\"z", "0800"]
        for i in 0..<rows {
            s.append(pool[i % pool.count])
            d.append(i % 7 == 0 ? Double(i) + 0.5 : Double(i))
            iv.append(i % 11 == 0 ? nil : Int64(i))
        }
        func frame(_ range: Range<Int>) -> DataFrame {
            DataFrame(columns: [
                ("s", strings(Array(s[range]))),
                ("d", validDoubles(Array(d[range]))),
                ("i", ints(Array(iv[range]))),
            ])
        }
        let whole = CSVWriter().write(frame(0..<rows))
        let headerless = CSVWriter(includeHeader: false)
        let concatenated = "s,d,i\n"
            + headerless.write(frame(0..<split))
            + headerless.write(frame(split..<rows))
        XCTAssertEqual(whole, concatenated)
    }

    // MARK: - 4. File output

    func testFileWriteMatchesInMemoryBytes() throws {
        let writer = CSVWriter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try writer.write(sampleFrame, to: url)
        XCTAssertEqual(Array(try Data(contentsOf: url)),
                       Array(writer.write(sampleFrame).utf8))
    }
}
