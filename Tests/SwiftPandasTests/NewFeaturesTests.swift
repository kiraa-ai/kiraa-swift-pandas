import XCTest
@testable import SwiftPandas

final class NewFeaturesTests: XCTestCase {

    // MARK: - Series Bool Initializers

    func testSeriesBoolInit() {
        let s = Series([true, false, true], name: "flags")
        XCTAssertEqual(s.name, "flags")
        XCTAssertEqual(s.count, 3)
    }

    func testSeriesOptionalBoolInit() {
        let s = Series([true, nil, false] as [Bool?], name: "flags")
        XCTAssertEqual(s.count, 3)
    }

    func testSeriesOptionalIntInit() {
        let s = Series([1, nil, 3] as [Int?], name: "ids")
        XCTAssertEqual(s.count, 3)
    }

    // MARK: - Series Equatable

    func testSeriesEquatable() {
        let a = Series([1.0, 2.0, 3.0], name: "x")
        let b = Series([1.0, 2.0, 3.0], name: "x")
        let c = Series([1.0, 2.0, 4.0], name: "x")
        let d = Series([1.0, 2.0, 3.0], name: "y")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(a, d)
    }

    // MARK: - Series Sequence

    func testSeriesSequence() {
        let s = Series([10.0, 20.0, 30.0])
        var values = [Double]()
        for val in s {
            if let v = val as? Double {
                values.append(v)
            }
        }
        XCTAssertEqual(values, [10.0, 20.0, 30.0])
    }

    // MARK: - Column Equatable

    func testColumnEquatable() {
        let a = Column.fromDoubles([1.0, 2.0])
        let b = Column.fromDoubles([1.0, 2.0])
        let c = Column.fromDoubles([1.0, 3.0])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testColumnEqualableDifferentTypes() {
        let d = Column.fromDoubles([1.0])
        let s = Column.fromStrings(["hello"])
        XCTAssertNotEqual(d, s)
    }

    // MARK: - DataFrame Equatable

    func testDataFrameEquatable() {
        let a = DataFrame(["x": [1.0, 2.0], "y": [3.0, 4.0]])
        let b = DataFrame(["x": [1.0, 2.0], "y": [3.0, 4.0]])
        let c = DataFrame(["x": [1.0, 2.0], "y": [3.0, 5.0]])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - DataFrame Sequence

    func testDataFrameSequence() {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        var rows = [[String: Any?]]()
        for row in df {
            rows.append(row)
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["a"] as? Double, 1.0)
        XCTAssertEqual(rows[0]["b"] as? Double, 3.0)
        XCTAssertEqual(rows[1]["a"] as? Double, 2.0)
    }

    // MARK: - DataFrame Convenience Initializers

    func testDataFrameFromColumnDict() {
        let df = DataFrame(["x": Column.fromDoubles([1.0, 2.0]),
                            "y": Column.fromStrings(["a", "b"])])
        XCTAssertEqual(df.rowCount, 2)
        XCTAssertEqual(df.columnCount, 2)
    }

    func testDataFrameFromStringDict() {
        let df = DataFrame(["name": ["Alice", "Bob"], "city": ["NYC", "LA"]])
        XCTAssertEqual(df.rowCount, 2)
        XCTAssertEqual(df.columnCount, 2)
    }

    func testDataFrameFromIntDict() {
        let df = DataFrame(["x": [1, 2, 3], "y": [4, 5, 6]])
        XCTAssertEqual(df.rowCount, 3)
        XCTAssertEqual(df.columnCount, 2)
    }

    // MARK: - DataFrame Throwing API

    func testColumnThrowsOnMissing() {
        let df = DataFrame(["x": [1.0, 2.0]])
        XCTAssertThrowsError(try df.column("missing")) { error in
            guard let dfErr = error as? DataFrameError else {
                XCTFail("Expected DataFrameError"); return
            }
            if case .columnNotFound(let name) = dfErr {
                XCTAssertEqual(name, "missing")
            } else {
                XCTFail("Expected columnNotFound")
            }
        }
    }

    func testColumnReturnsSeriesOnSuccess() throws {
        let df = DataFrame(["x": [1.0, 2.0]])
        let s = try df.column("x")
        XCTAssertEqual(s.name, "x")
        XCTAssertEqual(s.count, 2)
    }

    // MARK: - DataFrameError

    func testDataFrameErrorDescriptions() {
        let e1 = DataFrameError.columnNotFound("foo")
        XCTAssertTrue(e1.description.contains("foo"))

        let e2 = DataFrameError.typeMismatch(expected: "Double", got: "String")
        XCTAssertTrue(e2.description.contains("Double"))

        let e3 = DataFrameError.lengthMismatch(expected: 10, got: 5)
        XCTAssertTrue(e3.description.contains("10"))

        let e4 = DataFrameError.indexOutOfRange(position: 5, count: 3)
        XCTAssertTrue(e4.description.contains("5"))

        let e5 = DataFrameError.keyColumnNotFound("key")
        XCTAssertTrue(e5.description.contains("key"))

        let e6 = DataFrameError.invalidJSON("bad")
        XCTAssertTrue(e6.description.contains("bad"))
    }

    // MARK: - JSON I/O

    func testJSONReadWrite() throws {
        let json = """
        [
            {"name": "Alice", "age": 30},
            {"name": "Bob", "age": 25}
        ]
        """
        let df = try DataFrame.readJSON(json)
        XCTAssertEqual(df.rowCount, 2)
        XCTAssertTrue(df.columnNames.contains("name"))
        XCTAssertTrue(df.columnNames.contains("age"))

        let output = df.toJSON()
        XCTAssertTrue(output.contains("Alice"))
        XCTAssertTrue(output.contains("Bob"))
    }

    func testJSONRoundTrip() throws {
        let original = DataFrame(["x": [1.0, 2.0, 3.0]])
        let json = original.toJSON()
        let restored = try DataFrame.readJSON(json)
        XCTAssertEqual(restored.rowCount, 3)
    }

    func testJSONEmptyArray() throws {
        let df = try DataFrame.readJSON("[]")
        XCTAssertEqual(df.rowCount, 0)
    }

    func testJSONInvalidThrows() {
        XCTAssertThrowsError(try DataFrame.readJSON("not json")) { error in
            XCTAssertTrue(error is DataFrameError)
        }
    }

    func testJSONNotArrayThrows() {
        XCTAssertThrowsError(try DataFrame.readJSON("{\"key\": \"value\"}")) { error in
            XCTAssertTrue(error is DataFrameError)
        }
    }

    // MARK: - URL-based CSV I/O

    func testCSVUrlRoundTrip() throws {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try df.toCSV(url: tmpURL)
        let loaded = try DataFrame.readCSV(url: tmpURL)
        XCTAssertEqual(loaded.rowCount, 2)
        XCTAssertEqual(loaded.columnCount, 2)
    }
}
