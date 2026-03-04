import XCTest
@testable import SwiftPandas

final class SwiftPandasTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(SwiftPandas.version, "0.1.0")
    }
}

// MARK: - DType Tests

final class DTypeTests: XCTestCase {
    func testDTypeNames() {
        XCTAssertEqual(Int64DType().name, "int64")
        XCTAssertEqual(Float64DType().name, "float64")
        XCTAssertEqual(StringDType().name, "string")
        XCTAssertEqual(BoolDType().name, "bool")
    }

    func testDTypeCategories() {
        XCTAssertTrue(Int64DType().isSignedInteger)
        XCTAssertTrue(Int64DType().isNumeric)
        XCTAssertFalse(Int64DType().isFloat)

        XCTAssertTrue(UInt32DType().isUnsignedInteger)
        XCTAssertTrue(UInt32DType().isNumeric)
        XCTAssertTrue(UInt32DType().isInteger)

        XCTAssertTrue(Float64DType().isFloat)
        XCTAssertTrue(Float64DType().isNumeric)
        XCTAssertFalse(Float64DType().isInteger)

        XCTAssertTrue(BoolDType().isBoolean)
        XCTAssertFalse(BoolDType().isNumeric)

        XCTAssertFalse(StringDType().isNumeric)
    }

    func testDTypeEnum() {
        XCTAssertEqual(DTypeEnum.float64.description, "float64")
        XCTAssertTrue(DTypeEnum.int32.isInteger)
        XCTAssertTrue(DTypeEnum.float64.isFloat)
        XCTAssertFalse(DTypeEnum.string.isNumeric)
    }
}

// MARK: - NativeArray Tests

final class NativeArrayTests: XCTestCase {
    func testCreation() {
        let a = NativeArray<Double>([1.0, 2.0, 3.0])
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a[0], 1.0)
        XCTAssertEqual(a[1], 2.0)
        XCTAssertEqual(a[2], 3.0)
    }

    func testCopyOnWrite() {
        var a = NativeArray<Double>([1.0, 2.0, 3.0])
        let b = a  // shares storage
        a[0] = 99.0  // triggers CoW copy
        XCTAssertEqual(a[0], 99.0)
        XCTAssertEqual(b[0], 1.0)  // b is unmodified
    }

    func testArithmetic() {
        let a = NativeArray<Double>([1.0, 2.0, 3.0])
        let b = NativeArray<Double>([4.0, 5.0, 6.0])

        let sum = a + b
        XCTAssertEqual(sum.array, [5.0, 7.0, 9.0])

        let diff = b - a
        XCTAssertEqual(diff.array, [3.0, 3.0, 3.0])

        let prod = a * b
        XCTAssertEqual(prod.array, [4.0, 10.0, 18.0])

        let quot = b / a
        XCTAssertEqual(quot.array, [4.0, 2.5, 2.0])
    }

    func testReductions() {
        let a = NativeArray<Double>([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(a.sum(), 15.0)
        XCTAssertEqual(a.min(), 1.0)
        XCTAssertEqual(a.max(), 5.0)
        XCTAssertEqual(a.mean(), 3.0)
        XCTAssertEqual(a.std(ddof: 0), sqrt(2.0), accuracy: 1e-10)
    }

    func testArgsort() {
        let a = NativeArray<Double>([3.0, 1.0, 2.0])
        XCTAssertEqual(a.argsort(), [1, 2, 0])
        XCTAssertEqual(a.argsort(ascending: false), [0, 2, 1])
    }

    func testUnique() {
        let a = NativeArray<Int>([1, 2, 3, 2, 1])
        let u = a.unique()
        XCTAssertEqual(u.array, [1, 2, 3])
    }

    func testFactorize() {
        let a = NativeArray<String>(["cat", "dog", "cat", "bird", "dog"])
        let (codes, uniques) = a.factorize()
        XCTAssertEqual(codes, [0, 1, 0, 2, 1])
        XCTAssertEqual(uniques.array, ["cat", "dog", "bird"])
    }

    func testSlice() {
        let a = NativeArray<Double>([10.0, 20.0, 30.0, 40.0, 50.0])
        let s = a[1..<4]
        XCTAssertEqual(s.array, [20.0, 30.0, 40.0])
    }

    func testAppend() {
        var a = NativeArray<Int>([1, 2])
        a.append(3)
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a[2], 3)
    }

    func testCollection() {
        let a = NativeArray<Int>([1, 2, 3])
        let mapped = a.map { $0 * 2 }
        XCTAssertEqual(mapped, [2, 4, 6])
    }
}

