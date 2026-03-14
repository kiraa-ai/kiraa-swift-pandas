import Testing
import Foundation
@testable import SwiftPandas

@Suite struct NewFeaturesTests {

    // MARK: - Series Bool Initializers

    @Test func testSeriesBoolInit() {
        let s = Series([true, false, true], name: "flags")
        #expect(s.name == "flags")
        #expect(s.count == 3)
    }

    @Test func testSeriesOptionalBoolInit() {
        let s = Series([true, nil, false] as [Bool?], name: "flags")
        #expect(s.count == 3)
    }

    @Test func testSeriesOptionalIntInit() {
        let s = Series([1, nil, 3] as [Int?], name: "ids")
        #expect(s.count == 3)
    }

    // MARK: - Series Equatable

    @Test func testSeriesEquatable() {
        let a = Series([1.0, 2.0, 3.0], name: "x")
        let b = Series([1.0, 2.0, 3.0], name: "x")
        let c = Series([1.0, 2.0, 4.0], name: "x")
        let d = Series([1.0, 2.0, 3.0], name: "y")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    // MARK: - Series Sequence

    @Test func testSeriesSequence() {
        let s = Series([10.0, 20.0, 30.0])
        var values = [Double]()
        for val in s {
            if let v = val as? Double {
                values.append(v)
            }
        }
        #expect(values == [10.0, 20.0, 30.0])
    }

    // MARK: - Column Equatable

    @Test func testColumnEquatable() {
        let a = Column.fromDoubles([1.0, 2.0])
        let b = Column.fromDoubles([1.0, 2.0])
        let c = Column.fromDoubles([1.0, 3.0])
        #expect(a == b)
        #expect(a != c)
    }

    @Test func testColumnEqualableDifferentTypes() {
        let d = Column.fromDoubles([1.0])
        let s = Column.fromStrings(["hello"])
        #expect(d != s)
    }

    // MARK: - DataFrame Equatable

    @Test func testDataFrameEquatable() {
        let a = DataFrame(["x": [1.0, 2.0], "y": [3.0, 4.0]])
        let b = DataFrame(["x": [1.0, 2.0], "y": [3.0, 4.0]])
        let c = DataFrame(["x": [1.0, 2.0], "y": [3.0, 5.0]])
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - DataFrame Sequence

    @Test func testDataFrameSequence() {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        var rows = [[String: Any?]]()
        for row in df {
            rows.append(row)
        }
        #expect(rows.count == 2)
        #expect(rows[0]["a"] as? Double == 1.0)
        #expect(rows[0]["b"] as? Double == 3.0)
        #expect(rows[1]["a"] as? Double == 2.0)
    }

    // MARK: - DataFrame Convenience Initializers

    @Test func testDataFrameFromColumnDict() {
        let df = DataFrame(["x": Column.fromDoubles([1.0, 2.0]),
                            "y": Column.fromStrings(["a", "b"])])
        #expect(df.rowCount == 2)
        #expect(df.columnCount == 2)
    }

    @Test func testDataFrameFromStringDict() {
        let df = DataFrame(["name": ["Alice", "Bob"], "city": ["NYC", "LA"]])
        #expect(df.rowCount == 2)
        #expect(df.columnCount == 2)
    }

    @Test func testDataFrameFromIntDict() {
        let df = DataFrame(["x": [1, 2, 3], "y": [4, 5, 6]])
        #expect(df.rowCount == 3)
        #expect(df.columnCount == 2)
    }

    // MARK: - DataFrame Throwing API

    @Test func testColumnThrowsOnMissing() throws {
        let df = DataFrame(["x": [1.0, 2.0]])
        #expect(throws: (any Error).self) {
            try df.column("missing")
        }
        do {
            _ = try df.column("missing")
            Issue.record("Expected DataFrameError")
        } catch {
            guard let dfErr = error as? DataFrameError else {
                Issue.record("Expected DataFrameError"); return
            }
            if case .columnNotFound(let name) = dfErr {
                #expect(name == "missing")
            } else {
                Issue.record("Expected columnNotFound")
            }
        }
    }

    @Test func testColumnReturnsSeriesOnSuccess() throws {
        let df = DataFrame(["x": [1.0, 2.0]])
        let s = try df.column("x")
        #expect(s.name == "x")
        #expect(s.count == 2)
    }

    // MARK: - DataFrameError

    @Test func testDataFrameErrorDescriptions() {
        let e1 = DataFrameError.columnNotFound("foo")
        #expect(e1.description.contains("foo"))

        let e2 = DataFrameError.typeMismatch(expected: "Double", got: "String")
        #expect(e2.description.contains("Double"))

        let e3 = DataFrameError.lengthMismatch(expected: 10, got: 5)
        #expect(e3.description.contains("10"))

        let e4 = DataFrameError.indexOutOfRange(position: 5, count: 3)
        #expect(e4.description.contains("5"))

        let e5 = DataFrameError.keyColumnNotFound("key")
        #expect(e5.description.contains("key"))

        let e6 = DataFrameError.invalidJSON("bad")
        #expect(e6.description.contains("bad"))
    }

    // MARK: - JSON I/O

    @Test func testJSONReadWrite() throws {
        let json = """
        [
            {"name": "Alice", "age": 30},
            {"name": "Bob", "age": 25}
        ]
        """
        let df = try DataFrame.readJSON(json)
        #expect(df.rowCount == 2)
        #expect(df.columnNames.contains("name"))
        #expect(df.columnNames.contains("age"))

        let output = df.toJSON()
        #expect(output.contains("Alice"))
        #expect(output.contains("Bob"))
    }

    @Test func testJSONRoundTrip() throws {
        let original = DataFrame(["x": [1.0, 2.0, 3.0]])
        let json = original.toJSON()
        let restored = try DataFrame.readJSON(json)
        #expect(restored.rowCount == 3)
    }

    @Test func testJSONEmptyArray() throws {
        let df = try DataFrame.readJSON("[]")
        #expect(df.rowCount == 0)
    }

    @Test func testJSONInvalidThrows() {
        #expect(throws: (any Error).self) {
            try DataFrame.readJSON("not json")
        }
    }

    @Test func testJSONNotArrayThrows() {
        #expect(throws: (any Error).self) {
            try DataFrame.readJSON("{\"key\": \"value\"}")
        }
    }

    // MARK: - URL-based CSV I/O

    @Test func testCSVUrlRoundTrip() throws {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try df.toCSV(url: tmpURL)
        let loaded = try DataFrame.readCSV(url: tmpURL)
        #expect(loaded.rowCount == 2)
        #expect(loaded.columnCount == 2)
    }
}
