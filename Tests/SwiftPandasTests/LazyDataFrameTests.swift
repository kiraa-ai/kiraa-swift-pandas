import XCTest
@testable import SwiftPandas

// MARK: - Predicate Tests

final class PredicateTests: XCTestCase {
    let df = DataFrame([
        "name": [String](),
        "revenue": [Double](),
        "region": [String](),
    ].count == 0 ? ["revenue": [100.0, 500.0, 1500.0, 2000.0, 300.0]] : [:])

    func sampleDF() -> DataFrame {
        DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana", "Eve"])),
            ("revenue", Column.fromDoubles([100.0, 500.0, 1500.0, 2000.0, 300.0])),
            ("region", Column.fromStrings(["East", "West", "East", "West", "East"])),
            ("age", Column.fromDoubles([25, 30, 35, 40, 28])),
        ])
    }

    func testComparisonGT() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") > 1000
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, false, true, true, false])
    }

    func testComparisonGE() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") >= 500
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, true, true, true, false])
    }

    func testComparisonLT() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") < 500
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [true, false, false, false, true])
    }

    func testComparisonLE() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") <= 500
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [true, true, false, false, true])
    }

    func testComparisonEQ() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") == 500.0
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, true, false, false, false])
    }

    func testComparisonNE() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") != 500.0
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [true, false, true, true, true])
    }

    func testIntComparison() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("revenue") > 1000
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, false, true, true, false])
    }

    func testStringEQ() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("region") == "East"
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [true, false, true, false, true])
    }

    func testStringNE() {
        let df = sampleDF()
        let pred: ColumnPredicate = col("region") != "East"
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, true, false, true, false])
    }

    func testStringContains() {
        let df = sampleDF()
        let pred = col("name").contains("li")
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [true, false, true, false, false])
    }

    func testAND() {
        let df = sampleDF()
        let pred = (col("revenue") > 400) & (col("region") == "West")
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, true, false, true, false])
    }

    func testOR() {
        let df = sampleDF()
        let pred = (col("revenue") > 1000) | (col("region") == "East")
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [true, false, true, true, true])
    }

    func testNOT() {
        let df = sampleDF()
        let pred = !(col("region") == "East")
        let mask = pred.evaluate(on: df)
        XCTAssertEqual(mask, [false, true, false, true, false])
    }

    func testReferencedColumns() {
        let pred = (col("revenue") > 1000) & (col("region") == "East")
        XCTAssertEqual(pred.referencedColumns, ["revenue", "region"])
    }

    func testPredicateDescription() {
        let pred: ColumnPredicate = col("revenue") > 1000.0
        XCTAssertTrue(pred.description.contains("revenue"))
        XCTAssertTrue(pred.description.contains(">"))
    }
}

// MARK: - LazyDataFrame Basic Tests

