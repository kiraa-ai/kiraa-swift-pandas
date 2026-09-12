import XCTest
import Foundation
@testable import SwiftPandas

/// D5 acceptance: declared-schema `readCSV`.
///
/// * Columns named in the contract skip inference entirely — declared
///   `.string` beats inference (all-digit identifiers keep leading zeros).
/// * **Undeclared columns keep the historical inference byte-for-byte**
///   (they share `inferColumn` with the plain `.infer` path, so this is
///   structural, but the tests pin it observationally too).
/// * Declared-column parse failures become NA and are reported, same as
///   strict mode.
final class CSVDeclaredModeTests: XCTestCase {

    private let csv = """
    postcode,city,population,revenue,flagged
    0800,Darwin,147255,1.5,true
    0872,Alice Springs,25912,,false
    2000,Sydney,5312163,3.25,true
    """

    /// Renders one column as a single-column frame's CSV — a strict
    /// value+dtype comparison without needing Column: Equatable.
    private func render(_ df: DataFrame, _ name: String) -> String {
        DataFrame(columns: [(name, df.columns[name]!)]).toCSV()
    }

    func testDeclaredStringBeatsInference() {
        // Pin the defect first: plain inference numifies the postcodes.
        let inferred = DataFrame.readCSV(csv)
        guard case .double = inferred.columns["postcode"]! else {
            return XCTFail("premise broken: inference no longer numifies all-digit columns")
        }

        let df = CSVReader.declared(columnTypes: ["postcode": .string]).read(from: csv)
        guard case .string(let arr) = df.columns["postcode"]! else {
            return XCTFail("declared .string column did not stay string")
        }
        XCTAssertEqual(arr[0], "0800", "leading zero must survive")
        XCTAssertEqual(arr[1], "0872")
        XCTAssertEqual(arr[2], "2000")
    }

    func testUndeclaredColumnsMatchInferenceExactly() {
        let inferred = DataFrame.readCSV(csv)
        let declared = CSVReader.declared(columnTypes: ["postcode": .string]).read(from: csv)

        XCTAssertEqual(declared.columnNames, inferred.columnNames)
        for name in inferred.columnNames where name != "postcode" {
            XCTAssertEqual(render(declared, name), render(inferred, name),
                           "undeclared column '\(name)' diverged from plain inference")
            XCTAssertEqual(String(describing: declared.columns[name]!.dtype),
                           String(describing: inferred.columns[name]!.dtype),
                           "undeclared column '\(name)' changed dtype")
        }
        // Spot-check the semantics that comparison relies on: 'city' inferred
        // string, 'population' inferred numeric, 'revenue' numeric with NA.
        guard case .string = inferred.columns["city"]!,
              case .double = inferred.columns["population"]!,
              case .double(let rev) = inferred.columns["revenue"]! else {
            return XCTFail("inference premises changed")
        }
        XCTAssertNil(rev[1], "empty cell must stay NA")
    }

    func testDeclaredTypedColumnsAndFailureReport() {
        let messy = """
        id,score
        a1,10
        b2,not-a-number
        c3,30
        """
        let reader = CSVReader.declared(columnTypes: ["score": .int64])
        let (df, failures) = reader.readWithReport(from: messy)

        guard case .int64(let scores) = df.columns["score"]! else {
            return XCTFail("declared .int64 column has wrong dtype")
        }
        XCTAssertEqual(scores[0], 10)
        XCTAssertNil(scores[1], "failed cell must become NA")
        XCTAssertEqual(scores[2], 30)

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.column, "score")
        XCTAssertEqual(failures.first?.failedCount, 1)
        XCTAssertEqual(failures.first?.firstFailedRow, 1)
        XCTAssertEqual(failures.first?.firstFailedValue, "not-a-number")

        // 'id' is undeclared → inference → string (mixed alphanumerics).
        guard case .string = df.columns["id"]! else {
            return XCTFail("undeclared column should have inferred string")
        }
    }

    func testReadCSVPathWithDtypes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("declared-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try csv.write(to: url, atomically: true, encoding: .utf8)

        let df = try DataFrame.readCSV(path: url.path,
                                       dtypes: ["postcode": .string])
        guard case .string(let arr) = df.columns["postcode"]! else {
            return XCTFail("dtypes contract not applied through readCSV(path:dtypes:)")
        }
        XCTAssertEqual(arr[0], "0800")

        // nil/empty dtypes == plain inference.
        let plain = try DataFrame.readCSV(path: url.path, dtypes: nil)
        XCTAssertEqual(plain.toCSV(), DataFrame.readCSV(csv).toCSV())
    }

    func testZeroRowAndHeaderOnly() {
        let headerOnly = "postcode,city\n"
        let df = CSVReader.declared(columnTypes: ["postcode": .string]).read(from: headerOnly)
        XCTAssertEqual(df.columnNames, ["postcode", "city"])
        XCTAssertEqual(df.rowCount, 0)
    }
}
