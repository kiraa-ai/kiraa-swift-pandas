import XCTest
import Foundation
@testable import SwiftPandas

/// D4 (stage 1) acceptance: column-parallel CSV parsing produces frames
/// identical to serial parsing — values, dtypes, NA placement, column
/// order, and failure reports.
///
/// Reference: a column's parse result depends only on its own column's bytes,
/// so parsing each column as its own single-column CSV (small → serial
/// path) gives the serial reference for the full-width parse (large →
/// parallel path). The gate itself is also pinned so the test knows it
/// actually exercised the parallel branch.
final class CSVColumnParallelTests: XCTestCase {

    /// Deterministic LCG — reproducible run-to-run.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        // Use high bits: an LCG's low bits cycle with tiny periods (bit k
        // has period 2^(k+1)), which correlates with power-of-two pool
        // sizes and per-row column strides.
        mutating func below(_ n: Int) -> Int { Int((next() >> 33) % UInt64(n)) }
    }

    private let cellPool = [
        "42", "-7", "3.25", "0800", "plain", "", "NA", "1e3",
        "\"a,b\"", "\"q\"\"x\"", "true", "0.0", "999999999999",
    ]

    /// Builds a rows×cols CSV where every column gets its own value mix.
    private func makeCSV(rows: Int, cols: Int, rng: inout LCG) -> (text: String, names: [String]) {
        let names = (0..<cols).map { "c\($0)" }
        var lines = [names.joined(separator: ",")]
        lines.reserveCapacity(rows + 1)
        // Give columns distinct "personalities" so some infer numeric and
        // some string: even columns draw from the full pool, odd columns
        // from the numeric prefix.
        for _ in 0..<rows {
            var fields = [String]()
            for c in 0..<cols {
                let pool = c % 2 == 0 ? cellPool : Array(cellPool.prefix(4))
                fields.append(pool[rng.below(pool.count)])
            }
            lines.append(fields.joined(separator: ","))
        }
        return (lines.joined(separator: "\n") + "\n", names)
    }

    /// Splits the CSV into per-column single-column CSVs (serial path) and
    /// checks each against the corresponding column of the full parse.
    private func assertMatchesPerColumnSerialParse(
        _ full: DataFrame, rows: [[String]], names: [String],
        parse: (String) -> DataFrame, label: String
    ) {
        for (c, name) in names.enumerated() {
            let colCSV = ([name] + rows.map { $0[c] }).joined(separator: "\n") + "\n"
            let serial = parse(colCSV)
            let fullCol = DataFrame(columns: [(name, full.columns[name]!)]).toCSV()
            let serialCol = serial.toCSV()
            XCTAssertEqual(fullCol, serialCol,
                           "\(label): column '\(name)' diverged between parallel and serial parse")
        }
    }

    func testGate_largeFrameTriggersParallel_smallDoesNot() {
        XCTAssertTrue(CSVReader.shouldParallelizeColumns(rows: 40_000, cols: 8),
                      "40k×8 must take the parallel branch for the comparison below to mean anything")
        XCTAssertFalse(CSVReader.shouldParallelizeColumns(rows: 40_000, cols: 1))
        XCTAssertFalse(CSVReader.shouldParallelizeColumns(rows: 100, cols: 8))
    }

    func testInferParity_parallelVsSerial() {
        var rng = LCG(state: 0xD4)
        let rows = 40_000, cols = 8
        let names = (0..<cols).map { "c\($0)" }
        var rowFields = [[String]]()
        rowFields.reserveCapacity(rows)
        for _ in 0..<rows {
            var fields = [String]()
            for c in 0..<cols {
                let pool = c % 2 == 0 ? cellPool : Array(cellPool.prefix(4))
                fields.append(pool[rng.below(pool.count)])
            }
            rowFields.append(fields)
        }
        let text = ([names.joined(separator: ",")] +
                    rowFields.map { $0.joined(separator: ",") }).joined(separator: "\n") + "\n"

        let full = DataFrame.readCSV(text)   // 320k cells → parallel branch
        XCTAssertEqual(full.rowCount, rows)
        assertMatchesPerColumnSerialParse(full, rows: rowFields, names: names,
                                          parse: { DataFrame.readCSV($0) },
                                          label: "infer")
    }

    func testDeclaredParity_parallelVsSerial_withFailures() {
        var rng = LCG(state: 0xD5)
        let (text, names) = makeCSV(rows: 40_000, cols: 8, rng: &rng)
        let contract: [String: DTypeEnum] = ["c0": .string, "c1": .float64, "c3": .int64]
        let reader = CSVReader.declared(columnTypes: contract)

        let (full, failures) = reader.readWithReport(from: text)
        XCTAssertEqual(full.rowCount, 40_000)
        // c3 draws "3.25"/"0800"-style cells; int64 failures must be reported.
        XCTAssertTrue(failures.contains { $0.column == "c3" },
                      "expected int64 parse failures on c3 to survive the parallel path")

        // Per-column serial reference, including the failure report.
        var rowFields = [[String]]()
        text.split(separator: "\n").dropFirst().forEach { line in
            rowFields.append(Self.splitTopLevel(String(line)))
        }
        for (c, name) in names.enumerated() {
            let colCSV = ([name] + rowFields.map { $0[c] }).joined(separator: "\n") + "\n"
            let colReader = contract[name] != nil
                ? CSVReader.declared(columnTypes: [name: contract[name]!])
                : CSVReader()
            let (serial, serialFailures) = colReader.readWithReport(from: colCSV)
            XCTAssertEqual(DataFrame(columns: [(name, full.columns[name]!)]).toCSV(),
                           serial.toCSV(),
                           "declared: column '\(name)' diverged")
            let fullFailure = failures.first { $0.column == name }
            XCTAssertEqual(fullFailure, serialFailures.first,
                           "declared: failure report for '\(name)' diverged")
        }
    }

    /// Naive top-level CSV field splitter for rebuilding per-column inputs
    /// (handles the quoted pool values this suite generates).
    private static func splitTopLevel(_ line: String) -> [String] {
        var fields = [String](), current = "", inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle(); current.append(ch) }
            else if ch == "," && !inQuotes { fields.append(current); current = "" }
            else { current.append(ch) }
        }
        fields.append(current)
        return fields
    }
}
