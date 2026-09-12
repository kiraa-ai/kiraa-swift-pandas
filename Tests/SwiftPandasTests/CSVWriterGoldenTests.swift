import XCTest
import Foundation
@testable import SwiftPandas

/// D1 acceptance: the byte-level CSV writer must be byte-identical to the
/// legacy String-based writer (`CSVWriter.writeLegacy`), which is retained
/// in the module as the parity oracle.
///
/// Three layers of pinning:
/// 1. **Corpus parity** — hand-built frames covering the quoting/formatting
///    edge cases, cross-multiplied with writer configurations.
/// 2. **Golden literals** — a few outputs pinned as exact strings, so a
///    regression shared by both writers cannot hide behind parity.
/// 3. **Seeded fuzz** — randomized frames (deterministic LCG, reproducible
///    run-to-run) asserting parity, including one frame large enough to
///    drive the parallel chunk path.
///
/// **Documented divergence:** Swift's `String.contains` is grapheme-cluster
/// based, so the legacy writer fails to quote a field whose only special
/// bytes sit inside a cluster — `"\r\n"` (one cluster) or a separator/quote
/// followed by a combining mark. Legacy emits malformed CSV for those; the
/// byte writer scans UTF-8 and quotes them correctly. That is a deliberate
/// fix, pinned in `testDivergence_graphemeClusteredSpecials`.
final class CSVWriterGoldenTests: XCTestCase {

    // MARK: - Column construction helpers

    private func doubles(_ v: [Double?]) -> Column { .double(NullableArray<Double>(v)) }
    /// All-valid doubles — the only way to build a *valid* NaN cell (the
    /// `[Double?]` init would treat NaN storage as maskable placeholder).
    private func validDoubles(_ v: [Double]) -> Column { .double(NullableArray(NativeArray(v))) }
    private func ints(_ v: [Int64?]) -> Column { .int64(NullableArray<Int64>(v)) }
    private func bools(_ v: [Bool?]) -> Column { .bool(NullableArray<Bool>(v, naPlaceholder: false)) }
    private func strings(_ v: [String?]) -> Column { .string(StringArray(v)) }

    // MARK: - Corpus

    private var corpusFrames: [(name: String, df: DataFrame)] {
        [
            ("mixed", DataFrame(columns: [
                ("id", ints([1, nil, -3, Int64.max, Int64.min])),
                ("name", strings(["plain", "a,b", nil, "say \"hi\"", "line\nbreak"])),
                ("score", validDoubles([1.5, -0.0, 2.0, Double.nan, .infinity])),
                ("ok", bools([true, false, nil, true, false])),
            ])),
            ("numerics", DataFrame(columns: [
                ("d", validDoubles([0.0, -0.0, 0.1, 1e15, -1e15, 1e-300, 1e300,
                                    999_999_999_999_999.0, -2.5, Double.nan,
                                    .infinity, -.infinity])),
                ("i", ints([0, 1, -1, 42, Int64.max, Int64.min, nil,
                            1_234_567_890_123_456_789, -7, 10, 100, 1000])),
            ])),
            ("unicode", DataFrame(columns: [
                ("s", strings(["héllo", "日本語", "🦀 astral 🙂", "e\u{301}fine",
                               "cr\rreturn", "nl\nbreak", "tab\tcell", "trailing  "])),
                ("v", doubles([1, 2, 3, 4, nil, 6, 7, 8])),
            ])),
            ("empty-and-na", DataFrame(columns: [
                ("s", strings(["", nil, " ", ""])),
                ("d", doubles([nil, 1.0, nil, 0.0])),
            ])),
            ("single-string-col", DataFrame(columns: [
                ("only", strings(["x", "a,b", nil])),
            ])),
            ("zero-rows", DataFrame(columns: [
                ("a", ints([])),
                ("b,comma", strings([])),
            ])),
        ]
    }

