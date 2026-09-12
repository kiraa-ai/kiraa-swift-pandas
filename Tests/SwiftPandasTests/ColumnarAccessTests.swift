import XCTest
@testable import SwiftPandas

/// D3 acceptance: zero-copy columnar access in both directions.
///
/// * Borrow out: `withUnsafe*Buffer` exposes contiguous values plus the
///   packed validity bitmap (nil when all-valid), bit-identical to the
///   column's NA state.
/// * Move in: `Column(taking…)` inits build columns from prebuilt arrays;
///   a borrow → rebuild round-trip must preserve values, dtypes, and null
///   positions exactly — including all-digit strings staying strings.
final class ColumnarAccessTests: XCTestCase {

    // MARK: - Borrowing numerics

    func testDoubleBuffer_valuesAndValidity() throws {
        let df = DataFrame(columns: [
            ("x", Column(takingDoubles: [1.5, 0, -3.25, 0],
                         validity: [true, false, true, false])),
        ])
        try df.withUnsafeDoubleBuffer("x") { values, validity in
            XCTAssertEqual(values.count, 4)
            XCTAssertEqual(values[0], 1.5)
            XCTAssertEqual(values[2], -3.25)
            let v = try XCTUnwrap(validity)
            XCTAssertEqual(v.count, 4)
            XCTAssertEqual(v.boolArray, [true, false, true, false])
            XCTAssertTrue(v[0]); XCTAssertFalse(v[1])
            XCTAssertTrue(v[2]); XCTAssertFalse(v[3])
        }
    }

    func testAllValidColumn_yieldsNilValidity() throws {
        let df = DataFrame(columns: [
            ("x", Column(takingDoubles: [1, 2, 3])),
        ])
        try df.withUnsafeDoubleBuffer("x") { values, validity in
            XCTAssertEqual(Array(values), [1, 2, 3])
            XCTAssertNil(validity, "all-valid columns must omit the bitmap (Arrow convention)")
        }
    }

    func testInt64AndBoolBuffers() throws {
        let df = DataFrame(columns: [
            ("i", Column(takingInt64s: [Int64.min, 0, Int64.max],
                         validity: [true, false, true])),
            ("b", Column(takingBools: [true, false, true])),
        ])
        try df.withUnsafeInt64Buffer("i") { values, validity in
            XCTAssertEqual(values[0], Int64.min)
            XCTAssertEqual(values[2], Int64.max)
            XCTAssertEqual(try XCTUnwrap(validity).boolArray, [true, false, true])
        }
        try df.withUnsafeBoolBuffer("b") { values, validity in
            XCTAssertEqual(Array(values), [true, false, true])
            XCTAssertNil(validity)
        }
    }

    func testStringColumnView() throws {
        let source: [String?] = ["0800", nil, "plain", ""]
        let df = DataFrame(columns: [("s", Column(takingStrings: source))])
        try df.withStringColumn("s") { values in
            XCTAssertEqual(values, source)
        }
    }

    // MARK: - Validity bitmap semantics

    /// The packed words must decode to exactly the column's NA state, and
    /// bit positions must follow the LSB-first convention.
    func testValidityView_matchesIsNA_acrossWordBoundaries() throws {
        // 130 rows spans three words; make validity irregular.
        let n = 130
        var validity = [Bool](); var values = [Double]()
        for i in 0..<n {
            validity.append(i % 3 != 0 && i != 64 && i != 127)
            values.append(Double(i))
        }
        let df = DataFrame(columns: [("x", Column(takingDoubles: values, validity: validity))])
        try df.withUnsafeDoubleBuffer("x") { _, v in
            let view = try XCTUnwrap(v)
            XCTAssertEqual(view.words.count, (n + 63) / 64)
            XCTAssertEqual(view.boolArray, validity)
            for i in 0..<n {
                XCTAssertEqual((view.words[i / 64] >> UInt64(i % 64)) & 1 == 1, validity[i],
                               "LSB-first decode mismatch at row \(i)")
            }
        }
    }

    // MARK: - Errors

