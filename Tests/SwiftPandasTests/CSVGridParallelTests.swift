import XCTest
import Foundation
@testable import SwiftPandas

/// D4 (stage 2) acceptance: the chunked, speculative field-grid scanner
/// must produce a grid identical to the serial scanner — or return nil
/// (forcing the serial fallback) whenever speculation would be unsound.
///
/// Reference: `parseFieldGridSerial` on the same bytes. Grids compare by
/// `fields` (every cell's byte range and escape flag), `rowCount`, and
/// `colCount`.
final class CSVGridParallelTests: XCTestCase {

    private let reader = CSVReader()

    /// Runs both scanners over the text with a tiny gate so small inputs
    /// still exercise the chunked path, and compares grids. Returns
    /// whether the parallel scan produced a result (vs. falling back).
    @discardableResult
    private func assertGridParity(_ text: String, label: String,
                                  expectParallel: Bool = true) -> Bool {
        var t = text
        return t.withUTF8 { buf -> Bool in
            let serial = reader.parseFieldGridSerial(buf)
            guard let parallel = reader.parseFieldGridParallel(buf, byteThreshold: 64) else {
                XCTAssertFalse(expectParallel,
                               "\(label): parallel scan fell back but was expected to run")
                return false
            }
            XCTAssertEqual(parallel.rowCount, serial.rowCount, "\(label): rowCount")
            XCTAssertEqual(parallel.colCount, serial.colCount, "\(label): colCount")
            XCTAssertEqual(Array(parallel.fields), Array(serial.fields), "\(label): fields")
            return true
        }
    }

    func testPlainGrid_parity() {
        var lines = ["a,b,c"]
        for i in 0..<500 { lines.append("\(i),x\(i),\(Double(i) / 4)") }
        assertGridParity(lines.joined(separator: "\n") + "\n", label: "plain")
    }

    func testQuotedFieldsAndEscapes_parity() {
        var lines = ["a,b"]
        for i in 0..<500 {
            lines.append("\"quoted,comma \(i)\",\"say \"\"hi\"\" \(i)\"")
        }
        assertGridParity(lines.joined(separator: "\n") + "\n", label: "quoted")
    }

    func testCRLFAndRaggedRows_parity() {
        var lines = ["a,b,c"]
        for i in 0..<500 {
            lines.append(i % 5 == 0 ? "only\(i)" : "\(i),x,y")  // ragged short rows pad
        }
        assertGridParity(lines.joined(separator: "\r\n") + "\r\n", label: "crlf+ragged")
    }

    func testNoTrailingNewline_parity() {
        var lines = ["a,b"]
        for i in 0..<300 { lines.append("\(i),v") }
        assertGridParity(lines.joined(separator: "\n"), label: "no trailing NL")
    }

    func testQuotedNewline_fallsBackToSerial() {
        var lines = ["a,b"]
        for i in 0..<300 { lines.append("\(i),plain") }
        lines.append("\"line\nbreak\",tail")
        for i in 0..<300 { lines.append("\(i),plain") }
        let text = lines.joined(separator: "\n") + "\n"
        assertGridParity(text, label: "quoted newline", expectParallel: false)

        // End-to-end: the full read must still parse it correctly.
        let df = DataFrame.readCSV(text)
        XCTAssertEqual(df.rowCount, 601)
        guard case .string(let col) = df.columns["a"]! else { return XCTFail("dtype") }
        XCTAssertTrue((0..<col.count).contains { col[$0] == "line\nbreak" },
                      "quoted-newline cell lost in fallback path")
    }

    func testOverflowRow_fallsBackToSerial() {
        var lines = ["a,b"]
        for i in 0..<300 { lines.append("\(i),v") }
        lines.append("1,2,3,4,5")  // more fields than the header row
        for i in 0..<300 { lines.append("\(i),v") }
        assertGridParity(lines.joined(separator: "\n") + "\n",
                         label: "overflow row", expectParallel: false)
    }

    func testUnterminatedQuote_fallsBackToSerial() {
        var lines = ["a,b"]
        for i in 0..<300 { lines.append("\(i),v") }
        let text = lines.joined(separator: "\n") + "\n\"dangling,open\n"
        assertGridParity(text, label: "unterminated quote", expectParallel: false)
    }

    func testFuzz_gridParity() {
        struct LCG {
            var state: UInt64
            mutating func next() -> UInt64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return state
            }
            mutating func below(_ n: Int) -> Int { Int((next() >> 33) % UInt64(n)) }
        }
        // Parity-safe pool (no quoted newlines — those fall back, covered above).
        let pool = ["", "x", "42", "3.5", "\"a,b\"", "\"q\"\"z\"", "héllo", "NA",
                    "longer value here", "\"  padded  \""]
        var rng = LCG(state: 0x6121D)
        for iteration in 0..<30 {
            let rows = 20 + rng.below(400)
            let cols = 1 + rng.below(6)
            var lines = [(0..<cols).map { "c\($0)" }.joined(separator: ",")]
            for r in 0..<rows {
                var fields = [String]()
                // Occasionally emit short (ragged) rows.
                let width = r % 17 == 0 ? 1 + rng.below(cols) : cols
                for _ in 0..<width { fields.append(pool[rng.below(pool.count)]) }
                lines.append(fields.joined(separator: ","))
            }
            let sep = iteration % 4 == 0 ? "\r\n" : "\n"
            let trailing = iteration % 3 == 0 ? "" : sep
            assertGridParity(lines.joined(separator: sep) + trailing,
                             label: "fuzz #\(iteration)")
        }
    }
}