// MARK: - BitVector Tests

final class BitVectorTests: XCTestCase {
    func testAllValid() {
        let bv = BitVector(repeating: true, count: 100)
        XCTAssertEqual(bv.popcount, 100)
        XCTAssertTrue(bv.allValid)
        XCTAssertEqual(bv.naCount, 0)
    }

    func testAllNA() {
        let bv = BitVector(repeating: false, count: 50)
        XCTAssertEqual(bv.popcount, 0)
        XCTAssertTrue(bv.allNA)
    }

    func testFromBools() {
        let bv = BitVector([true, false, true, false, true])
        XCTAssertEqual(bv.popcount, 3)
        XCTAssertTrue(bv[0])
        XCTAssertFalse(bv[1])
        XCTAssertTrue(bv[2])
    }

    func testMutation() {
        var bv = BitVector(repeating: true, count: 10)
        bv[3] = false
        bv[7] = false
        XCTAssertEqual(bv.popcount, 8)
        XCTAssertFalse(bv[3])
        XCTAssertFalse(bv[7])
    }

    func testBitwiseAnd() {
        let a = BitVector([true, true, false, false])
        let b = BitVector([true, false, true, false])
        let c = a & b
        XCTAssertEqual(c.boolArray, [true, false, false, false])
    }

    func testBitwiseOr() {
        let a = BitVector([true, true, false, false])
        let b = BitVector([true, false, true, false])
        let c = a | b
        XCTAssertEqual(c.boolArray, [true, true, true, false])
    }

    func testBitwiseNot() {
        let a = BitVector([true, false, true])
        let b = ~a
        XCTAssertEqual(b.boolArray, [false, true, false])
    }

    func testLargeBitVector() {
        let bv = BitVector(repeating: true, count: 1000)
        XCTAssertEqual(bv.popcount, 1000)
        XCTAssertEqual(bv.bitCount, 1000)
    }
}

// MARK: - NullableArray Tests

final class NullableArrayTests: XCTestCase {
    func testFromOptionals() {
        let a = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        XCTAssertEqual(a.count, 5)
        XCTAssertEqual(a.validCount, 3)
        XCTAssertEqual(a.naCount, 2)
        XCTAssertEqual(a[0], 1.0)
        XCTAssertNil(a[1])
        XCTAssertEqual(a[2], 3.0)
    }

    func testIsNA() {
        let a = NullableArray<Double>([1.0, nil, 3.0])
        XCTAssertEqual(a.isNA(), [false, true, false])
        XCTAssertEqual(a.notNA(), [true, false, true])
    }

    func testFillNA() {
        let a = NullableArray<Double>([1.0, nil, 3.0])
        let filled = a.fillNA(value: 0.0)
        XCTAssertEqual(filled.array, [1.0, 0.0, 3.0])
    }

    func testDropNA() {
        let a = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        let dropped = a.dropNA()
        XCTAssertEqual(dropped.array, [1.0, 3.0, 5.0])
    }

    func testArithmeticWithNAPropagation() {
        let a = NullableArray<Double>([1.0, nil, 3.0])
        let b = NullableArray<Double>([10.0, 20.0, nil])
        let sum = a + b
        XCTAssertEqual(sum[0], 11.0)
        XCTAssertNil(sum[1])   // NA + 20 = NA
        XCTAssertNil(sum[2])   // 3 + NA = NA
    }

    func testReductions() {
        let a = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        XCTAssertEqual(a.sum(), 9.0)
        XCTAssertEqual(a.mean(), 3.0)
        XCTAssertEqual(a.min(), 1.0)
        XCTAssertEqual(a.max(), 5.0)
    }