    private var writerConfigs: [(name: String, writer: CSVWriter)] {
        [
            ("default", CSVWriter()),
            ("quoteAll", CSVWriter(quoting: .all)),
            ("index", CSVWriter(includeIndex: true)),
            ("noHeader", CSVWriter(includeHeader: false)),
            ("semicolon", CSVWriter(separator: ";")),
            ("tab", CSVWriter(separator: "\t")),
            ("naRep", CSVWriter(naRepresentation: "NULL")),
            // NA text containing the separator: legacy quotes it in string
            // columns but emits it raw in numeric columns — parity must
            // reproduce that asymmetry exactly.
            ("naRepComma", CSVWriter(naRepresentation: "n,a")),
            ("kitchenSink", CSVWriter(separator: ";", includeHeader: true,
                                      includeIndex: true, naRepresentation: "NA",
                                      quoting: .all)),
        ]
    }

    // MARK: - 1. Corpus parity

    func testParity_corpusAcrossAllConfigs() {
        for (frameName, df) in corpusFrames {
            for (configName, writer) in writerConfigs {
                XCTAssertEqual(
                    writer.write(df), writer.writeLegacy(df),
                    "byte writer diverged from legacy: frame=\(frameName) config=\(configName)")
            }
        }
    }

    // MARK: - 2. Golden literals

    private var goldenFrame: DataFrame {
        DataFrame(columns: [
            ("id", ints([1, nil, -3])),
            ("name", strings(["plain", "a,b", nil])),
            ("score", validDoubles([1.5, -0.0, 2.0])),
            ("ok", bools([true, false, nil])),
        ])
    }

    func testGolden_defaultConfig() {
        let expected = """
        id,name,score,ok
        1,plain,1.5,True
        ,"a,b",0,False
        -3,,2,

        """
        XCTAssertEqual(CSVWriter().write(goldenFrame), expected)
        XCTAssertEqual(CSVWriter().writeLegacy(goldenFrame), expected)
    }

    func testGolden_quoteAll() {
        let expected = """
        "id","name","score","ok"
        "1","plain","1.5","True"
        "","a,b","0","False"
        "-3","","2",""

        """
        let writer = CSVWriter(quoting: .all)
        XCTAssertEqual(writer.write(goldenFrame), expected)
        XCTAssertEqual(writer.writeLegacy(goldenFrame), expected)
    }

    func testGolden_embeddedQuoteDoubling() {
        let df = DataFrame(columns: [("q", strings(["say \"hi\""]))])
        let expected = "q\n\"say \"\"hi\"\"\"\n"
        XCTAssertEqual(CSVWriter().write(df), expected)
        XCTAssertEqual(CSVWriter().writeLegacy(df), expected)
    }

    // MARK: - 3. Seeded fuzz parity

    /// Deterministic LCG (Numerical Recipes constants) — reproducible
    /// run-to-run, matching the repo's determinism contract.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    /// Pool values are parity-safe: any special byte they contain is its own
    /// grapheme cluster, so legacy `contains` and the byte scan agree. The
    /// grapheme-clustered pathologies live in the divergence test instead.
    private let stringPool: [String?] = [
        "plain", "a,b", "q\"uote", "nl\nx", "cr\rx", "", nil,
        "héllo", "🙂🦀", "  spaced  ", "semi;colon", "tab\tsep", "e\u{301}fine",
    ]
    private let doublePool: [Double] = [
        0.0, -0.0, 0.5, -2.75, 1e14, 999_999_999_999_999.0, 1e15,
        1e-300, 1e300, 123.456, Double.nan, .infinity, -.infinity,
    ]
    private let intPool: [Int64?] = [
        0, 1, -1, 42, Int64.max, Int64.min, nil, 1_234_567_890_123_456_789,
    ]

    private func randomFrame(rows: Int, rng: inout LCG) -> DataFrame {
        var s = [String?](), dv = [Double](), dm = [Double?](), iv = [Int64?](), b = [Bool?]()
        for _ in 0..<rows {
            s.append(stringPool[rng.below(stringPool.count)])
            dv.append(doublePool[rng.below(doublePool.count)])
            dm.append(rng.below(5) == 0 ? nil : doublePool[rng.below(doublePool.count - 3)])
            iv.append(intPool[rng.below(intPool.count)])
            b.append([true, false, nil][rng.below(3)])
        }
        return DataFrame(columns: [
            ("s", strings(s)), ("dv", validDoubles(dv)), ("dm", doubles(dm)),
            ("i", ints(iv)), ("b", bools(b)),
        ])
    }

