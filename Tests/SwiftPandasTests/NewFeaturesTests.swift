import XCTest
@testable import SwiftPandas

// MARK: - Series Comparison Operator Tests

final class SeriesComparisonTests: XCTestCase {
    func testGreaterThan() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s > 3.0
        XCTAssertEqual(mask, [false, false, false, true, true])
    }

    func testGreaterThanOrEqual() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s >= 3.0
        XCTAssertEqual(mask, [false, false, true, true, true])
    }

    func testLessThan() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s < 3.0
        XCTAssertEqual(mask, [true, true, false, false, false])
    }

    func testLessThanOrEqual() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s <= 3.0
        XCTAssertEqual(mask, [true, true, true, false, false])
    }

    func testComparisonWithNA() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        let mask = s > 2.0
        XCTAssertEqual(mask, [false, false, true, false, true]) // NAs produce false
    }

    func testEqDouble() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        let mask = s.eq(2.0)
        XCTAssertEqual(mask, [false, true, false, true, false])
    }

    func testNeDouble() {
        let s = Series([1.0, 2.0, 3.0])
        let mask = s.ne(2.0)
        XCTAssertEqual(mask, [true, false, true])
    }

    func testEqString() {
        let s = Series(["a", "b", "c", "b"])
        let mask = s.eq("b")
        XCTAssertEqual(mask, [false, true, false, true])
    }

    func testNeString() {
        let s = Series(["a", "b", "c"])
        let mask = s.ne("b")
        XCTAssertEqual(mask, [true, false, true])
    }

    func testStrContains() {
        let s = Series(["hello", "world", "help", "foo"])
        let mask = s.strContains("hel")
        XCTAssertEqual(mask, [true, false, true, false])
    }

    func testStrContainsWithNA() {
        let s = Series(["hello", nil, "help", nil] as [String?])
        let mask = s.strContains("hel")
        XCTAssertEqual(mask, [true, false, true, false]) // NAs produce false
    }

    func testDataFrameFilterWithComparison() {
        // The pandas-style: df[df["age"] > 30]
        let df = DataFrame(["name_len": [3.0, 5.0, 4.0, 6.0], "age": [25.0, 35.0, 28.0, 40.0]])
        let filtered = df[df["age"] > 30.0]
        XCTAssertEqual(filtered.rowCount, 2)
        XCTAssertEqual(filtered["age"].min(), 35.0)
    }
}

// MARK: - Series Apply/Map Tests

final class SeriesApplyMapTests: XCTestCase {
    func testApply() {
        let s = Series([1.0, 4.0, 9.0, 16.0])
        let sqrts = s.apply { $0.squareRoot() }
        XCTAssertEqual(sqrts.iloc(0) as? Double, 1.0)
        XCTAssertEqual(sqrts.iloc(1) as? Double, 2.0)
        XCTAssertEqual(sqrts.iloc(2) as? Double, 3.0)
        XCTAssertEqual(sqrts.iloc(3) as? Double, 4.0)
    }

    func testApplyWithNA() {
        let s = Series([1.0, nil, 9.0])
        let result = s.apply { $0 * 2 }
        XCTAssertEqual(result.iloc(0) as? Double, 2.0)
        XCTAssertNil(result.iloc(1) as? Double) // NA stays NA
        XCTAssertEqual(result.iloc(2) as? Double, 18.0)
    }

    func testMapDouble() {
        let s = Series([1.0, 2.0, 3.0, 2.0])
        let mapped = s.map([1.0: 10.0, 2.0: 20.0, 3.0: 30.0])
        XCTAssertEqual(mapped.sum(), 80.0) // 10 + 20 + 30 + 20
    }

    func testMapString() {
        let s = Series(["a", "b", "c", "a"])
        let mapped = s.map(["a": "alpha", "b": "beta"])
        XCTAssertEqual(mapped.iloc(0) as? String, "alpha")
        XCTAssertEqual(mapped.iloc(1) as? String, "beta")
        // "c" is not in mapping, so it becomes NA. "a" maps to "alpha" (both).
        XCTAssertEqual(mapped.naCount, 1) // only "c" unmapped
    }

    func testMapStringUnmappedBecomesNA() {
        let s = Series(["x", "y", "z"])
        let mapped = s.map(["x": "X"])
        XCTAssertEqual(mapped.iloc(0) as? String, "X")
        XCTAssertEqual(mapped.naCount, 2) // y, z not in mapping
    }
}

// MARK: - Series Scalar Arithmetic Tests