final class LazyDataFrameTests: XCTestCase {
    func sampleDF() -> DataFrame {
        DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana", "Eve"])),
            ("revenue", Column.fromDoubles([100.0, 500.0, 1500.0, 2000.0, 300.0])),
            ("region", Column.fromStrings(["East", "West", "East", "West", "East"])),
            ("cost", Column.fromDoubles([50.0, 200.0, 800.0, 900.0, 150.0])),
        ])
    }

    func testLazyFilterMatchesEager() {
        let df = sampleDF()
        let eagerMask = df["revenue"] > 1000
        let eager = df.filter(mask: eagerMask)

        let lazy = df.lazy()
            .filter(col("revenue") > 1000)
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        XCTAssertEqual(lazy.columnNames, eager.columnNames)
        for col in lazy.columnNames {
            for i in 0..<lazy.rowCount {
                XCTAssertEqual(lazy.columns[col]!.formattedValue(at: i),
                              eager.columns[col]!.formattedValue(at: i))
            }
        }
    }

    func testLazySelectMatchesEager() {
        let df = sampleDF()
        let eager = df.select(columns: ["name", "revenue"])

        let lazy = df.lazy()
            .select("name", "revenue")
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        XCTAssertEqual(lazy.columnNames, eager.columnNames)
    }

    func testLazyDropMatchesEager() {
        let df = sampleDF()
        let eager = df.drop(columns: ["cost"])

        let lazy = df.lazy()
            .drop(["cost"])
            .collect()

        XCTAssertEqual(lazy.columnNames, eager.columnNames)
        XCTAssertEqual(lazy.rowCount, eager.rowCount)
    }

    func testLazySortMatchesEager() {
        let df = sampleDF()
        let eager = df.sortValues(by: ["revenue"], ascending: [false])

        let lazy = df.lazy()
            .sort(by: "revenue", ascending: false)
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        for i in 0..<lazy.rowCount {
            XCTAssertEqual(lazy.columns["revenue"]!.formattedValue(at: i),
                          eager.columns["revenue"]!.formattedValue(at: i))
        }
    }

    func testLazyHeadMatchesEager() {
        let df = sampleDF()
        let eager = df.head(3)

        let lazy = df.lazy()
            .head(3)
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        XCTAssertEqual(lazy.rowCount, 3)
    }

    func testLazyGroupBySumMatchesEager() {
        let df = sampleDF()
        let eager = df.groupBy("region").sum()

        let lazy = df.lazy()
            .groupBy("region").sum()
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        // Both should have same index labels (group keys)
        XCTAssertEqual(Set(lazy.indexLabels), Set(eager.indexLabels))
    }

    func testLazyGroupByMeanMatchesEager() {
        let df = sampleDF()
        let eager = df.groupBy("region").mean()

        let lazy = df.lazy()
            .groupBy("region").mean()
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
    }

    func testLazyGroupByCountMatchesEager() {
        let df = sampleDF()
        let eager = df.groupBy("region").count()

        let lazy = df.lazy()
            .groupBy("region").count()
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
    }

    func testLazyGroupByMinMatchesEager() {
        let df = sampleDF()
        let eager = df.groupBy("region").min()

        let lazy = df.lazy()
            .groupBy("region").min()
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
    }

    func testLazyGroupByMaxMatchesEager() {
        let df = sampleDF()
        let eager = df.groupBy("region").max()

        let lazy = df.lazy()
            .groupBy("region").max()
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
    }

    func testLazyMergeMatchesEager() {
        let left = DataFrame(columns: [
            ("key", Column.fromStrings(["a", "b", "c"])),
            ("val1", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let right = DataFrame(columns: [
            ("key", Column.fromStrings(["b", "c", "d"])),
            ("val2", Column.fromDoubles([20.0, 30.0, 40.0])),
        ])

        let eager = left.merge(right, on: "key", how: .inner)

        let lazy = left.lazy()
            .merge(right.lazy(), on: "key", how: .inner)
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        XCTAssertEqual(Set(lazy.columnNames), Set(eager.columnNames))
    }
}

// MARK: - Chained Operations Tests

final class LazyChainedTests: XCTestCase {
    func sampleDF() -> DataFrame {
        DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana", "Eve"])),
            ("revenue", Column.fromDoubles([100.0, 500.0, 1500.0, 2000.0, 300.0])),
            ("region", Column.fromStrings(["East", "West", "East", "West", "East"])),
            ("cost", Column.fromDoubles([50.0, 200.0, 800.0, 900.0, 150.0])),
        ])
    }

    func testFilterThenSelect() {
        let df = sampleDF()

        // Eager
        let eagerMask = df["revenue"] > 400
        let eager = df.filter(mask: eagerMask).select(columns: ["name", "revenue"])

        // Lazy
        let lazy = df.lazy()
            .filter(col("revenue") > 400)
            .select("name", "revenue")
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        XCTAssertEqual(lazy.columnNames, eager.columnNames)
        for i in 0..<lazy.rowCount {
            XCTAssertEqual(lazy.columns["name"]!.formattedValue(at: i),
                          eager.columns["name"]!.formattedValue(at: i))
            XCTAssertEqual(lazy.columns["revenue"]!.formattedValue(at: i),
                          eager.columns["revenue"]!.formattedValue(at: i))
        }
    }

    func testFilterThenGroupBySum() {
        let df = sampleDF()

        // Eager
        let eagerMask = df["revenue"] > 200
        let eager = df.filter(mask: eagerMask).groupBy("region").sum()

        // Lazy
        let lazy = df.lazy()
            .filter(col("revenue") > 200)
            .groupBy("region").sum()
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        XCTAssertEqual(Set(lazy.indexLabels), Set(eager.indexLabels))
    }

    func testFilterSelectGroupByChain() {
        let df = sampleDF()

        // The full chain: filter → select → groupBy → sum
        let result = df.lazy()
            .filter(col("revenue") > 200)
            .select("name", "region", "revenue")
            .groupBy("region").sum()
            .collect()

        // Verify it produces valid output
        XCTAssertTrue(result.rowCount > 0)
        XCTAssertTrue(result.columnNames.contains("revenue"))
    }

    func testMultipleFilters() {
        let df = sampleDF()

        // Eager
        let mask1 = df["revenue"] > 200
        let mask2 = df["revenue"] < 2000
        let eager = df.filter(mask: zip(mask1, mask2).map { $0 && $1 })

        // Lazy (two separate filters — should be fused by optimizer)
        let lazy = df.lazy()
            .filter(col("revenue") > 200)
            .filter(col("revenue") < 2000)
            .collect()

        XCTAssertEqual(lazy.rowCount, eager.rowCount)
        for i in 0..<lazy.rowCount {
            XCTAssertEqual(lazy.columns["revenue"]!.formattedValue(at: i),
                          eager.columns["revenue"]!.formattedValue(at: i))
        }
    }

    func testSortThenHead() {
        let df = sampleDF()
        let eager = df.sortValues(by: "revenue", ascending: false).head(3)

        let lazy = df.lazy()
            .sort(by: "revenue", ascending: false)
            .head(3)
            .collect()

        XCTAssertEqual(lazy.rowCount, 3)
        for i in 0..<lazy.rowCount {
            XCTAssertEqual(lazy.columns["revenue"]!.formattedValue(at: i),
                          eager.columns["revenue"]!.formattedValue(at: i))
        }
    }
}