    func testFactorize() {
        let a = NullableArray<Int64>([1, nil, 2, 1, nil, 2])
        let (codes, uniques) = a.factorize()
        XCTAssertEqual(codes, [0, -1, 1, 0, -1, 1])
        XCTAssertEqual(uniques.array, [1, 2])
    }

    func testMutation() {
        var a = NullableArray<Double>([1.0, nil, 3.0])
        a[1] = 2.0
        XCTAssertEqual(a[1], 2.0)
        a[0] = nil
        XCTAssertNil(a[0])
    }
}

// MARK: - StringArray Tests

final class StringArrayTests: XCTestCase {
    func testCreation() {
        let a = StringArray(["hello", "world"])
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0], "hello")
    }

    func testWithNAs() {
        let a = StringArray(["a", nil, "c"])
        XCTAssertEqual(a.validCount, 2)
        XCTAssertNil(a[1])
        XCTAssertEqual(a.isNA(), [false, true, false])
    }

    func testUnique() {
        let a = StringArray(["a", "b", "a", "c", "b"])
        let u = a.unique()
        XCTAssertEqual(u.storage, ["a", "b", "c"])
    }

    func testFillNA() {
        let a = StringArray(["a", nil, "c"])
        let filled = a.fillNA(value: "NA")
        XCTAssertEqual(filled.storage, ["a", "NA", "c"])
    }

    func testDropNA() {
        let a = StringArray(["a", nil, "c"])
        XCTAssertEqual(a.dropNA(), ["a", "c"])
    }
}

// MARK: - Column Tests

final class ColumnTests: XCTestCase {
    func testDoubleColumn() {
        let col = Column.fromDoubles([1.0, 2.0, 3.0])
        XCTAssertEqual(col.dtype, .float64)
        XCTAssertEqual(col.count, 3)
        XCTAssertTrue(col.isNumeric)
        XCTAssertEqual(col.sum(), 6.0)
        XCTAssertEqual(col.mean(), 2.0)
    }

    func testStringColumn() {
        let col = Column.fromStrings(["a", "b", "c"])
        XCTAssertEqual(col.dtype, .string)
        XCTAssertFalse(col.isNumeric)
        XCTAssertEqual(col.count, 3)
    }

    func testColumnWithNAs() {
        let col = Column.fromOptionalDoubles([1.0, nil, 3.0])
        XCTAssertEqual(col.validCount, 2)
        XCTAssertEqual(col.naCount, 1)
        XCTAssertEqual(col.formattedValue(at: 1), "NA")
    }

    func testColumnAggregations() {
        let col = Column.fromOptionalDoubles([1.0, nil, 3.0, nil, 5.0])
        XCTAssertEqual(col.sum(), 9.0)
        XCTAssertEqual(col.mean(), 3.0)
        XCTAssertEqual(col.min(), 1.0)
        XCTAssertEqual(col.max(), 5.0)
    }

    func testTake() {
        let col = Column.fromDoubles([10.0, 20.0, 30.0, 40.0])
        let taken = col.take(indices: [3, 1, 0])
        XCTAssertEqual(taken.count, 3)
    }

    func testBoolColumn() {
        let col = Column.fromBools([true, false, true])
        XCTAssertEqual(col.dtype, .bool)
        XCTAssertEqual(col.count, 3)
    }
}

// MARK: - Index Tests

final class IndexTests: XCTestCase {
    func testRangeIndex() {
        let idx = RangeIndex(10)
        XCTAssertEqual(idx.count, 10)
        XCTAssertEqual(idx[0], 0)
        XCTAssertEqual(idx[9], 9)
        XCTAssertEqual(idx.getLocation(of: 5), 5)
        XCTAssertNil(idx.getLocation(of: 10))
        XCTAssertTrue(idx.isUnique)
    }

    func testStringIndex() {
        let idx = StringIndex(["a", "b", "c"])
        XCTAssertEqual(idx.count, 3)
        XCTAssertEqual(idx.getLocation(of: "b"), 1)
        XCTAssertNil(idx.getLocation(of: "d"))
        XCTAssertTrue(idx.isUnique)
    }