final class SeriesScalarArithmeticTests: XCTestCase {
    func testSubtractScalar() {
        let s = Series([10.0, 20.0, 30.0])
        let result = s - 5.0
        XCTAssertEqual(result.sum(), 45.0) // 5 + 15 + 25
    }

    func testDivideScalar() {
        let s = Series([10.0, 20.0, 30.0])
        let result = s / 10.0
        XCTAssertEqual(result.sum(), 6.0) // 1 + 2 + 3
    }

    func testScalarArithmeticWithNA() {
        let s = Series([10.0, nil, 30.0])
        let result = s - 5.0
        XCTAssertEqual(result.iloc(0) as? Double, 5.0)
        XCTAssertNil(result.iloc(1) as? Double)
        XCTAssertEqual(result.iloc(2) as? Double, 25.0)
    }
}

// MARK: - Median / Quantile / Cumsum Tests

final class SeriesStatisticsTests: XCTestCase {
    func testMedianOdd() {
        let s = Series([3.0, 1.0, 2.0, 5.0, 4.0])
        XCTAssertEqual(s.median(), 3.0)
    }

    func testMedianEven() {
        let s = Series([1.0, 2.0, 3.0, 4.0])
        XCTAssertEqual(s.median(), 2.5)
    }

    func testMedianWithNA() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        XCTAssertEqual(s.median(), 3.0) // median of [1, 3, 5]
    }

    func testQuantile() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(s.quantile(0.0), 1.0)
        XCTAssertEqual(s.quantile(0.5), 3.0)
        XCTAssertEqual(s.quantile(1.0), 5.0)
        XCTAssertEqual(s.quantile(0.25)!, 2.0, accuracy: 0.01)
        XCTAssertEqual(s.quantile(0.75)!, 4.0, accuracy: 0.01)
    }

    func testCumsum() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let cs = s.cumsum()
        XCTAssertEqual(cs.iloc(0) as? Double, 1.0)
        XCTAssertEqual(cs.iloc(1) as? Double, 3.0)
        XCTAssertEqual(cs.iloc(2) as? Double, 6.0)
        XCTAssertEqual(cs.iloc(3) as? Double, 10.0)
        XCTAssertEqual(cs.iloc(4) as? Double, 15.0)
    }

    func testCumsumWithNA() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        let cs = s.cumsum()
        XCTAssertEqual(cs.iloc(0) as? Double, 1.0)
        XCTAssertNil(cs.iloc(1) as? Double) // NA stays NA
        XCTAssertEqual(cs.iloc(2) as? Double, 4.0)
        XCTAssertNil(cs.iloc(3) as? Double)
        XCTAssertEqual(cs.iloc(4) as? Double, 9.0)
    }

    func testDescribeIncludesQuartiles() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let desc = s.describe()
        XCTAssertEqual(desc.count, 8)
        XCTAssertEqual(desc.index, ["count", "mean", "std", "min", "25%", "50%", "75%", "max"])
        // 50% should be the median
        XCTAssertEqual(desc.loc("50%") as? Double, 3.0)
    }

    func testDataFrameMedian() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [10.0, 20.0, 30.0]])
        let med = df.median()
        XCTAssertEqual(med.loc("a") as? Double, 2.0)
        XCTAssertEqual(med.loc("b") as? Double, 20.0)
    }
}

// MARK: - Unique / Duplicated Tests

final class DuplicatedTests: XCTestCase {
    func testSeriesDuplicated() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        let dupes = s.duplicated()
        XCTAssertEqual(dupes, [false, false, false, true, true])
    }

    func testSeriesDropDuplicates() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        let unique = s.dropDuplicates()
        XCTAssertEqual(unique.count, 3)
        XCTAssertEqual(unique.sum(), 6.0) // 1 + 2 + 3
    }

    func testSeriesNUnique() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        XCTAssertEqual(s.nUnique, 3)
    }

    func testSeriesUnique() {
        let s = Series(["a", "b", "c", "b", "a"])
        let unique = s.unique()
        XCTAssertEqual(unique.count, 3)
    }

    func testDataFrameDuplicated() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([1.0, 2.0, 1.0, 2.0])),
            ("b", Column.fromStrings(["x", "y", "x", "z"])),
        ])
        let dupes = df.duplicated()
        XCTAssertEqual(dupes, [false, false, true, false]) // row 2 duplicates row 0
    }

    func testDataFrameDropDuplicates() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([1.0, 2.0, 1.0, 2.0])),
            ("b", Column.fromStrings(["x", "y", "x", "z"])),
        ])
        let deduped = df.dropDuplicates()
        XCTAssertEqual(deduped.rowCount, 3)
    }

    func testDataFrameDropDuplicatesSubset() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([1.0, 2.0, 1.0, 3.0])),
            ("b", Column.fromStrings(["x", "y", "z", "x"])),
        ])
        let deduped = df.dropDuplicates(subset: ["a"])
        XCTAssertEqual(deduped.rowCount, 3) // 1.0, 2.0, 3.0
    }

    func testStringDuplicated() {
        let s = Series(["hello", "world", "hello"])
        let dupes = s.duplicated()
        XCTAssertEqual(dupes, [false, false, true])
    }
}

