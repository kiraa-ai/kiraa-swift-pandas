// MARK: - CSVDataFrameTests.swift
// MARK: Comprehensive API Documentation Tests
//
// This file serves as both a test suite and a living API reference for the
// SwiftPandas library. Each test method demonstrates and verifies a major
// area of the API, producing formatted console output that reads like
// documentation. Topics covered:
//
//   0. Table of Contents  - Full API overview with section index
//   1. Series             - 1D labeled arrays: construction, indexing, NA handling,
//                           aggregations, arithmetic, comparisons, apply/map,
//                           cumulative ops, unique/duplicates, sorting
//   2. DataFrame          - 2D labeled tables: construction, properties, column/row
//                           access, boolean filtering, sorting, aggregations,
//                           duplicates, apply
//   3. GroupBy            - Split-apply-combine: single-column and multi-column
//                           grouping with sum/mean/count/min/max
//   4. Merge & Concat     - Combining DataFrames via inner/left joins and
//                           vertical concatenation
//   5. CSV I/O            - Reading and writing CSV from strings and files,
//                           custom parser/writer configuration, round-trip
//   6. Core Types         - Column storage, DType system, BitVector, NativeArray,
//                           NullableArray, StringArray
//   7. Index Types        - RangeIndex, StringIndex, Int64Index
//   8. Full Pipeline Demo - End-to-end workflow: load, describe, groupby, filter,
//                           sort, transform, merge, concat, CSV round-trip
//
// Run with: ./run_csv_demo.sh

import XCTest
@testable import SwiftPandas

/// Comprehensive documentation and demo test suite for the SwiftPandas library.
///
/// Each test method documents and exercises a specific API area, producing
/// formatted console output suitable for use as an API reference. Assertions
/// at the end of each test verify correctness of the demonstrated operations.
final class CSVDataFrameTests: XCTestCase {

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Helper: section / subsection / note printers                       │
    // └─────────────────────────────────────────────────────────────────────┘

    /// The fixed character width used for formatting output banners and sections.
    static let W = 78  // output width

    /// Prints a top-level banner with a double-line box around the title.
    static func banner(_ title: String) {
        let pad = max(0, W - title.count - 4)
        let left = pad / 2
        let right = pad - left
        print("")
        print("\u{2554}" + String(repeating: "\u{2550}", count: W) + "\u{2557}")
        print("\u{2551}" + String(repeating: " ", count: left) + "  " + title + String(repeating: " ", count: right) + "  \u{2551}")
        print("\u{255A}" + String(repeating: "\u{2550}", count: W) + "\u{255D}")
    }

    /// Prints a numbered section header with a single-line box.
    static func section(_ num: String, _ title: String) {
        print("")
        print("  \u{250C}" + String(repeating: "\u{2500}", count: W - 4) + "\u{2510}")
        print("  \u{2502}  \(num). \(title)" + String(repeating: " ", count: max(0, W - 8 - num.count - title.count)) + "\u{2502}")
        print("  \u{2514}" + String(repeating: "\u{2500}", count: W - 4) + "\u{2518}")
    }

    /// Prints a subsection header with a triangle marker and horizontal rule.
    static func sub(_ title: String) {
        print("\n  \u{25B6} \(title)")
        print("  " + String(repeating: "\u{2500}", count: W - 4))
    }

    /// Prints a code example label with an arrow marker.
    static func code(_ label: String) {
        print("    \u{25B8} \(label)")
    }

    /// Prints an indented note line with a vertical bar prefix.
    static func note(_ text: String) {
        print("    \u{2502} \(text)")
    }

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │  Sample data                                                        │
    // └─────────────────────────────────────────────────────────────────────┘