    func testInt64Index() {
        let idx = Int64Index([10, 20, 30])
        XCTAssertEqual(idx.count, 3)
        XCTAssertEqual(idx.getLocation(of: 20), 1)
        XCTAssertTrue(idx.contains(30))
        XCTAssertFalse(idx.contains(40))
    }
}

// MARK: - Series Tests

final class SeriesTests: XCTestCase {
    func testCreation() {
        let s = Series([1.0, 2.0, 3.0], name: "values")
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.name, "values")
        XCTAssertEqual(s.dtype, .float64)
    }

    func testFromDict() {
        let s = Series(["a": 1.0, "b": 2.0, "c": 3.0])
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.loc("b") as? Double, 2.0)
    }

    func testAggregations() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(s.sum(), 15.0)
        XCTAssertEqual(s.mean(), 3.0)
        XCTAssertEqual(s.min(), 1.0)
        XCTAssertEqual(s.max(), 5.0)
    }

    func testNAHandling() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s.validCount, 3)
        XCTAssertEqual(s.naCount, 2)
        XCTAssertEqual(s.sum(), 9.0)
    }

    func testDropNA() {
        let s = Series([1.0, nil, 3.0])
        let dropped = s.dropNA()
        XCTAssertEqual(dropped.count, 2)
    }

    func testFillNA() {
        let s = Series([1.0, nil, 3.0])
        let filled = s.fillNA(0.0)
        XCTAssertEqual(filled.sum(), 4.0)
        XCTAssertEqual(filled.naCount, 0)
    }

    func testHeadTail() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(s.head(3).count, 3)
        XCTAssertEqual(s.tail(2).count, 2)
    }

    func testArithmetic() {
        let a = Series([1.0, 2.0, 3.0])
        let b = Series([4.0, 5.0, 6.0])
        let sum = a + b
        XCTAssertEqual(sum.sum(), 21.0)
    }

    func testScalarArithmetic() {
        let s = Series([1.0, 2.0, 3.0])
        let doubled = s * 2.0
        XCTAssertEqual(doubled.sum(), 12.0)
    }

    func testValueCounts() {
        let s = Series(["a", "b", "a", "c", "b", "a"])
        let vc = s.valueCounts()
        XCTAssertEqual(vc.count, 3)
    }

    func testSortValues() {
        let s = Series([3.0, 1.0, 2.0])
        let sorted = s.sortValues()
        XCTAssertEqual(sorted.iloc(0) as? Double, 1.0)
        XCTAssertEqual(sorted.iloc(2) as? Double, 3.0)
    }

    func testDescribe() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let desc = s.describe()
        XCTAssertEqual(desc.count, 5) // count, mean, std, min, max
    }
}

// MARK: - DataFrame Tests