    func testParity_fuzz() {
        var rng = LCG(state: 0x5EED_CAFE)
        let configs = [CSVWriter(), CSVWriter(quoting: .all),
                       CSVWriter(separator: ";", includeIndex: true)]
        for iteration in 0..<40 {
            let df = randomFrame(rows: rng.below(33), rng: &rng)
            for (c, writer) in configs.enumerated() {
                XCTAssertEqual(
                    writer.write(df), writer.writeLegacy(df),
                    "fuzz parity failed: iteration=\(iteration) config=\(c) seed=0x5EED_CAFE")
            }
        }
    }

    /// Drives the concurrent chunk path (rows > 65 536) and pins it against
    /// the sequential legacy writer — chunked output must be byte-identical.
    func testParity_parallelChunkPath() {
        let rows = 70_000
        var s = [String?](), d = [Double](), iv = [Int64?]()
        for i in 0..<rows {
            s.append(stringPool[i % stringPool.count])
            d.append(i % 7 == 0 ? Double(i) + 0.5 : Double(i))
            iv.append(i % 11 == 0 ? nil : Int64(i))
        }
        let df = DataFrame(columns: [
            ("s", strings(s)), ("d", validDoubles(d)), ("i", ints(iv)),
        ])
        let writer = CSVWriter()
        XCTAssertEqual(writer.write(df), writer.writeLegacy(df))
    }

    // MARK: - File output parity

    func testFileWrite_matchesInMemoryBytes() throws {
        let df = corpusFrames[0].df
        let writer = CSVWriter()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try writer.write(df, to: url)
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(Array(onDisk), Array(writer.write(df).utf8))
    }

    // MARK: - Multi-byte separator fallback

    func testMultiByteSeparator_routesToLegacy() {
        let df = DataFrame(columns: [
            ("a", strings(["x"])), ("b", strings(["y"])),
        ])
        let writer = CSVWriter(separator: "||")
        XCTAssertNil(writer.fastSeparatorByte)
        XCTAssertEqual(writer.write(df), "a||b\nx||y\n")
        XCTAssertEqual(writer.write(df), writer.writeLegacy(df))
    }

    // MARK: - Documented divergence (deliberate correctness fix)

    /// Swift's grapheme-based `contains` makes the legacy writer blind to
    /// special *bytes* hiding inside a cluster: `"\r\n"` is one cluster that
    /// matches neither `"\n"` nor `"\r"`, and `,`/`"` followed by a combining
    /// mark stops matching the bare character. Legacy emitted those fields
    /// unquoted/unescaped — malformed CSV. The byte writer quotes them.
    func testDivergence_graphemeClusteredSpecials() {
        // Sanity-check the platform semantics the divergence rests on; if a
        // future Swift changes contains(), legacy heals and parity resumes.
        guard !"a\r\nb".contains("\n") else {
            XCTAssertEqual(
                CSVWriter().write(DataFrame(columns: [("s", strings(["a\r\nb"]))])),
                CSVWriter().writeLegacy(DataFrame(columns: [("s", strings(["a\r\nb"]))])))
            return
        }

        let crlf = DataFrame(columns: [("s", strings(["a\r\nb"]))])
        XCTAssertEqual(CSVWriter().write(crlf), "s\n\"a\r\nb\"\n",
                       "byte writer must quote CRLF-in-cell")
        XCTAssertEqual(CSVWriter().writeLegacy(crlf), "s\na\r\nb\n",
                       "legacy emits CRLF unquoted (malformed) — the defect this pins")

        let combiningComma = DataFrame(columns: [("s", strings(["a,\u{0308}b"]))])
        XCTAssertEqual(CSVWriter().write(combiningComma), "s\n\"a,\u{0308}b\"\n",
                       "byte writer must quote separator + combining mark")

        let combiningQuote = DataFrame(columns: [("s", strings(["q\"\u{0301}x"]))])
        XCTAssertEqual(CSVWriter().write(combiningQuote), "s\n\"q\"\"\u{0301}x\"\n",
                       "byte writer must double a quote even with a trailing combining mark")
    }
}