    /// Sample CSV data representing a 15-row employee dataset with columns:
    /// name, department, salary, age, years_experience, and performance_score.
    /// Used throughout the test suite as the primary test fixture.
    let employeeCSV = """
    name,department,salary,age,years_experience,performance_score
    Alice,Engineering,95000,32,8,4.5
    Bob,Marketing,72000,28,4,3.8
    Charlie,Engineering,105000,35,12,4.7
    Diana,Sales,68000,26,3,4.1
    Eve,Engineering,115000,40,16,4.9
    Frank,Marketing,75000,31,6,3.5
    Grace,Sales,71000,29,5,4.3
    Hank,Engineering,98000,33,9,4.2
    Ivy,Marketing,80000,34,10,4.0
    Jack,Sales,65000,25,2,3.6
    Kate,Engineering,110000,38,14,4.8
    Leo,Sales,69000,27,4,3.9
    Mia,Marketing,78000,30,7,4.1
    Noah,Engineering,102000,36,11,4.6
    Olivia,Sales,73000,31,6,4.4
    """

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 0. TABLE OF CONTENTS
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Prints the full API table of contents covering all SwiftPandas modules.
    /// Named with "AA" prefix to ensure it runs first alphabetically.
    func testAA_TableOfContents() {
        Self.banner("SWIFTPANDAS \(SwiftPandas.version) \u{2014} API REFERENCE")

        print("""

          Table of Contents
          \(String(repeating: "\u{2500}", count: 68))

          1. Series \u{2014} 1D Labeled Array
             Construction          Series([Double]), Series(dict), ...
             Properties            count, dtype, isNumeric, name, index
             Indexing              s[i], iloc, loc, head, tail
             NA Handling           isNA, dropNA, fillNA
             Aggregations          sum, mean, std, min, max, median, quantile
             Describe              describe, valueCounts
             Arithmetic            + \u{2212} * / (element-wise & scalar)
             Comparison            > >= < <= eq ne strContains
             Apply & Map           apply, map (Double & String)
             Cumulative            cumsum
             Unique & Duplicates   unique, nUnique, duplicated, dropDuplicates
             Sorting               sortValues

          2. DataFrame \u{2014} 2D Labeled Table
             Construction          DataFrame(dict), DataFrame(columns:), readCSV
             Properties            rowCount, columnCount, shape, dtypes
             Column Access         df["col"], select, drop, rename, set
             Row Access            iloc, loc, head, tail
             Boolean Filtering     df[mask], filter(mask:)
             Sorting               sortValues (single & multi-column)
             Aggregations          sum, mean, std, min, max, median, describe
             Duplicates            duplicated, dropDuplicates
             Apply                 apply (per-column transform)

          3. GroupBy \u{2014} Split-Apply-Combine
             Single-Column         groupBy("col").mean/sum/count/min/max
             Multi-Column          groupBy(["col1","col2"])
             Group Inspection      .groups

          4. Merge & Concat \u{2014} Combining DataFrames
             Merge                 inner join, left join, right, outer
             Concat                DataFrame.concat (vertical stack)

          5. CSV I/O \u{2014} Read & Write
             Read                  readCSV(string), readCSV(path:)
             Write                 toCSV(), toCSV(path:)
             Custom Parser         CSVReader(separator:header:naValues:)
             Custom Writer         CSVWriter(separator:includeHeader:)

          6. Core Types \u{2014} Storage & Type System
             Column                double, string, bool, int64
             DType System          Int8..Int64, UInt8..UInt64, Float32/64, Bool, String
             BitVector             1-bit validity bitmap, &, |, ~
             NativeArray<T>        contiguous typed storage with CoW
             NullableArray<T>      NativeArray + BitVector for NA
             StringArray           string storage with NA support

          7. Index Types \u{2014} Label Management
             RangeIndex            memory-efficient integer range
             StringIndex           hash-backed string label lookup
             Int64Index            integer label lookup

          8. End-to-End Pipeline Demo
             Load \u{2192} Describe \u{2192} GroupBy \u{2192} Filter \u{2192} Sort \u{2192} Transform \u{2192} Merge \u{2192} Concat \u{2192} CSV

          \(String(repeating: "\u{2500}", count: 68))
        """)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 1. SERIES — 1D Labeled Array
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests the Series API: construction, properties, indexing,
    /// NA handling, aggregations, arithmetic, comparisons, apply/map, cumulative
    /// operations, unique/duplicate handling, and sorting.
    func testSeriesDocumentation() {
        Self.section("1", "Series \u{2014} 1D Labeled Array")

        // --- Construction ---
        Self.sub("Construction")

        Self.code("Series([Double]) \u{2014} from array of doubles")
        let s1 = Series([10, 20, 30, 40, 50], name: "values")
        print(s1)

        Self.code("Series([Double?]) \u{2014} with missing values (NA)")
        let s2 = Series([1.0, nil, 3.0, nil, 5.0], name: "sparse")
        print(s2)

        Self.code("Series([String]) \u{2014} string series")
        let s3 = Series(["apple", "banana", "cherry"], name: "fruits")
        print(s3)

        Self.code("Series([String?]) \u{2014} strings with NA")
        let s4 = Series(["a", nil, "c", "d"], name: "letters")
        print(s4)

        Self.code("Series([Int]) \u{2014} from integers")
        let s5 = Series([100, 200, 300], name: "ints")
        print(s5)

        Self.code("Series(dict) \u{2014} from dictionary (sorted by key)")
        let s6 = Series(["x": 1.0, "y": 2.0, "z": 3.0], name: "coords")
        print(s6)

        Self.code("Series(data:index:name:) \u{2014} with custom index labels")
        let s7 = Series(data: .fromDoubles([100, 200, 300]), index: ["mon", "tue", "wed"], name: "revenue")
        print(s7)

        // --- Properties ---
        Self.sub("Properties")
        let s = Series([10.0, 20, nil, 40, 50], name: "demo")
        Self.note("s.count          = \(s.count)")
        Self.note("s.validCount     = \(s.validCount)")
        Self.note("s.naCount        = \(s.naCount)")
        Self.note("s.dtype          = \(s.dtype)")
        Self.note("s.isNumeric      = \(s.isNumeric)")
        Self.note("s.name           = \(s.name ?? "nil")")
        Self.note("s.index          = \(s.index)")
        Self.note("s.doubleValues   = \(s.doubleValues ?? [])")

        // --- Indexing ---
        Self.sub("Indexing & Slicing")

        Self.code("s[i] / s.iloc(i) \u{2014} access by integer position")
        Self.note("s[0] = \(s[0] ?? "nil" as Any)")
        Self.note("s[2] = \(s[2] ?? "nil" as Any) (NA)")

        Self.code("s.iloc(Range) \u{2014} slice by position range")
        print(s.iloc(1..<4))

        Self.code("s.loc(label) \u{2014} access by index label")
        let labeled = Series(data: .fromDoubles([10, 20, 30]), index: ["a", "b", "c"], name: "lbl")
        Self.note("labeled.loc(\"b\") = \(labeled.loc("b") ?? "nil" as Any)")

        Self.code("s.head(n) / s.tail(n)")
        print(Series([1,2,3,4,5,6,7,8,9,10.0], name: "nums").head(3))
        print(Series([1,2,3,4,5,6,7,8,9,10.0], name: "nums").tail(3))

        // --- NA handling ---
        Self.sub("Missing Value (NA) Handling")

        Self.code("s.isNA() \u{2014} boolean mask of missing values")
        Self.note("isNA = \(s.isNA())")

        Self.code("s.dropNA() \u{2014} remove missing values")
        print(s.dropNA())

        Self.code("s.fillNA(value) \u{2014} replace NA with a value")
        print(s.fillNA(0))

        // --- Aggregations ---
        Self.sub("Aggregations & Statistics")
        let agg = Series([10, 20, 30, 40, 50.0], name: "data")
        Self.note("sum()      = \(agg.sum() ?? .nan)")
        Self.note("mean()     = \(agg.mean() ?? .nan)")
        Self.note("std()      = \(String(format: "%.4f", agg.std() ?? .nan))")
        Self.note("min()      = \(agg.min() ?? .nan)")
        Self.note("max()      = \(agg.max() ?? .nan)")
        Self.note("median()   = \(agg.median() ?? .nan)")
        Self.note("quantile(0.25) = \(agg.quantile(0.25) ?? .nan)")
        Self.note("quantile(0.75) = \(agg.quantile(0.75) ?? .nan)")

        Self.code("s.describe() \u{2014} summary statistics")
        print(agg.describe())

        Self.code("s.valueCounts() \u{2014} frequency of each value")
        let vc = Series([1, 2, 2, 3, 3, 3.0], name: "freq")
        print(vc.valueCounts())

        // --- Arithmetic ---
        Self.sub("Arithmetic Operations")
        let a = Series([10, 20, 30.0], name: "a")
        let b = Series([1, 2, 3.0], name: "b")

        Self.code("Series + Series  (element-wise)")
        print(a + b)

        Self.code("Series - Series")
        print(a - b)

        Self.code("Series * Series")
        print(a * b)

        Self.code("Series / Series")
        print(a / b)

        Self.code("Series + scalar")
        print(a + 100.0)

        Self.code("Series - scalar")
        print(a - 5.0)

        Self.code("Series * scalar")
        print(a * 2.0)

        Self.code("Series / scalar")
        print(a / 10.0)

        // --- Comparison ---
        Self.sub("Comparison Operators (return [Bool] masks)")
        let vals = Series([10, 20, 30, 40, 50.0], name: "vals")

        Self.code("s > 25.0")
        Self.note("\(vals > 25.0)")

        Self.code("s >= 30.0")
        Self.note("\(vals >= 30.0)")

        Self.code("s < 30.0")
        Self.note("\(vals < 30.0)")

        Self.code("s <= 30.0")
        Self.note("\(vals <= 30.0)")

        Self.code("s.eq(30.0)")
        Self.note("\(vals.eq(30.0))")

        Self.code("s.ne(30.0)")
        Self.note("\(vals.ne(30.0))")

        Self.code("s.eq(\"string\") / s.ne(\"string\") \u{2014} string equality")
        let fruits = Series(["apple", "banana", "apple", "cherry"], name: "fruit")
        Self.note("eq(\"apple\") = \(fruits.eq("apple"))")

        Self.code("s.strContains(substring) \u{2014} string contains check")
        Self.note("strContains(\"an\") = \(fruits.strContains("an"))")

        // --- Apply / Map ---
        Self.sub("Apply & Map")

        Self.code("s.apply { $0 * 2 } \u{2014} transform each element")
        print(Series([1, 2, 3.0], name: "x").apply { $0 * 2 })

        Self.code("s.map(dict) \u{2014} remap values via dictionary (Double)")
        let mapped = Series([1, 2, 3, 1.0], name: "codes").map([1.0: 10.0, 2.0: 20.0, 3.0: 30.0])
        print(mapped)

        Self.code("s.map(dict) \u{2014} remap string values")
        let strMapped = Series(["a", "b", "c", "a"], name: "grades").map(["a": "Alpha", "b": "Beta"])
        print(strMapped)

        // --- Cumulative ---
        Self.sub("Cumulative Operations")

        Self.code("s.cumsum() \u{2014} cumulative sum")
        print(Series([1, 2, 3, 4, 5.0], name: "x").cumsum())

        // --- Unique / Duplicates ---
        Self.sub("Unique Values & Duplicates")
        let dupes = Series([1, 2, 2, 3, 3, 3.0], name: "dupes")

        Self.code("s.unique() \u{2014} unique values")
        print(dupes.unique())

        Self.code("s.nUnique \u{2014} count of unique values")
        Self.note("nUnique = \(dupes.nUnique)")

        Self.code("s.duplicated() \u{2014} mask of duplicate values")
        Self.note("duplicated = \(dupes.duplicated())")

        Self.code("s.dropDuplicates()")
        print(dupes.dropDuplicates())

        // --- Sorting ---
        Self.sub("Sorting")
        Self.code("s.sortValues(ascending:)")
        print(Series([30, 10, 50, 20, 40.0], name: "unsorted").sortValues())
        print(Series([30, 10, 50, 20, 40.0], name: "unsorted").sortValues(ascending: false))

        // Assertions
        XCTAssertEqual(s1.count, 5)
        XCTAssertEqual(s2.naCount, 2)
        XCTAssertEqual(agg.sum(), 150.0)
        XCTAssertEqual(agg.median(), 30.0)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 2. DATAFRAME — 2D Labeled Table
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests the DataFrame API: construction from dictionaries,
    /// typed columns, records, and CSV; properties; column/row access; boolean
    /// filtering; sorting (single and multi-column); aggregations; duplicates; and apply.
    func testDataFrameDocumentation() {
        Self.section("2", "DataFrame \u{2014} 2D Labeled Table")

        // --- Construction ---
        Self.sub("Construction")

        Self.code("DataFrame([String: [Double]]) \u{2014} from dictionary of arrays")
        let df1 = DataFrame(["x": [1, 2, 3.0], "y": [4, 5, 6.0]])
        print(df1)

        Self.code("DataFrame([String: [Double?]]) \u{2014} with missing values")
        let df2 = DataFrame(["a": [1.0, nil, 3.0], "b": [nil, 5.0, 6.0]])
        print(df2)

        Self.code("DataFrame(columns:index:) \u{2014} from typed columns with labels")
        let df3 = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie"])),
            ("age", Column.fromDoubles([30, 25, 35])),
            ("active", Column.fromBools([true, false, true]))
        ], index: ["r0", "r1", "r2"])
        print(df3)

        Self.code("DataFrame(records:) \u{2014} from array of dictionaries")
        let df4 = DataFrame(records: [
            ["x": 1, "y": 10],
            ["x": 2, "y": 20],
            ["x": 3, "y": 30],
        ])
        print(df4)

        Self.code("DataFrame.readCSV() \u{2014} from CSV string")
        let df = DataFrame.readCSV(employeeCSV)
        print(df.head())

        // --- Properties ---
        Self.sub("Properties")
        Self.note("df.rowCount      = \(df.rowCount)")
        Self.note("df.columnCount   = \(df.columnCount)")
        Self.note("df.shape         = \(df.shape)")
        Self.note("df.isEmpty       = \(df.isEmpty)")
        Self.note("df.columnNames   = \(df.columnNames)")
        Self.note("df.dtypes:")
        for dt in df.dtypes {
            Self.note("  \(dt.name): \(dt.dtype)")
        }

        // --- Column access ---
        Self.sub("Column Access")

        Self.code("df[\"col\"] \u{2014} get a column as Series")
        print(df["salary"].head(5))

        Self.code("df.select(columns:) \u{2014} select multiple columns")
        print(df.select(columns: ["name", "salary"]).head(5))

        Self.code("df.drop(columns:) \u{2014} drop columns")
        print(df.drop(columns: ["age", "years_experience", "performance_score"]).head(3))

        Self.code("df.rename(columns:) \u{2014} rename columns")
        print(df.select(columns: ["name", "salary"]).rename(columns: ["name": "employee", "salary": "pay"]).head(3))

        Self.code("df[\"new_col\"] = series \u{2014} add/set a column")
        var dfMut = DataFrame(["x": [1, 2, 3.0]])
        dfMut["doubled"] = Series([2, 4, 6.0], name: "doubled")
        print(dfMut)

        // --- Row access ---
        Self.sub("Row Access")

        Self.code("df.iloc(position) \u{2014} single row by integer")
        let row = df.iloc(0)
        Self.note("iloc(0) = \(row)")

        Self.code("df.iloc(range) \u{2014} rows by integer range")
        print(df.iloc(2..<5))

        Self.code("df.head(n) / df.tail(n)")
        print(df.head(3))

        Self.code("df.loc(label) \u{2014} single row by index label")
        let r = df.loc("0")
        Self.note("loc(\"0\") = \(r ?? [:])")

        Self.code("df.loc([labels]) \u{2014} multiple rows by label")
        print(df.loc(["0", "2", "4"]))

        // --- Filtering ---
        Self.sub("Boolean Filtering")

        Self.code("df[df[\"col\"] > value] \u{2014} pandas-style boolean indexing")
        let highSalary = df[df["salary"] > 100000.0]
        print(highSalary.select(columns: ["name", "department", "salary"]))

        Self.code("df.filter(mask:) \u{2014} explicit mask filtering")
        let mask = df["performance_score"] >= 4.5
        let stars = df.filter(mask: mask)
        print(stars.select(columns: ["name", "performance_score"]))

        // --- Sorting ---
        Self.sub("Sorting")

        Self.code("df.sortValues(by:ascending:) \u{2014} single column sort")
        print(df.sortValues(by: "salary", ascending: false).select(columns: ["name", "salary"]).head(5))

        Self.code("df.sortValues(by:[cols],ascending:[flags]) \u{2014} multi-column sort")
        print(df.sortValues(by: ["department", "salary"], ascending: [true, false]).select(columns: ["name", "department", "salary"]).head(8))

        // --- Aggregations ---
        Self.sub("Aggregations")
        let numDf = df.select(columns: ["salary", "age", "performance_score"])

        Self.code("df.sum()")
        print(numDf.sum())

        Self.code("df.mean()")
        print(numDf.mean())

        Self.code("df.std()")
        print(numDf.std())

        Self.code("df.min()")
        print(numDf.min())

        Self.code("df.max()")
        print(numDf.max())

        Self.code("df.median()")
        print(numDf.median())

        Self.code("df.describe() \u{2014} full summary statistics with quartiles")
        print(df.describe())

        // --- Duplicates ---
        Self.sub("Duplicates")
        let dupeDf = DataFrame(columns: [
            ("name", Column.fromStrings(["A", "B", "A", "C", "B"])),
            ("val", Column.fromDoubles([1, 2, 1, 3, 2]))
        ])

        Self.code("df.duplicated(subset:) \u{2014} boolean mask of duplicate rows")
        Self.note("duplicated = \(dupeDf.duplicated())")

        Self.code("df.dropDuplicates(subset:)")
        print(dupeDf.dropDuplicates())

        // --- Apply ---
        Self.sub("Apply")

        Self.code("df.apply { series in ... } \u{2014} apply function to each column")
        let normalized = df.select(columns: ["salary", "age"]).apply { s in
            guard let mean = s.mean(), let std = s.std(), std > 0 else { return s }
            return (s - mean) / std
        }
        print(normalized.head(5))

        // Assertions
        XCTAssertEqual(df.rowCount, 15)
        XCTAssertEqual(highSalary.rowCount, 4) // Charlie, Eve, Kate, Noah
        XCTAssertEqual(stars.rowCount, 5)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 3. GROUPBY — Split-Apply-Combine
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests GroupBy split-apply-combine operations: single-column
    /// grouping with all five aggregation functions, group inspection via `.groups`,
    /// and multi-column grouping with composite keys.
    func testGroupByDocumentation() {
        Self.section("3", "GroupBy \u{2014} Split-Apply-Combine")
        let df = DataFrame.readCSV(employeeCSV)

        // --- Single column groupby ---
        Self.sub("Single-Column GroupBy")

        Self.code("df.groupBy(\"department\").mean()")
        let grouped = df.select(columns: ["department", "salary", "age", "performance_score"]).groupBy("department")
        print(grouped.mean())

        Self.code("df.groupBy(\"department\").sum()")
        print(grouped.sum())

        Self.code("df.groupBy(\"department\").count()")
        print(grouped.count())

        Self.code("df.groupBy(\"department\").min()")
        print(grouped.min())

        Self.code("df.groupBy(\"department\").max()")
        print(grouped.max())

        Self.code(".groups \u{2014} inspect group keys and row indices")
        for (key, indices) in grouped.groups.sorted(by: { $0.key < $1.key }) {
            Self.note("\(key): rows \(indices)")
        }

        // --- Multi-column groupby ---
        Self.sub("Multi-Column GroupBy")

        // Add a region-like column by splitting employees
        var dfWithRegion = df
        let regions = ["West","East","West","East","West","East","West","East","West","East","West","East","West","East","West"]
        dfWithRegion["region"] = Series(regions, name: "region")

        Self.code("df.groupBy([\"department\", \"region\"]).mean()")
        let multiGrouped = dfWithRegion.select(columns: ["department", "region", "salary"]).groupBy(["department", "region"])
        print(multiGrouped.mean())

        // Assertions
        let countDf = grouped.count()
        let engIdx = countDf.indexLabels.firstIndex(of: "Engineering")!
        XCTAssertEqual(countDf["salary"].iloc(engIdx) as? Double, 6.0)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 4. MERGE & CONCAT
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests merge (inner/left join) and concat (vertical stack)
    /// operations for combining multiple DataFrames.
    func testMergeConcatDocumentation() {
        Self.section("4", "Merge & Concat \u{2014} Combining DataFrames")

        // --- Merge ---
        Self.sub("Merge (Join)")

        let employees = DataFrame(columns: [
            ("emp_id", Column.fromDoubles([1, 2, 3, 4])),
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana"])),
            ("dept_id", Column.fromDoubles([10, 20, 10, 30]))
        ])

        let departments = DataFrame(columns: [
            ("dept_id", Column.fromDoubles([10, 20, 30])),
            ("dept_name", Column.fromStrings(["Engineering", "Marketing", "Sales"]))
        ])

        Self.code("df.merge(right, on: key) \u{2014} inner join (default)")
        print(employees.merge(departments, on: "dept_id"))

        Self.code("df.merge(right, on: key, how: .left) \u{2014} left join")
        let leftJoined = employees.merge(departments, on: "dept_id", how: .left)
        print(leftJoined)

        // --- Concat ---
        Self.sub("Concat (Vertical Stack)")

        let q1 = DataFrame(columns: [
            ("quarter", Column.fromStrings(["Q1", "Q1", "Q1"])),
            ("revenue", Column.fromDoubles([100, 200, 150]))
        ])
        let q2 = DataFrame(columns: [
            ("quarter", Column.fromStrings(["Q2", "Q2", "Q2"])),
            ("revenue", Column.fromDoubles([120, 210, 180]))
        ])

        Self.code("DataFrame.concat([df1, df2]) \u{2014} stack vertically")
        print(DataFrame.concat([q1, q2]))

        // Assertions
        let merged = employees.merge(departments, on: "dept_id")
        XCTAssertEqual(merged.rowCount, 4)
        XCTAssertEqual(DataFrame.concat([q1, q2]).rowCount, 6)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 5. CSV I/O
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests CSV I/O: reading from strings and files, custom parser
    /// configuration (separators, headers, NA values), writing to strings and files,
    /// custom writer settings, and round-trip data integrity verification.
    func testCSVDocumentation() {
        Self.section("5", "CSV I/O \u{2014} Read & Write")

        // --- Read ---
        Self.sub("Reading CSV")

        Self.code("DataFrame.readCSV(string) \u{2014} parse CSV from string")
        let df = DataFrame.readCSV(employeeCSV)
        Self.note("Loaded \(df.rowCount) rows x \(df.columnCount) columns")
        print(df.head(3))

        Self.code("DataFrame.readCSV(path:) \u{2014} parse CSV from file")
        Self.note("let df = try DataFrame.readCSV(path: \"/path/to/file.csv\")")

        Self.code("CSVReader(separator:header:naValues:) \u{2014} custom parser")
        Self.note("Supports: custom separators, header toggle, configurable NA values")
        Self.note("NA values: \"\", \"NA\", \"N/A\", \"NaN\", \"nan\", \"null\", \"NULL\", \"None\", \".\"")

        // --- Write ---
        Self.sub("Writing CSV")

        Self.code("df.toCSV() \u{2014} write to string")
        let csv = df.head(3).toCSV()
        print("    Output:\n    " + csv.replacingOccurrences(of: "\n", with: "\n    "))

        Self.code("df.toCSV(path:) \u{2014} write to file")
        Self.note("try df.toCSV(path: \"/path/to/output.csv\")")

        Self.code("CSVWriter(separator:includeHeader:includeIndex:naRepresentation:)")
        Self.note("Full control over CSV output format")

        // --- Round-trip ---
        Self.sub("Round-Trip Verification")
        let csvOut = df.toCSV()
        let dfBack = DataFrame.readCSV(csvOut)
        Self.note("Original:   \(df.shape)")
        Self.note("Round-trip:  \(dfBack.shape)")
        Self.note("Salary sum matches: \(abs(df["salary"].sum()! - dfBack["salary"].sum()!) < 0.01)")

        // Assertions
        XCTAssertEqual(df.rowCount, dfBack.rowCount)
        XCTAssertEqual(df.columnCount, dfBack.columnCount)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 6. CORE TYPES
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests core storage types: Column (type-erased storage with
    /// factory methods), DType system (numeric, boolean, string types), BitVector
    /// (1-bit validity bitmap with bitwise operators), NativeArray (contiguous
    /// typed storage with CoW), NullableArray (NativeArray + BitVector for NA),
    /// and StringArray (string storage with NA support).
    func testCoreTypesDocumentation() {
        Self.section("6", "Core Types \u{2014} Storage & Type System")

        // --- Column types ---
        Self.sub("Column (Type-Erased Storage)")
        Self.note("Column.double(NullableArray<Double>)  \u{2014} numeric data")
        Self.note("Column.string(StringArray)            \u{2014} text data")
        Self.note("Column.bool(NullableArray<Bool>)      \u{2014} boolean data")
        Self.note("Column.int64(NullableArray<Int64>)    \u{2014} integer data")

        Self.code("Column factory methods")
        let c1 = Column.fromDoubles([1, 2, 3])
        let c2 = Column.fromOptionalDoubles([1.0, nil, 3.0])
        let c3 = Column.fromStrings(["a", "b", "c"])
        let c4 = Column.fromBools([true, false, true])
        let c5 = Column.fromInts([10, 20, 30])

        Self.note("fromDoubles:       dtype=\(c1.dtype), count=\(c1.count)")
        Self.note("fromOptionalDoubles: dtype=\(c2.dtype), naCount=\(c2.naCount)")
        Self.note("fromStrings:       dtype=\(c3.dtype)")
        Self.note("fromBools:         dtype=\(c4.dtype)")
        Self.note("fromInts:          dtype=\(c5.dtype)")

        // --- DType system ---
        Self.sub("DType System")
        Self.note("Numeric:  Int8, Int16, Int32, Int64, UInt8..UInt64, Float32, Float64")
        Self.note("Other:    Bool, String, Datetime, Timedelta")
        Self.note("")

        let dtypes: [DTypeEnum] = [.int8, .int16, .int32, .int64, .float32, .float64, .bool, .string]
        for dt in dtypes {
            Self.note("  \(dt)  isNumeric=\(dt.isNumeric)  isInteger=\(dt.isInteger)  isFloat=\(dt.isFloat)")
        }

        // --- BitVector ---
        Self.sub("BitVector (1-bit-per-element validity bitmap)")
        let bv = BitVector([true, true, false, true, false])
        Self.note("BitVector([true, true, false, true, false])")
        Self.note("  bitCount  = \(bv.bitCount)")
        Self.note("  popcount  = \(bv.popcount)")
        Self.note("  naCount   = \(bv.naCount)")
        Self.note("  allValid  = \(bv.allValid)")
        Self.note("  boolArray = \(bv.boolArray)")

        Self.code("Bitwise operators: &, |, ~")
        let bv2 = BitVector([false, true, true, false, true])
        Self.note("bv & bv2 = \((bv & bv2).boolArray)")
        Self.note("bv | bv2 = \((bv | bv2).boolArray)")
        Self.note("~bv      = \((~bv).boolArray)")

        // --- NativeArray ---
        Self.sub("NativeArray<T> (contiguous typed storage with CoW)")
        let na = NativeArray([10.0, 20.0, 30.0, 40.0, 50.0])
        Self.note("NativeArray([10, 20, 30, 40, 50])")
        Self.note("  count  = \(na.count)")
        Self.note("  sum()  = \(na.sum())")
        Self.note("  mean() = \(na.mean())")
        Self.note("  min()  = \(na.min() ?? .nan)")
        Self.note("  max()  = \(na.max() ?? .nan)")
        Self.note("  std()  = \(String(format: "%.4f", na.std()))")

        // --- NullableArray ---
        Self.sub("NullableArray<T> (NativeArray + BitVector for NA)")
        let nullable = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        Self.note("NullableArray([1.0, nil, 3.0, nil, 5.0])")
        Self.note("  count      = \(nullable.count)")
        Self.note("  validCount = \(nullable.validCount)")
        Self.note("  naCount    = \(nullable.naCount)")
        Self.note("  hasNAs     = \(nullable.hasNAs)")
        Self.note("  sum()      = \(nullable.sum() ?? .nan)")
        Self.note("  mean()     = \(nullable.mean() ?? .nan)")

        // --- StringArray ---
        Self.sub("StringArray (string storage with NA)")
        let sa = StringArray(["hello", nil, "world", "swift", nil])
        Self.note("StringArray([\"hello\", nil, \"world\", \"swift\", nil])")
        Self.note("  count      = \(sa.count)")
        Self.note("  validCount = \(sa.validCount)")
        Self.note("  naCount    = \(sa.naCount)")
        Self.note("  unique     = \(sa.unique())")

        // Assertions
        XCTAssertEqual(bv.popcount, 3)
        XCTAssertEqual(nullable.validCount, 3)
        XCTAssertEqual(sa.naCount, 2)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 7. INDEX TYPES
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Documents and tests index types: RangeIndex (memory-efficient integer range),
    /// StringIndex (hash-backed string label lookup), and Int64Index (integer label lookup).
    func testIndexDocumentation() {
        Self.section("7", "Index Types \u{2014} Label Management")

        Self.sub("RangeIndex (memory-efficient integer range)")
        let ri = RangeIndex(10)
        Self.note("RangeIndex(10): start=\(ri.start), stop=\(ri.stop), step=\(ri.step), count=\(ri.count)")
        let ri2 = RangeIndex(start: 0, stop: 20, step: 5)
        Self.note("RangeIndex(0, 20, step=5): values=\(ri2.values)")

        Self.sub("StringIndex (hash-backed label lookup)")
        let si = StringIndex(["mon", "tue", "wed", "thu", "fri"])
        Self.note("StringIndex: count=\(si.count), isUnique=\(si.isUnique)")
        Self.note("getLocation(\"wed\") = \(si.getLocation(of: "wed") ?? -1)")
        Self.note("contains(\"sat\") = \(si.contains("sat"))")

        Self.sub("Int64Index (integer label lookup)")
        let ii = Int64Index(ints: [100, 200, 300, 400])
        Self.note("Int64Index: count=\(ii.count)")
        Self.note("getLocation(200) = \(ii.getLocation(of: 200) ?? -1)")

        // Assertions
        XCTAssertEqual(ri.count, 10)
        XCTAssertEqual(si.getLocation(of: "wed"), 2)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - 8. FULL PIPELINE DEMO
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Runs an end-to-end pipeline demo: load CSV, inspect, describe, GroupBy,
    /// filter, sort, transform (salary per year), merge with department budgets,
    /// concat quarterly reports, and CSV round-trip verification.
    func testFullPipelineDocumentation() {
        Self.section("8", "End-to-End Pipeline Demo")
        let df = DataFrame.readCSV(employeeCSV)

        Self.sub("Step 1: Load & Inspect")
        Self.note("\(df.rowCount) rows x \(df.columnCount) columns")
        Self.note("Columns: \(df.columnNames.joined(separator: ", "))")
        print(df.head(5))

        Self.sub("Step 2: Summary Statistics")
        print(df.describe())

        Self.sub("Step 3: GroupBy Department \u{2192} Average Salary")
        print(df.select(columns: ["department", "salary"]).groupBy("department").mean())

        Self.sub("Step 4: Filter \u{2192} Senior Employees (experience > 8)")
        let seniors = df[df["years_experience"] > 8.0]
        print(seniors.select(columns: ["name", "department", "salary", "years_experience"]))

        Self.sub("Step 5: Sort \u{2192} Top 5 by Performance")
        let top5 = df.sortValues(by: "performance_score", ascending: false).head(5)
        print(top5.select(columns: ["name", "department", "performance_score", "salary"]))

        Self.sub("Step 6: Transform \u{2192} Salary per Year of Experience")
        var transformed = df.select(columns: ["name", "department", "salary", "years_experience"])
        transformed["salary_per_yr"] = df["salary"] / df["years_experience"]
        print(transformed.sortValues(by: "salary_per_yr", ascending: false).head(5))

        Self.sub("Step 7: Merge \u{2192} Join with Department Budgets")
        let budgets = DataFrame(columns: [
            ("department", Column.fromStrings(["Engineering", "Marketing", "Sales"])),
            ("budget", Column.fromDoubles([500000, 300000, 250000]))
        ])
        let withBudget = df.select(columns: ["name", "department", "salary"])
            .merge(budgets, on: "department")
        print(withBudget.head(5))

        Self.sub("Step 8: Concat \u{2192} Combine Quarterly Reports")
        let q1 = df.head(5).select(columns: ["name", "salary"])
        let q2 = df.tail(5).select(columns: ["name", "salary"])
        let combined = DataFrame.concat([q1, q2])
        print(combined)

        Self.sub("Step 9: CSV Round-Trip")
        let csvOut = df.toCSV()
        let dfBack = DataFrame.readCSV(csvOut)
        Self.note("Write \u{2192} Read: \(df.shape) \u{2192} \(dfBack.shape)")
        Self.note("Data integrity: \(abs(df["salary"].sum()! - dfBack["salary"].sum()!) < 0.01 ? "PASS" : "FAIL")")

        print("\n  " + String(repeating: "\u{2550}", count: Self.W - 4))
        print("  SwiftPandas \(SwiftPandas.version) \u{2014} All demos complete.")
        print("  " + String(repeating: "\u{2550}", count: Self.W - 4))

        // Assertions
        XCTAssertEqual(df.rowCount, 15)
        XCTAssertEqual(seniors.rowCount, 6)
        XCTAssertEqual(top5.rowCount, 5)
        XCTAssertEqual(withBudget.rowCount, 15)
        XCTAssertEqual(combined.rowCount, 10)
        XCTAssertEqual(df.rowCount, dfBack.rowCount)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - File I/O test (kept for resource bundle validation)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Tests loading a CSV file from the test resource bundle to validate
    /// that file-based CSV reading works with both Swift Package Manager
    /// and Xcode bundle resource layouts.
    func testLoadCSVFromFile() throws {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        let csvURL = bundle.url(forResource: "employees", withExtension: "csv", subdirectory: "SampleData")
        #else
        let bundle = Bundle(for: type(of: self))
        let csvURL = bundle.url(forResource: "employees", withExtension: "csv", subdirectory: "SampleData")
            ?? bundle.url(forResource: "employees", withExtension: "csv")
        #endif
        guard let csvURL else {
            XCTFail("Sample CSV file not found in test bundle")
            return
        }
        let df = try DataFrame.readCSV(path: csvURL.path)
        XCTAssertEqual(df.rowCount, 15)
        XCTAssertEqual(df.columnCount, 6)
    }
}