    func testErrors_missingColumnAndTypeMismatch() {
        let df = DataFrame(columns: [("s", Column(takingStrings: ["a"]))])
        XCTAssertThrowsError(try df.withUnsafeDoubleBuffer("nope") { _, _ in }) { error in
            guard case DataFrameError.columnNotFound("nope") = error else {
                return XCTFail("expected columnNotFound, got \(error)")
            }
        }
        XCTAssertThrowsError(try df.withUnsafeDoubleBuffer("s") { _, _ in }) { error in
            guard case DataFrameError.typeMismatch = error else {
                return XCTFail("expected typeMismatch, got \(error)")
            }
        }
        XCTAssertThrowsError(try df.withStringColumn("nope") { _ in }) { error in
            guard case DataFrameError.columnNotFound = error else {
                return XCTFail("expected columnNotFound, got \(error)")
            }
        }
    }

    // MARK: - Taking inits

    func testTakingInits_matchElementwiseConstruction() {
        let viaTaking = Column(takingDoubles: [1.0, 0, 3.0], validity: [true, false, true])
        let viaOptionals = Column.double(NullableArray<Double>([1.0, nil, 3.0]))
        guard case .double(let a) = viaTaking, case .double(let b) = viaOptionals else {
            return XCTFail("dtype mismatch")
        }
        XCTAssertEqual(a.count, b.count)
        for i in 0..<a.count {
            XCTAssertEqual(a[i], b[i], "row \(i)")
        }
    }

    /// The defect class D3 exists to kill: all-digit identifiers built as
    /// strings must stay strings with leading zeros intact.
    func testTakingInits_allDigitStringsSurvive() throws {
        let postcodes: [String?] = ["0800", "0872", "2000", nil]
        let df = DataFrame(columns: [("postcode", Column(takingStrings: postcodes))])
        guard case .string = df.columns["postcode"]! else {
            return XCTFail("string column changed dtype")
        }
        try df.withStringColumn("postcode") { values in
            XCTAssertEqual(values, postcodes)
        }
    }

    // MARK: - Round-trip (borrow → rebuild)

    /// Acceptance: a frame reassembled from borrowed buffers via the taking
    /// inits preserves values, dtypes, and null positions exactly.
    func testRoundTrip_borrowRebuildPreservesEverything() throws {
        let original = DataFrame(columns: [
            ("d", Column(takingDoubles: [1.5, 0, -0.0, 9e99],
                         validity: [true, false, true, true])),
            ("i", Column(takingInt64s: [7, 0, -7, Int64.max],
                         validity: [true, false, true, true])),
            ("s", Column(takingStrings: ["0800", nil, "x,y", ""])),
            ("b", Column(takingBools: [true, false, false, true],
                         validity: [true, true, false, true])),
        ])

        var rebuiltCols = [(String, Column)]()
        try original.withUnsafeDoubleBuffer("d") { values, validity in
            rebuiltCols.append(("d", Column(takingDoubles: Array(values),
                                            validity: validity?.boolArray)))
        }
        try original.withUnsafeInt64Buffer("i") { values, validity in
            rebuiltCols.append(("i", Column(takingInt64s: Array(values),
                                            validity: validity?.boolArray)))
        }
        try original.withStringColumn("s") { values in
            rebuiltCols.append(("s", Column(takingStrings: values)))
        }
        try original.withUnsafeBoolBuffer("b") { values, validity in
            rebuiltCols.append(("b", Column(takingBools: Array(values),
                                            validity: validity?.boolArray)))
        }
        let rebuilt = DataFrame(columns: rebuiltCols)

        XCTAssertEqual(rebuilt.columnNames, original.columnNames)
        XCTAssertEqual(rebuilt.rowCount, original.rowCount)
        // Byte-exact CSV emission doubles as a strict whole-frame equality
        // check across values, dtypes (via formatting), and NA positions.
        XCTAssertEqual(rebuilt.toCSV(), original.toCSV())

        guard case .string = rebuilt.columns["s"]! else {
            return XCTFail("string column changed dtype in round-trip")
        }
    }
}