// MARK: - Query Optimizer Tests

final class QueryOptimizerTests: XCTestCase {
    func sampleDF() -> DataFrame {
        DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie"])),
            ("revenue", Column.fromDoubles([100.0, 500.0, 1500.0])),
            ("region", Column.fromStrings(["East", "West", "East"])),
        ])
    }

    func testFilterFusion() {
        let df = sampleDF()
        let plan: QueryPlan = .filter(
            col("revenue") > 100,
            .filter(col("revenue") < 2000, .scan(df))
        )
        let optimized = QueryOptimizer.optimize(plan)

        // The optimized plan should have a single filter with AND
        if case .filter(let pred, .scan) = optimized {
            if case .and = pred {
                // Correct: two filters fused into AND
            } else {
                XCTFail("Expected fused AND predicate, got \(pred)")
            }
        } else {
            XCTFail("Expected single filter node, got \(optimized)")
        }
    }

    func testPredicatePushdownBelowSort() {
        let df = sampleDF()
        let plan: QueryPlan = .filter(
            col("revenue") > 100,
            .sort(by: ["name"], ascending: [true], .scan(df))
        )
        let optimized = QueryOptimizer.optimize(plan)

        // Filter should be pushed below sort
        if case .sort(_, _, let child) = optimized {
            if case .filter = child {
                // Correct: filter pushed below sort
            } else {
                XCTFail("Expected filter below sort, got \(child)")
            }
        } else {
            XCTFail("Expected sort at top, got \(optimized)")
        }
    }

    func testRedundantLimitElimination() {
        let df = sampleDF()
        let plan: QueryPlan = .limit(5, .limit(10, .scan(df)))
        let optimized = QueryOptimizer.optimize(plan)

        // Should be reduced to limit(5, scan)
        if case .limit(let n, .scan) = optimized {
            XCTAssertEqual(n, 5)
        } else {
            XCTFail("Expected limit(5, scan), got \(optimized)")
        }
    }

    func testIdentitySelectRemoval() {
        let df = sampleDF()
        let plan: QueryPlan = .select(df.columnNames, .scan(df))
        let optimized = QueryOptimizer.optimize(plan)

        // Selecting all columns should be removed
        if case .scan = optimized {
            // Correct: identity select removed
        } else {
            XCTFail("Expected bare scan, got \(optimized)")
        }
    }

    func testOptimizerPreservesCorrectness() {
        // Most important test: optimized plan produces same result as unoptimized
        let df = sampleDF()
        let plan: QueryPlan = .filter(
            col("revenue") > 100,
            .filter(
                col("region") == "East",
                .sort(by: ["revenue"], ascending: [true], .scan(df))
            )
        )

        let unoptimized = QueryExecutor.execute(plan)
        let optimized = QueryExecutor.execute(QueryOptimizer.optimize(plan))

        XCTAssertEqual(unoptimized.rowCount, optimized.rowCount)
        for colName in unoptimized.columnNames {
            for i in 0..<unoptimized.rowCount {
                XCTAssertEqual(unoptimized.columns[colName]!.formattedValue(at: i),
                              optimized.columns[colName]!.formattedValue(at: i))
            }
        }
    }
}

