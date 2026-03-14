import Testing
import Foundation
import SwiftPandas
@testable import SwiftPandasCLI

@Suite struct TransformTests {

    private func loadSalesCSV() throws -> DataFrame {
        let url = Bundle.module.url(forResource: "sales", withExtension: "csv", subdirectory: "Fixtures")!
        return try DataFrame.readCSV(url: url)
    }

    // MARK: - Filter

    @Test func test_filter_greaterThan() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(revenue > 10000)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 5)
        // All revenue values should be > 10000
        for i in 0..<result.rowCount {
            let rev = result["revenue"][i] as? Double ?? 0
            #expect(rev > 10000)
        }
    }

    @Test func test_filter_stringEquality() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(status == \"active\")")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 6)
    }

    @Test func test_filter_contains() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(sku contains \"001\")")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 2)
    }

    @Test func test_filter_invalidColumn_throws() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(nonexistent > 0)")
        #expect(throws: (any Error).self) {
            try TransformRunner(operations: ops, verbose: false).run(on: df)
        }
    }

    // MARK: - Sort

    @Test func test_sort_desc() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("sort(revenue, desc)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        let revenues = (0..<result.rowCount).map { result["revenue"][$0] as? Double ?? 0 }
        #expect(revenues == revenues.sorted(by: >))
    }

    @Test func test_sort_asc() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("sort(revenue, asc)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        let revenues = (0..<result.rowCount).map { result["revenue"][$0] as? Double ?? 0 }
        #expect(revenues == revenues.sorted())
    }

    // MARK: - Rename

    @Test func test_rename() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("rename(revenue -> total_revenue)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.columnNames.contains("total_revenue"))
        #expect(!result.columnNames.contains("revenue"))
        #expect(result.rowCount == df.rowCount)
    }

    @Test func test_rename_unknownColumn_throws() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("rename(ghost -> phantom)")
        #expect(throws: (any Error).self) {
            try TransformRunner(operations: ops, verbose: false).run(on: df)
        }
    }

    // MARK: - Select / Drop

    @Test func test_select() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("select(region, revenue)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.columnNames == ["region", "revenue"])
        #expect(result.columnCount == 2)
    }

    @Test func test_drop() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("drop(cost, status)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(!result.columnNames.contains("cost"))
        #expect(!result.columnNames.contains("status"))
        #expect(result.columnCount == df.columnCount - 2)
    }

    // MARK: - Head / Tail

    @Test func test_head() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("head(3)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 3)
    }

    @Test func test_tail() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("tail(2)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 2)
    }

    @Test func test_head_clampsToRowCount() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("head(9999)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == df.rowCount)
    }

    // MARK: - Round

    @Test func test_round() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("round(margin, 1)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        for i in 0..<result.rowCount {
            let v = result["margin"][i] as? Double ?? 0
            let rounded = (v * 10).rounded() / 10
            #expect(abs(v - rounded) < 1e-9)
        }
    }

    // MARK: - Derive

    @Test func test_derive_arithmetic() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("derive(profit = revenue - cost)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.columnNames.contains("profit"))
        let profit0 = result["profit"][0] as? Double ?? 0
        #expect(abs(profit0 - 6000.0) < 0.01) // 15000 - 9000
    }

    @Test func test_derive_multiplication() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("derive(double_rev = revenue * 2)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        let v = result["double_rev"][0] as? Double ?? 0
        #expect(abs(v - 30000.0) < 0.01)
    }

    // MARK: - GroupBy + Agg

    @Test func test_groupby_agg_sum() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("groupby(region) | agg(sum:revenue)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 3) // APAC, EMEA, US
        #expect(result.columnNames.contains("region"))
        #expect(result.columnNames.contains("revenue"))
    }

    @Test func test_groupby_agg_multiKey() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("groupby(region, quarter) | agg(sum:revenue, count:transactions)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        // APAC+Q1, APAC+Q2, EMEA+Q1, EMEA+Q2, US+Q1, US+Q2 = 6 combos
        #expect(result.rowCount == 6)
        #expect(result.columnNames.contains("revenue"))
        #expect(result.columnNames.contains("transactions"))
    }

    @Test func test_agg_without_groupby_throws() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("agg(sum:revenue)")
        #expect(throws: (any Error).self) {
            try TransformRunner(operations: ops, verbose: false).run(on: df)
        }
    }

    // MARK: - Cast

    @Test func test_cast_toString() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("cast(revenue, String)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == df.rowCount)
    }

    // MARK: - Chained Pipeline

    @Test func test_filter_sort_head_chain() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(revenue > 10000) | sort(revenue, desc) | head(3)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        #expect(result.rowCount == 3)
        let rev0 = result["revenue"][0] as? Double ?? 0
        let rev1 = result["revenue"][1] as? Double ?? 0
        #expect(rev0 >= rev1) // sorted desc
    }
}
