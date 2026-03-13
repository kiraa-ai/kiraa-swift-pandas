import XCTest
import SwiftPandas
@testable import SwiftPandasCLI

final class IntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    private func runPipeline(input: String = "sales.csv",
                             chain: String,
                             sep: String = ",") throws -> DataFrame {
        let inputURL = fixtureURL(input)
        let df = try DataFrame.readCSV(url: inputURL, separator: sep.first ?? ",")
        let operations = try DSLParser.parse(chain)
        return try TransformRunner(operations: operations, verbose: false).run(on: df)
    }

    private func runJSONPipeline(input: String = "sales.csv",
                                 jsonFile: String) throws -> DataFrame {
        let inputURL = fixtureURL(input)
        let jsonURL = fixtureURL(jsonFile)
        let df = try DataFrame.readCSV(url: inputURL)
        let jsonContents = try String(contentsOf: jsonURL, encoding: .utf8)
        let operations = try JSONTransformParser.parse(from: jsonContents)
        return try TransformRunner(operations: operations, verbose: false).run(on: df)
    }

    // MARK: - Full Pipeline (from spec)

    func test_fullPipeline_inline() throws {
        let result = try runPipeline(chain: """
            filter(status == "active")                       |
            filter(revenue > 10000)                         |
            groupby(region, quarter)                        |
            agg(sum:revenue, mean:margin, count:transactions) |
            sort(revenue, desc)                             |
            rename(revenue -> total_revenue)                |
            rename(margin -> avg_margin)                    |
            round(avg_margin, 3)
        """)

        XCTAssertTrue(result.columnNames.contains("total_revenue"))
        XCTAssertFalse(result.columnNames.contains("revenue"))
        XCTAssertTrue(result.columnNames.contains("avg_margin"))
        XCTAssertGreaterThan(result.rowCount, 0)

        // Check sorted descending by total_revenue
        if result.rowCount >= 2 {
            let rev0 = result["total_revenue"][0] as? Double ?? 0
            let rev1 = result["total_revenue"][1] as? Double ?? 0
            XCTAssertGreaterThanOrEqual(rev0, rev1)
        }
    }

    // MARK: - JSON File-Based Pipeline

    func test_fullPipeline_jsonFile() throws {
        let result = try runJSONPipeline(jsonFile: "transforms.json")

        XCTAssertTrue(result.columnNames.contains("total_revenue"))
        XCTAssertFalse(result.columnNames.contains("revenue"))
        XCTAssertTrue(result.columnNames.contains("avg_margin"))
        XCTAssertGreaterThan(result.rowCount, 0)
    }

    // MARK: - Empty Result

    func test_emptyResult_afterAggressiveFilter() throws {
        let result = try runPipeline(chain: "filter(revenue > 9999999)")
        XCTAssertEqual(result.rowCount, 0)
        XCTAssertFalse(result.columnNames.isEmpty) // schema preserved
    }

    // MARK: - Derive Integration

    func test_derive_in_pipeline() throws {
        let result = try runPipeline(chain: """
            derive(profit = revenue - cost) |
            filter(profit > 10000) |
            select(region, sku, profit) |
            sort(profit, desc)
        """)
        XCTAssertEqual(result.columnNames, ["region", "sku", "profit"])
        XCTAssertGreaterThan(result.rowCount, 0)
        // All profits should be > 10000
        for i in 0..<result.rowCount {
            let profit = result["profit"][i] as? Double ?? 0
            XCTAssertGreaterThan(profit, 10000)
        }
    }

    // MARK: - Select + Rename Pipeline

    func test_select_rename_pipeline() throws {
        let result = try runPipeline(chain: """
            select(region, revenue, margin) |
            rename(revenue -> sales) |
            rename(margin -> profit_margin)
        """)
        XCTAssertEqual(Set(result.columnNames), Set(["region", "sales", "profit_margin"]))
    }

    // MARK: - Verbose Mode (smoke test)

    func test_verbose_doesNotCrash() throws {
        let inputURL = fixtureURL("sales.csv")
        let df = try DataFrame.readCSV(url: inputURL)
        let operations = try DSLParser.parse("filter(revenue > 10000) | head(3)")
        // Verbose should write to stderr and not crash
        let result = try TransformRunner(operations: operations, verbose: true).run(on: df)
        XCTAssertEqual(result.rowCount, 3)
    }

    // MARK: - JSON Parser Error Messages

    func test_json_invalidOperator_givesHelpfulError() throws {
        let json = """
        { "operations": [{ "op": "filter", "args": { "column": "x", "operator": "~=", "value": 1 } }] }
        """
        XCTAssertThrowsError(try JSONTransformParser.parse(from: json)) { error in
            let desc = (error as? CLIError)?.errorDescription ?? ""
            XCTAssertTrue(desc.contains("filter"), "Error should mention filter context: \(desc)")
        }
    }

    func test_json_missingField_givesHelpfulError() throws {
        let json = """
        { "operations": [{ "op": "sort", "args": {} }] }
        """
        XCTAssertThrowsError(try JSONTransformParser.parse(from: json)) { error in
            let desc = (error as? CLIError)?.errorDescription ?? ""
            XCTAssertTrue(desc.contains("sort"), "Error should mention sort context: \(desc)")
        }
    }

    // MARK: - Edge Cases

    func test_headThenTail() throws {
        let result = try runPipeline(chain: "head(5) | tail(2)")
        XCTAssertEqual(result.rowCount, 2)
    }

    func test_multipleRenames() throws {
        let result = try runPipeline(chain: "rename(revenue -> rev) | rename(cost -> cst)")
        XCTAssertTrue(result.columnNames.contains("rev"))
        XCTAssertTrue(result.columnNames.contains("cst"))
        XCTAssertFalse(result.columnNames.contains("revenue"))
        XCTAssertFalse(result.columnNames.contains("cost"))
    }
}
