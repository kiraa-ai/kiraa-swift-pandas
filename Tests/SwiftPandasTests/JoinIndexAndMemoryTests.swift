import XCTest
@testable import SwiftPandas

// ===----------------------------------------------------------------------===//
// Tests for the join-index utilities (last-row-wins guarantee) and the
// estimatedBytes accuracy bound.
// ===----------------------------------------------------------------------===//

final class JoinIndexTests: XCTestCase {

    private let df = DataFrame(columns: [
        ("sku", .fromStrings(["A", "B", "A", "C"])),
        ("region", .fromStrings(["east", "west", "west", "east"])),
        ("desc", .fromStrings(["first-A", "only-B", "second-A", "only-C"])),
        ("qty", .fromDoubles([1, 2, 3, 4])),
    ])

    func test_index_lastRowWins() {
        let idx = df.index(on: "sku")
        XCTAssertEqual(idx["A"], 2, "duplicate key 'A' must resolve to its LAST row (byte-parity guarantee)")
        XCTAssertEqual(idx["B"], 1, "unique keys map to their row")
        XCTAssertEqual(idx["C"], 3, "unique keys map to their row")
        XCTAssertEqual(idx.count, 3, "duplicates collapse: 4 rows, 3 distinct keys")
    }

    func test_index_compositeKeys() {
        let idx = df.index(on: ["sku", "region"])
        XCTAssertEqual(idx["A|east"], 0, "composite key joins components with '|' by default")
        XCTAssertEqual(idx["A|west"], 2, "composite keys distinguish rows a single key cannot")
        let custom = df.index(on: ["sku", "region"], separator: "::")
        XCTAssertEqual(custom["A::west"], 2, "a custom separator must be honored")
    }

    func test_index_missingColumn_isEmpty() {
        XCTAssertTrue(df.index(on: "nope").isEmpty, "indexing a missing column must return an empty index")
        XCTAssertTrue(df.index(on: []).isEmpty, "an empty key-column list must return an empty index")
    }

    func test_index_missingColumnInComposite_contributesEmptyComponent() {
        let idx = df.index(on: ["sku", "nope"])
        XCTAssertEqual(idx["A|"], 2, "a missing column must contribute an empty component, keeping key arity stable")
    }

    func test_index_naKey_indexesUnderEmptyString() {
        let withNA = DataFrame(columns: [("k", .fromOptionalStrings(["x", nil, "y"]))])
        let idx = withNA.index(on: "k")
        XCTAssertEqual(idx[""], 1, "an NA key must index under the empty string, matching its CSV appearance")
    }

    func test_index_numericKeys_useCSVText() {
        let numeric = DataFrame(columns: [("id", .fromDoubles([42, 7.5]))])
        let idx = numeric.index(on: "id")
        XCTAssertEqual(idx["42"], 0, "integral doubles must key as their CSV text ('42', not '42.0')")
        XCTAssertEqual(idx["7.5"], 1, "fractional doubles keep their decimal text")
    }

    func test_lookupTable_lastRowWins() {
        let table = df.lookupTable(key: "sku", value: "desc")
        XCTAssertEqual(table["A"], "second-A", "duplicate keys must take the LAST row's value")
        XCTAssertEqual(table["B"], "only-B", "unique keys map to their value")
        XCTAssertEqual(table.count, 3, "table has one entry per distinct key")
    }

    func test_lookupTable_missingColumns_isEmpty() {
        XCTAssertTrue(df.lookupTable(key: "nope", value: "desc").isEmpty,
                      "a missing key column must yield an empty table")
        XCTAssertTrue(df.lookupTable(key: "sku", value: "nope").isEmpty,
                      "a missing value column must yield an empty table")
    }

    func test_lookupTable_numericValues_useCSVText() {
        let table = df.lookupTable(key: "sku", value: "qty")
        XCTAssertEqual(table["C"], "4", "numeric values must render as CSV text (no trailing .0)")
    }
}

final class EstimatedBytesTests: XCTestCase {

    /// Model constants documented on `StringArray.nbytes` /
    /// `DataFrame.estimatedBytes`. If the model changes, change these AND
    /// the doc comments together.
    private let slotBytes = MemoryLayout<String?>.stride  // 16 on 64-bit
    private let largeStringHeader = 32
    private let smallStringMax = 15

    private func assertWithin20Percent(_ actual: Int, of expected: Int,
                                       _ label: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let lower = Double(expected) * 0.8
        let upper = Double(expected) * 1.2
        XCTAssertTrue(Double(actual) >= lower && Double(actual) <= upper,
                      "\(label): estimatedBytes \(actual) must be within ±20% of the reference \(expected)",
                      file: file, line: line)
    }

    func test_doubleFrame_matchesBufferPlusBitmap() {
        let n = 10_000
        let df = DataFrame(["x": (0..<n).map(Double.init)])
        // 8 bytes per double + 1 bit per row of validity bitmap + name.
        let reference = n * 8 + (n + 63) / 64 * 8 + 1
        assertWithin20Percent(df.estimatedBytes, of: reference, "double frame")
    }

    func test_intFrame_matchesBufferPlusBitmap() {
        let n = 10_000
        let df = DataFrame(columns: [("x", .fromInts(Array(0..<n)))])
        let reference = n * 8 + (n + 63) / 64 * 8 + 1
        assertWithin20Percent(df.estimatedBytes, of: reference, "int64 frame")
    }

    func test_largeStringFrame_countsPayloadAndOverhead() {
        let n = 2_000
        let payload = 40 // > small-string capacity → heap allocated
        let value = String(repeating: "s", count: payload)
        let df = DataFrame(columns: [("s", .fromStrings(Array(repeating: value, count: n)))])
        let reference = n * (slotBytes + payload + largeStringHeader) + 1
        assertWithin20Percent(df.estimatedBytes, of: reference, "large-string frame")
    }

    func test_smallStringFrame_countsSlotsOnly() {
        let n = 2_000
        let value = "tiny" // ≤ 15 UTF-8 bytes → inline, no heap payload
        let df = DataFrame(columns: [("s", .fromStrings(Array(repeating: value, count: n)))])
        let reference = n * slotBytes + 1
        assertWithin20Percent(df.estimatedBytes, of: reference, "small-string frame")
    }

    func test_mixedFrame_sumsPerColumnModels() {
        let n = 1_000
        let long = String(repeating: "x", count: 64)
        let df = DataFrame(columns: [
            ("id", .fromStrings(Array(repeating: long, count: n))),
            ("v", .fromDoubles(Array(repeating: 1.5, count: n))),
        ])
        let stringRef = n * (slotBytes + 64 + largeStringHeader)
        let doubleRef = n * 8 + (n + 63) / 64 * 8
        assertWithin20Percent(df.estimatedBytes, of: stringRef + doubleRef + 3, "mixed frame")
    }

    func test_naStrings_stillCountTheirSlots() {
        let n = 1_000
        let df = DataFrame(columns: [("s", .fromOptionalStrings(Array(repeating: nil, count: n)))])
        XCTAssertGreaterThanOrEqual(df.estimatedBytes, n * slotBytes,
                                    "NA string cells still occupy their [String?] slots")
    }
}