final class DataFrameTests: XCTestCase {
    func testCreation() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        XCTAssertEqual(df.shape.rows, 3)
        XCTAssertEqual(df.shape.columns, 2)
    }

    func testColumnAccess() {
        let df = DataFrame(["x": [1.0, 2.0], "y": [3.0, 4.0]])
        let s = df["x"]
        XCTAssertEqual(s.sum(), 3.0)
        XCTAssertEqual(s.name, "x")
    }

    func testColumnAssignment() {
        var df = DataFrame(["a": [1.0, 2.0, 3.0]])
        df["b"] = Series([4.0, 5.0, 6.0])
        XCTAssertEqual(df.columnCount, 2)
        XCTAssertEqual(df["b"].sum(), 15.0)
    }

    func testSelectColumns() {
        let df = DataFrame(["a": [1.0], "b": [2.0], "c": [3.0]])
        let sub = df.select(columns: ["a", "c"])
        XCTAssertEqual(sub.columnCount, 2)
        XCTAssertEqual(sub.columnNames, ["a", "c"])
    }

    func testDropColumns() {
        let df = DataFrame(["a": [1.0], "b": [2.0], "c": [3.0]])
        let sub = df.drop(columns: ["b"])
        XCTAssertEqual(sub.columnCount, 2)
        XCTAssertFalse(sub.columnNames.contains("b"))
    }

    func testIloc() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0, 5.0]])
        let sliced = df.iloc(1..<4)
        XCTAssertEqual(sliced.rowCount, 3)
    }

    func testFilterByMask() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0]])
        let mask = [true, false, true, false]
        let filtered = df.filter(mask: mask)
        XCTAssertEqual(filtered.rowCount, 2)
    }

    func testHeadTail() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0, 5.0]])
        XCTAssertEqual(df.head(3).rowCount, 3)
        XCTAssertEqual(df.tail(2).rowCount, 2)
    }

    func testAggregations() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        XCTAssertEqual(df.sum().sum(), 21.0)
        XCTAssertEqual(df.mean().sum(), 7.0) // mean(a)=2 + mean(b)=5 = 7
    }

    func testSortValues() {
        let df = DataFrame(["a": [3.0, 1.0, 2.0], "b": [30.0, 10.0, 20.0]])
        let sorted = df.sortValues(by: "a")
        XCTAssertEqual(sorted["a"].iloc(0) as? Double, 1.0)
        XCTAssertEqual(sorted["b"].iloc(0) as? Double, 10.0)
    }

    func testFromRecords() {
        let records: [[String: Double]] = [
            ["name_len": 3, "age": 25],
            ["name_len": 5, "age": 30],
        ]
        let df = DataFrame(records: records)
        XCTAssertEqual(df.rowCount, 2)
        XCTAssertEqual(df.columnCount, 2)
    }

    func testDescribe() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        let desc = df.describe()
        XCTAssertEqual(desc.rowCount, 5) // count, mean, std, min, max
        XCTAssertEqual(desc.columnCount, 2)
    }

    func testRename() {
        let df = DataFrame(["old": [1.0, 2.0]])
        let renamed = df.rename(columns: ["old": "new"])
        XCTAssertTrue(renamed.columnNames.contains("new"))
        XCTAssertFalse(renamed.columnNames.contains("old"))
    }

    func testConcat() {
        let df1 = DataFrame(["a": [1.0, 2.0]])
        let df2 = DataFrame(["a": [3.0, 4.0]])
        let combined = DataFrame.concat([df1, df2])
        XCTAssertEqual(combined.rowCount, 4)
        XCTAssertEqual(combined["a"].sum(), 10.0)
    }

    func testDescription() {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        let desc = df.description
        XCTAssertTrue(desc.contains("a"))
        XCTAssertTrue(desc.contains("b"))
    }
}

// MARK: - GroupBy Tests

final class GroupByTests: XCTestCase {
    func testGroupBySum() {
        let df = DataFrame(columns: [
            ("category", Column.fromStrings(["A", "B", "A", "B", "A"])),
            ("value", Column.fromDoubles([1.0, 2.0, 3.0, 4.0, 5.0])),
        ])
        let result = df.groupBy("category").sum()
        XCTAssertEqual(result.rowCount, 2)
        // A: 1+3+5=9, B: 2+4=6
    }

    func testGroupByMean() {
        let df = DataFrame(columns: [
            ("group", Column.fromStrings(["X", "Y", "X", "Y"])),
            ("score", Column.fromDoubles([10.0, 20.0, 30.0, 40.0])),
        ])
        let result = df.groupBy("group").mean()
        XCTAssertEqual(result.rowCount, 2)
    }

    func testGroupByCount() {
        let df = DataFrame(columns: [
            ("type", Column.fromStrings(["A", "B", "A", "A"])),
            ("val", Column.fromDoubles([1.0, 2.0, 3.0, 4.0])),
        ])
        let result = df.groupBy("type").count()
        XCTAssertEqual(result.rowCount, 2)
    }
}

// MARK: - Merge Tests

final class MergeTests: XCTestCase {
    func testInnerMerge() {
        let left = DataFrame(columns: [
            ("key", Column.fromStrings(["a", "b", "c"])),
            ("val1", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let right = DataFrame(columns: [
            ("key", Column.fromStrings(["b", "c", "d"])),
            ("val2", Column.fromDoubles([20.0, 30.0, 40.0])),
        ])
        let merged = left.merge(right, on: "key")
        XCTAssertEqual(merged.rowCount, 2) // b, c
        XCTAssertTrue(merged.columnNames.contains("val1"))
        XCTAssertTrue(merged.columnNames.contains("val2"))
    }
}