// MARK: - DataFrame .loc Tests

final class DataFrameLocTests: XCTestCase {
    func testLocSingleRow() {
        let df = DataFrame(
            columns: [("a", Column.fromDoubles([10.0, 20.0, 30.0]))],
            index: ["x", "y", "z"]
        )
        let row = df.loc("y")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?["a"] as? Double, 20.0)
    }

    func testLocMultipleRows() {
        let df = DataFrame(
            columns: [("a", Column.fromDoubles([10.0, 20.0, 30.0, 40.0]))],
            index: ["w", "x", "y", "z"]
        )
        let sub = df.loc(["x", "z"])
        XCTAssertEqual(sub.rowCount, 2)
        XCTAssertEqual(sub["a"].sum(), 60.0) // 20 + 40
    }

    func testLocMissingLabel() {
        let df = DataFrame(
            columns: [("a", Column.fromDoubles([10.0]))],
            index: ["x"]
        )
        XCTAssertNil(df.loc("missing"))
    }
}

// MARK: - DataFrame Mask Subscript Tests

final class DataFrameMaskSubscriptTests: XCTestCase {
    func testSubscriptWithMask() {
        let df = DataFrame(["age": [25.0, 35.0, 28.0, 40.0]])
        let result = df[df["age"] > 30.0]
        XCTAssertEqual(result.rowCount, 2)
    }

    func testPandasStyleFiltering() {
        // This is the key usability test: df[df["col"] > val]
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie"])),
            ("score", Column.fromDoubles([85.0, 92.0, 78.0])),
        ])
        let passed = df[df["score"] >= 80.0]
        XCTAssertEqual(passed.rowCount, 2)

        // Can also chain string comparisons
        let bobs = df[df["name"].eq("Bob")]
        XCTAssertEqual(bobs.rowCount, 1)
        XCTAssertEqual(bobs["score"].iloc(0) as? Double, 92.0)
    }
}

// MARK: - Multi-column Sort Tests

final class MultiColumnSortTests: XCTestCase {
    func testSortByMultipleColumns() {
        let df = DataFrame(columns: [
            ("dept", Column.fromStrings(["A", "B", "A", "B"])),
            ("salary", Column.fromDoubles([50.0, 60.0, 70.0, 40.0])),
        ])
        let sorted = df.sortValues(by: ["dept", "salary"], ascending: [true, false])
        // A rows first (sorted by salary desc): 70, 50
        // B rows next (sorted by salary desc): 60, 40
        XCTAssertEqual(sorted.columns["dept"]!.formattedValue(at: 0), "A")
        XCTAssertEqual(sorted["salary"].iloc(0) as? Double, 70.0)
        XCTAssertEqual(sorted["salary"].iloc(1) as? Double, 50.0)
        XCTAssertEqual(sorted.columns["dept"]!.formattedValue(at: 2), "B")
        XCTAssertEqual(sorted["salary"].iloc(2) as? Double, 60.0)
        XCTAssertEqual(sorted["salary"].iloc(3) as? Double, 40.0)
    }

    func testSortByMultipleColumnsDefaultAscending() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([2.0, 1.0, 2.0, 1.0])),
            ("b", Column.fromDoubles([30.0, 10.0, 20.0, 40.0])),
        ])
        let sorted = df.sortValues(by: ["a", "b"])
        // a=1 rows first (b asc): 10, 40; then a=2 rows: 20, 30
        XCTAssertEqual(sorted["a"].iloc(0) as? Double, 1.0)
        XCTAssertEqual(sorted["b"].iloc(0) as? Double, 10.0)
        XCTAssertEqual(sorted["a"].iloc(1) as? Double, 1.0)
        XCTAssertEqual(sorted["b"].iloc(1) as? Double, 40.0)
    }
}

// MARK: - Multi-column GroupBy Tests

