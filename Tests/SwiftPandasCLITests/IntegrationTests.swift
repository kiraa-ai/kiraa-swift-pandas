import Testing
import Foundation
import SwiftPandas
@testable import SwiftPandasCLI

@Suite struct IntegrationTests {

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

    @Test func test_fullPipeline_inline() throws {
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

        #expect(result.columnNames.contains("total_revenue"))
        #expect(!result.columnNames.contains("revenue"))
        #expect(result.columnNames.contains("avg_margin"))
        #expect(result.rowCount > 0)

        // Check sorted descending by total_revenue
        if result.rowCount >= 2 {
            let rev0 = result["total_revenue"][0] as? Double ?? 0
            let rev1 = result["total_revenue"][1] as? Double ?? 0
            #expect(rev0 >= rev1)
        }
    }

    // MARK: - JSON File-Based Pipeline

    @Test func test_fullPipeline_jsonFile() throws {
        let result = try runJSONPipeline(jsonFile: "transforms.json")

        #expect(result.columnNames.contains("total_revenue"))
        #expect(!result.columnNames.contains("revenue"))
        #expect(result.columnNames.contains("avg_margin"))
        #expect(result.rowCount > 0)
    }

    // MARK: - Empty Result

    @Test func test_emptyResult_afterAggressiveFilter() throws {
        let result = try runPipeline(chain: "filter(revenue > 9999999)")
        #expect(result.rowCount == 0)
        #expect(!result.columnNames.isEmpty) // schema preserved
    }

    // MARK: - Derive Integration

    @Test func test_derive_in_pipeline() throws {
        let result = try runPipeline(chain: """
            derive(profit = revenue - cost) |
            filter(profit > 10000) |
            select(region, sku, profit) |
            sort(profit, desc)
        """)
        #expect(result.columnNames == ["region", "sku", "profit"])
        #expect(result.rowCount > 0)
        // All profits should be > 10000
        for i in 0..<result.rowCount {
            let profit = result["profit"][i] as? Double ?? 0
            #expect(profit > 10000)
        }
    }

    // MARK: - Select + Rename Pipeline

    @Test func test_select_rename_pipeline() throws {
        let result = try runPipeline(chain: """
            select(region, revenue, margin) |
            rename(revenue -> sales) |
            rename(margin -> profit_margin)
        """)
        #expect(Set(result.columnNames) == Set(["region", "sales", "profit_margin"]))
    }

    // MARK: - Verbose Mode (smoke test)

    @Test func test_verbose_doesNotCrash() throws {
        let inputURL = fixtureURL("sales.csv")
        let df = try DataFrame.readCSV(url: inputURL)
        let operations = try DSLParser.parse("filter(revenue > 10000) | head(3)")
        // Verbose should write to stderr and not crash
        let result = try TransformRunner(operations: operations, verbose: true).run(on: df)
        #expect(result.rowCount == 3)
    }

    // MARK: - JSON Parser Error Messages

    @Test func test_json_invalidOperator_givesHelpfulError() throws {
        let json = """
        { "operations": [{ "op": "filter", "args": { "column": "x", "operator": "~=", "value": 1 } }] }
        """
        #expect(throws: (any Error).self) {
            let parsed = try JSONTransformParser.parse(from: json)
            let desc = "parsed unexpectedly: \(parsed)"
            _ = desc
        }
    }

    @Test func test_json_missingField_givesHelpfulError() throws {
        let json = """
        { "operations": [{ "op": "sort", "args": {} }] }
        """
        #expect(throws: (any Error).self) {
            let parsed = try JSONTransformParser.parse(from: json)
            let desc = "parsed unexpectedly: \(parsed)"
            _ = desc
        }
    }

    // MARK: - Edge Cases

    @Test func test_headThenTail() throws {
        let result = try runPipeline(chain: "head(5) | tail(2)")
        #expect(result.rowCount == 2)
    }

    @Test func test_multipleRenames() throws {
        let result = try runPipeline(chain: "rename(revenue -> rev) | rename(cost -> cst)")
        #expect(result.columnNames.contains("rev"))
        #expect(result.columnNames.contains("cst"))
        #expect(!result.columnNames.contains("revenue"))
        #expect(!result.columnNames.contains("cost"))
    }
}
