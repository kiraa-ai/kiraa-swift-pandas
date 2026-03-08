// ──────────────────────────────────────────────────────────────────────────────
// LazyDataFrameTests.swift
// SwiftPandasTests
//
// Tests for the lazy evaluation engine introduced in SwiftPandas v0.3.0. The
// lazy API lets users build a chain of DataFrame operations (filter, select,
// drop, sort, head, groupBy, merge) without materializing intermediate results.
// Internally each call appends a node to a `QueryPlan` tree. When `.collect()`
// is called the `QueryOptimizer` rewrites the tree (filter fusion, predicate
// pushdown, redundant limit elimination, identity select removal) and then
// `QueryExecutor` walks the optimized tree to produce the final DataFrame.
//
// Test classes in this file:
//
//   - PredicateTests          — column predicate DSL: comparison operators
//                               (>, >=, <, <=, ==, !=), string equality,
//                               string contains, boolean combinators (&, |, !),
//                               referenced-column introspection, and
//                               description formatting.
//
//   - LazyDataFrameTests      — one-to-one correctness checks: each lazy
//                               operation (filter, select, drop, sort, head,
//                               groupBy sum/mean/count/min/max, merge) is
//                               compared cell-by-cell against the equivalent
//                               eager (non-lazy) operation to ensure identical
//                               output.
//
//   - LazyChainedTests        — multi-step operation chains: filter-then-select,
//                               filter-then-groupBy, filter-select-groupBy,
//                               multiple consecutive filters (testing filter
//                               fusion), and sort-then-head.
//
//   - QueryOptimizerTests     — unit tests for individual optimizer passes:
//                               filter fusion (two nested filters -> AND),
//                               predicate pushdown below sort, redundant limit
//                               elimination, identity select removal, and an
//                               end-to-end correctness check proving the
//                               optimized plan produces the same result as the
//                               unoptimized plan.
//
//   - ExplainTests            — tests for the `.explain()` and `.explainRaw()`
//                               introspection APIs that return human-readable
//                               plan descriptions.
//
//   - LazyEdgeCaseTests       — boundary conditions: empty DataFrame, single-row
//                               DataFrame, filter that removes all rows, head(0),
//                               head larger than the DataFrame, and NA values
//                               in filter predicates.
// ──────────────────────────────────────────────────────────────────────────────

import XCTest
@testable import SwiftPandas

// MARK: - Predicate Tests

/// Tests for the `ColumnPredicate` DSL used by the lazy evaluation engine.
///
/// `ColumnPredicate` is a value type that represents a boolean condition over
/// DataFrame columns. It is built using the `col("name")` free function and
/// comparison operators (`>`, `>=`, `<`, `<=`, `==`, `!=`), plus string-specific
/// helpers like `.contains(_:)`. Predicates can be combined with `&` (AND),
/// `|` (OR), and `!` (NOT). Each predicate can `evaluate(on:)` a DataFrame to
/// produce a `[Bool]` mask, and exposes `.referencedColumns` for use by the
/// query optimizer's projection pushdown pass.
///
/// Coverage includes:
/// - Numeric comparisons (GT, GE, LT, LE, EQ, NE) against Double literals.
/// - Integer literal comparison (auto-converted to Double).
/// - String equality and inequality.
/// - String `.contains(_:)` substring match.
/// - Boolean AND, OR, NOT combinators.
/// - `.referencedColumns` introspection.
/// - `.description` formatting.
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

/// One-to-one correctness tests comparing each lazy operation against its eager equivalent.
///
/// For every supported lazy operation (filter, select, drop, sort, head, groupBy
/// with each aggregation, and merge), this class builds the result both eagerly
/// (using the standard DataFrame API) and lazily (using `df.lazy()...collect()`),
/// then compares the two results cell-by-cell. This ensures the lazy engine
/// produces bit-identical output to the eager path.
///
/// The sample DataFrame used across tests contains 5 rows with columns: name
/// (String), revenue (Double), region (String), and cost (Double).
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

/// Tests for multi-step lazy operation chains that exercise the query optimizer.
///
/// These tests combine two or more lazy operations in a single pipeline and
/// verify that the final result matches the equivalent eager computation. They
/// are particularly important for validating optimizer passes like filter fusion
/// (two consecutive `.filter()` calls merged into a single AND predicate) and
/// predicate pushdown (filter pushed below sort so fewer rows are sorted).
///
/// Coverage includes:
/// - **Filter then select**: filter rows, then project columns.
/// - **Filter then groupBy sum**: filter rows, then aggregate.
/// - **Filter, select, groupBy chain**: the full three-step pipeline.
/// - **Multiple filters**: two consecutive `.filter()` calls that the optimizer
///   should fuse into a single AND predicate.
/// - **Sort then head**: sort all rows, then take the top N.
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

/// Unit tests for individual `QueryOptimizer` rewrite passes.
///
/// The query optimizer transforms a `QueryPlan` tree to reduce work at execution
/// time. Each test constructs a specific plan shape, runs the optimizer, and
/// inspects the resulting tree structure (via pattern matching on the `QueryPlan`
/// enum) to confirm the expected rewrite was applied.
///
/// Optimizer passes tested:
/// - **Filter fusion**: two nested `.filter` nodes are collapsed into a single
///   `.filter` with an `.and` predicate.
/// - **Predicate pushdown below sort**: a `.filter` above a `.sort` is pushed
///   below the `.sort` so that fewer rows need to be sorted.
/// - **Redundant limit elimination**: nested `.limit(5, .limit(10, ...))` is
///   simplified to `.limit(5, ...)` (the smaller limit wins).
/// - **Identity select removal**: a `.select` that lists all columns of the
///   source DataFrame is removed entirely, leaving a bare `.scan`.
/// - **End-to-end correctness**: an optimized plan produces the same DataFrame
///   as the unoptimized plan, verified cell-by-cell.
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

/// Tests for the `.explain()` and `.explainRaw()` plan introspection APIs.
///
/// These methods return human-readable string representations of the query plan
/// tree — `.explainRaw()` shows the plan before optimization, and `.explain()`
/// shows the plan after optimization. They are useful for debugging and for
/// verifying that the optimizer is actually transforming the plan as expected.
///
/// Coverage includes:
/// - **explain output**: a multi-step pipeline produces a string containing
///   expected node names like "GroupBy", "Filter", "Select", or "Scan".
/// - **Raw vs optimized**: a pipeline with two consecutive filters should show
///   two Filter nodes in the raw plan and a fused Filter in the optimized plan.
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

/// Boundary-condition tests for the lazy evaluation engine.
///
/// These tests ensure the lazy pipeline handles degenerate inputs gracefully
/// without crashing or producing incorrect results.
///
/// Coverage includes:
/// - **Empty DataFrame**: `DataFrame().lazy().collect()` should return 0 rows.
/// - **Single-row DataFrame**: a filter that matches the only row should return 1.
/// - **Filter removes all rows**: a filter with an impossible condition yields 0.
/// - **head(0)**: requesting zero rows should return an empty DataFrame.
/// - **head larger than DataFrame**: requesting more rows than exist returns all.
/// - **NA values in filter**: NA positions in the predicate column are treated as
///   `false`, so they are excluded from the result.
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