// MARK: - Explain Tests

final class ExplainTests: XCTestCase {
    func testExplainOutput() {
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob"])),
            ("revenue", Column.fromDoubles([100.0, 500.0])),
            ("region", Column.fromStrings(["East", "West"])),
        ])

        let explanation = df.lazy()
            .filter(col("revenue") > 100)
            .select("name", "region", "revenue")
            .groupBy("region").sum()
            .explain()

        XCTAssertTrue(explanation.contains("GroupBy"))
        XCTAssertTrue(explanation.contains("Filter") || explanation.contains("Select") || explanation.contains("Scan"))
    }

    func testExplainRawVsOptimized() {
        let df = DataFrame(columns: [
            ("revenue", Column.fromDoubles([100.0, 500.0])),
            ("region", Column.fromStrings(["East", "West"])),
        ])

        let lazy = df.lazy()
            .filter(col("revenue") > 100)
            .filter(col("revenue") < 2000)

        let raw = lazy.explainRaw()
        let optimized = lazy.explain()

        // Raw should have two separate Filter nodes
        XCTAssertTrue(raw.contains("Filter"))

        // Optimized should have fused them (still contains Filter)
        XCTAssertTrue(optimized.contains("Filter"))
    }
}

// MARK: - Edge Cases

final class LazyEdgeCaseTests: XCTestCase {
    func testEmptyDataFrame() {
        let df = DataFrame()
        // Should not crash
        let result = df.lazy().collect()
        XCTAssertEqual(result.rowCount, 0)
    }

    func testSingleRowDataFrame() {
        let df = DataFrame(columns: [
            ("x", Column.fromDoubles([42.0])),
        ])
        let result = df.lazy()
            .filter(col("x") > 0)
            .collect()
        XCTAssertEqual(result.rowCount, 1)
    }

    func testFilterRemovesAllRows() {
        let df = DataFrame(columns: [
            ("x", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let result = df.lazy()
            .filter(col("x") > 100)
            .collect()
        XCTAssertEqual(result.rowCount, 0)
    }

    func testHeadZero() {
        let df = DataFrame(columns: [
            ("x", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let result = df.lazy().head(0).collect()
        XCTAssertEqual(result.rowCount, 0)
    }

    func testHeadLargerThanDataFrame() {
        let df = DataFrame(columns: [
            ("x", Column.fromDoubles([1.0, 2.0])),
        ])
        let result = df.lazy().head(100).collect()
        XCTAssertEqual(result.rowCount, 2)
    }

    func testWithNAValues() {
        let df = DataFrame(columns: [
            ("x", Column.fromOptionalDoubles([1.0, nil, 3.0, nil, 5.0])),
            ("region", Column.fromStrings(["a", "b", "a", "b", "a"])),
        ])

        // Filter should treat NA as false
        let result = df.lazy()
            .filter(col("x") > 2)
            .collect()

        XCTAssertEqual(result.rowCount, 2) // 3.0 and 5.0
    }
}
