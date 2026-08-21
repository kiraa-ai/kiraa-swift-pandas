import XCTest
@testable import SwiftPandas

/// Acceptance tests for issue #18: `BitVector.allValid` must never disagree
/// with the bits. Written RED against v0.8.0-beta (the `&` / `~` operators
/// leave the `_knownAllValid` latch stale) before any production change.
///
/// Every test here names the production change that makes it fail: a cached
/// all-valid answer that is not re-derived from `words`.
final class BitVectorInvariantTests: XCTestCase {

    // MARK: - Unit: the latch

    func test_and_withAllValidLhs_reportsNotAllValid() {
        var hasNA = BitVector(repeating: true, count: 4)
        hasNA[1] = false

        let anded = BitVector(repeating: true, count: 4) & hasNA

        XCTAssertFalse(anded[1])
        XCTAssertEqual(anded.popcount, 3)
        XCTAssertFalse(anded.allValid)
    }

    func test_and_multiWordUnalignedTail_reportsNotAllValid() {
        // 130 bits = 2 full words + a 2-bit tail; clear a bit in each region.
        var hasNA = BitVector(repeating: true, count: 130)
        hasNA[0] = false
        hasNA[70] = false
        hasNA[129] = false

        let anded = BitVector(repeating: true, count: 130) & hasNA

        XCTAssertEqual(anded.popcount, 127)
        XCTAssertFalse(anded.allValid)
    }

    func test_not_ofAllValid_reportsNotAllValid() {
        let inverted = ~BitVector(repeating: true, count: 4)

        XCTAssertEqual(inverted.popcount, 0)
        XCTAssertFalse(inverted.allValid)
        XCTAssertTrue(inverted.allNA)
    }

    func test_or_withAllValidLhs_staysAllValid() {
        // Pins the currently-correct `|` semantics so the fix cannot regress it.
        var hasNA = BitVector(repeating: true, count: 4)
        hasNA[1] = false

        let ored = BitVector(repeating: true, count: 4) | hasNA

        XCTAssertEqual(ored.popcount, 4)
        XCTAssertTrue(ored.allValid)
    }

    func test_concat_ofAllValidAndMaskWithNA_reportsNotAllValid() {
        var hasNA = BitVector(repeating: true, count: 3)
        hasNA[0] = false
        // Route the NA through `&` so the input carries the stale latch.
        let stale = BitVector(repeating: true, count: 3) & hasNA

        let joined = BitVector.concat([BitVector(repeating: true, count: 5), stale])

        XCTAssertEqual(joined.bitCount, 8)
        XCTAssertEqual(joined.popcount, 7)
        XCTAssertFalse(joined[5])
        XCTAssertFalse(joined.allValid)
    }

    func test_equatable_ignoresHowTheMaskWasBuilt() {
        // Same bits, different construction path → must be equal.
        XCTAssertEqual(BitVector(repeating: true, count: 4),
                       BitVector([true, true, true, true]))
    }

    // MARK: - End to end: operator-derived NA survives bulk operations

    private func frameWithDerivedNA() -> DataFrame {
        var df = DataFrame()
        df["a"] = Series([13.0, 14.0, 20.0, 21.0], name: "a")
        df["b"] = Series([0.5, nil, 0.2, 0.3], name: "b")
        df["t"] = df["a"] + df["b"]
        return df
    }

    private func doubles(_ s: Series) -> [Double?] {
        (0..<s.count).map { s[$0] as? Double }
    }

    func test_derivedNA_isVisibleElementwise() {
        // Control: the element path is correct today and must stay so.
        let df = frameWithDerivedNA()
        XCTAssertEqual(doubles(df["t"]), [13.5, nil, 20.2, 21.3])
    }

    func test_derivedNA_survivesSort() {
        let sorted = frameWithDerivedNA().sortValues(by: ["a"])
        XCTAssertEqual(doubles(sorted["t"]), [13.5, nil, 20.2, 21.3])
    }

    func test_derivedNA_survivesBooleanFilter() {
        let df = frameWithDerivedNA()
        let filtered = df[df["a"] > 13.0]
        XCTAssertEqual(doubles(filtered["t"]), [nil, 20.2, 21.3])
    }

    func test_derivedNA_isExcludedFromGroupByMean() {
        let g = frameWithDerivedNA().groupBy("a").mean()
        // Key 14.0 has a single row whose "t" is NA → the group mean is NA.
        // Group keys become the result's index labels.
        let keys = g.indexLabels
        guard let row = keys.firstIndex(where: { Double($0) == 14.0 }) else {
            return XCTFail("groupBy result has no key 14.0: \(keys)")
        }
        XCTAssertNil(doubles(g["t"])[row])
    }

    func test_derivedNA_rendersAsEmptyCellInCSV() {
        let csv = frameWithDerivedNA().toCSV()
        let rows = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[0], "a,b,t")
        XCTAssertEqual(rows[2], "14,,")
    }

    func test_derivedNA_roundTripsThroughSPB() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitvector-invariant-\(UUID().uuidString).spb")
        defer { try? FileManager.default.removeItem(at: url) }

        try frameWithDerivedNA().writeSPB(to: url)
        let back = try DataFrame.readSPB(from: url)

        XCTAssertEqual(doubles(back["t"]), [13.5, nil, 20.2, 21.3])
    }

    func test_derivedNA_survivesSort_forAllArithmeticOperators() {
        var df = frameWithDerivedNA()
        df["m"] = df["a"] - df["b"]
        df["x"] = df["a"] * df["b"]
        df["d"] = df["a"] / df["b"]

        let sorted = df.sortValues(by: ["a"], ascending: [false])

        XCTAssertNil(doubles(sorted["m"])[2], "subtraction-derived NA erased")
        XCTAssertNil(doubles(sorted["x"])[2], "multiplication-derived NA erased")
        XCTAssertNil(doubles(sorted["d"])[2], "division-derived NA erased")
    }
}