final class MultiColumnGroupByTests: XCTestCase {
    func testGroupByMultipleColumns() {
        let df = DataFrame(columns: [
            ("dept", Column.fromStrings(["A", "A", "B", "B"])),
            ("level", Column.fromStrings(["Jr", "Sr", "Jr", "Sr"])),
            ("salary", Column.fromDoubles([50.0, 80.0, 60.0, 90.0])),
        ])
        let result = df.groupBy(["dept", "level"]).mean()
        XCTAssertEqual(result.rowCount, 4) // A-Jr, A-Sr, B-Jr, B-Sr
        XCTAssertTrue(result.columnNames.contains("dept"))
        XCTAssertTrue(result.columnNames.contains("level"))
        XCTAssertTrue(result.columnNames.contains("salary"))
    }

    func testSingleColumnGroupByStillWorks() {
        let df = DataFrame(columns: [
            ("group", Column.fromStrings(["A", "B", "A"])),
            ("val", Column.fromDoubles([10.0, 20.0, 30.0])),
        ])
        let result = df.groupBy("group").sum()
        XCTAssertEqual(result.rowCount, 2)
        // A: 10+30=40, B: 20
        let aIdx = result.indexLabels.firstIndex(of: "A")!
        XCTAssertEqual(result["val"].iloc(aIdx) as? Double, 40.0)
    }
}

// MARK: - String Concat Tests

final class ConcatTests: XCTestCase {
    func testConcatWithStringColumns() {
        let df1 = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob"])),
            ("score", Column.fromDoubles([90.0, 80.0])),
        ])
        let df2 = DataFrame(columns: [
            ("name", Column.fromStrings(["Charlie"])),
            ("score", Column.fromDoubles([70.0])),
        ])
        let combined = DataFrame.concat([df1, df2])
        XCTAssertEqual(combined.rowCount, 3)
        XCTAssertEqual(combined["name"].iloc(2) as? String, "Charlie")
        XCTAssertEqual(combined["score"].sum(), 240.0)
    }

    func testConcatMixedTypes() {
        let df1 = DataFrame(columns: [
            ("id", Column.fromStrings(["a", "b"])),
            ("val", Column.fromDoubles([1.0, 2.0])),
        ])
        let df2 = DataFrame(columns: [
            ("id", Column.fromStrings(["c"])),
            ("val", Column.fromDoubles([3.0])),
        ])
        let combined = DataFrame.concat([df1, df2])
        XCTAssertEqual(combined.rowCount, 3)
        XCTAssertEqual(combined.columns["id"]!.dtype, .string)
        XCTAssertEqual(combined.columns["val"]!.dtype, .float64)
    }
}

// MARK: - Integration: Full pandas-style workflow

final class PandasStyleWorkflowTests: XCTestCase {
    func testEndToEndPandasStyle() {
        // Build a DataFrame
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana", "Eve"])),
            ("department", Column.fromStrings(["Eng", "Sales", "Eng", "Sales", "Eng"])),
            ("salary", Column.fromDoubles([95000, 72000, 105000, 68000, 115000])),
            ("years", Column.fromDoubles([8, 4, 12, 3, 16])),
        ])

        // Pandas-style filter: df[df["salary"] > 80000]
        let highEarners = df[df["salary"] > 80000]
        XCTAssertEqual(highEarners.rowCount, 3) // Alice, Charlie, Eve

        // Filter by string
        let engineers = df[df["department"].eq("Eng")]
        XCTAssertEqual(engineers.rowCount, 3)

        // Apply
        let salaryInK = df["salary"].apply { $0 / 1000.0 }
        XCTAssertEqual(salaryInK.iloc(0) as? Double, 95.0)

        // Cumsum
        let cumSalary = df["salary"].cumsum()
        XCTAssertEqual(cumSalary.iloc(0) as? Double, 95000)
        XCTAssertEqual(cumSalary.iloc(4) as? Double, 455000)

        // Median
        XCTAssertEqual(df["salary"].median(), 95000)

        // Multi-column sort
        let sorted = df.sortValues(by: ["department", "salary"], ascending: [true, false])
        XCTAssertEqual(sorted.columns["name"]!.formattedValue(at: 0), "Eve") // Eng, highest salary

        // GroupBy
        let deptStats = df.select(columns: ["department", "salary"]).groupBy("department")
        let avgSalary = deptStats.mean()
        XCTAssertEqual(avgSalary.rowCount, 2)

        // Drop duplicates
        let depts = df["department"].dropDuplicates()
        XCTAssertEqual(depts.count, 2) // Eng, Sales

        // Quantiles
        XCTAssertNotNil(df["salary"].quantile(0.25))
        XCTAssertNotNil(df["salary"].quantile(0.75))
    }
}
