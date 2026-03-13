import XCTest
import SwiftPandas
@testable import SwiftPandasCLI

final class TransformTests: XCTestCase {

    private func loadSalesCSV() throws -> DataFrame {
        let url = Bundle.module.url(forResource: "sales", withExtension: "csv", subdirectory: "Fixtures")!
        return try DataFrame.readCSV(url: url)
    }

    // MARK: - Filter

    func test_filter_greaterThan() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(revenue > 10000)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 5)
        // All revenue values should be > 10000
        for i in 0..<result.rowCount {
            let rev = result["revenue"][i] as? Double ?? 0
            XCTAssertGreaterThan(rev, 10000)
        }
    }

    func test_filter_stringEquality() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(status == \"active\")")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 6)
    }

    func test_filter_contains() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(sku contains \"001\")")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 2)
    }

    func test_filter_invalidColumn_throws() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(nonexistent > 0)")
        XCTAssertThrowsError(
            try TransformRunner(operations: ops, verbose: false).run(on: df)
        ) { error in
            XCTAssertTrue((error as? CLIError)?.isUnknownColumn == true)
        }
    }

    // MARK: - Sort

    func test_sort_desc() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("sort(revenue, desc)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        let revenues = (0..<result.rowCount).map { result["revenue"][$0] as? Double ?? 0 }
        XCTAssertEqual(revenues, revenues.sorted(by: >))
    }

    func test_sort_asc() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("sort(revenue, asc)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        let revenues = (0..<result.rowCount).map { result["revenue"][$0] as? Double ?? 0 }
        XCTAssertEqual(revenues, revenues.sorted())
    }

    // MARK: - Rename

    func test_rename() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("rename(revenue -> total_revenue)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertTrue(result.columnNames.contains("total_revenue"))
        XCTAssertFalse(result.columnNames.contains("revenue"))
        XCTAssertEqual(result.rowCount, df.rowCount)
    }

    func test_rename_unknownColumn_throws() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("rename(ghost -> phantom)")
        XCTAssertThrowsError(
            try TransformRunner(operations: ops, verbose: false).run(on: df)
        )
    }

    // MARK: - Select / Drop

    func test_select() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("select(region, revenue)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.columnNames, ["region", "revenue"])
        XCTAssertEqual(result.columnCount, 2)
    }

    func test_drop() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("drop(cost, status)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertFalse(result.columnNames.contains("cost"))
        XCTAssertFalse(result.columnNames.contains("status"))
        XCTAssertEqual(result.columnCount, df.columnCount - 2)
    }

    // MARK: - Head / Tail

    func test_head() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("head(3)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 3)
    }

    func test_tail() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("tail(2)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 2)
    }

    func test_head_clampsToRowCount() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("head(9999)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, df.rowCount)
    }

    // MARK: - Round

    func test_round() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("round(margin, 1)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        for i in 0..<result.rowCount {
            let v = result["margin"][i] as? Double ?? 0
            let rounded = (v * 10).rounded() / 10
            XCTAssertEqual(v, rounded, accuracy: 1e-9)
        }
    }

    // MARK: - Derive

    func test_derive_arithmetic() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("derive(profit = revenue - cost)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertTrue(result.columnNames.contains("profit"))
        let profit0 = result["profit"][0] as? Double ?? 0
        XCTAssertEqual(profit0, 6000.0, accuracy: 0.01) // 15000 - 9000
    }

    func test_derive_multiplication() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("derive(double_rev = revenue * 2)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        let v = result["double_rev"][0] as? Double ?? 0
        XCTAssertEqual(v, 30000.0, accuracy: 0.01)
    }

    // MARK: - GroupBy + Agg

    func test_groupby_agg_sum() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("groupby(region) | agg(sum:revenue)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 3) // APAC, EMEA, US
        XCTAssertTrue(result.columnNames.contains("region"))
        XCTAssertTrue(result.columnNames.contains("revenue"))
    }

    func test_groupby_agg_multiKey() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("groupby(region, quarter) | agg(sum:revenue, count:transactions)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        // APAC+Q1, APAC+Q2, EMEA+Q1, EMEA+Q2, US+Q1, US+Q2 = 6 combos
        XCTAssertEqual(result.rowCount, 6)
        XCTAssertTrue(result.columnNames.contains("revenue"))
        XCTAssertTrue(result.columnNames.contains("transactions"))
    }

    func test_agg_without_groupby_throws() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("agg(sum:revenue)")
        XCTAssertThrowsError(
            try TransformRunner(operations: ops, verbose: false).run(on: df)
        )
    }

    // MARK: - Cast

    func test_cast_toString() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("cast(revenue, String)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, df.rowCount)
    }

    // MARK: - Chained Pipeline

    func test_filter_sort_head_chain() throws {
        let df = try loadSalesCSV()
        let ops = try DSLParser.parse("filter(revenue > 10000) | sort(revenue, desc) | head(3)")
        let result = try TransformRunner(operations: ops, verbose: false).run(on: df)
        XCTAssertEqual(result.rowCount, 3)
        let rev0 = result["revenue"][0] as? Double ?? 0
        let rev1 = result["revenue"][1] as? Double ?? 0
        XCTAssertGreaterThanOrEqual(rev0, rev1) // sorted desc
    }
}
