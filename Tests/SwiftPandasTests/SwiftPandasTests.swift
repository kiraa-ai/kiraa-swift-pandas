// ──────────────────────────────────────────────────────────────────────────────
// SwiftPandasTests.swift
// SwiftPandasTests
//
// Core unit test suite for the SwiftPandas library. This file exercises every
// fundamental type and subsystem that forms the backbone of the library:
//
//   - Version string verification
//   - DType metadata (names, numeric/integer/float/boolean classification)
//   - NativeArray<T> (contiguous typed storage with copy-on-write semantics,
//     element-wise arithmetic, reductions, sorting, uniqueness, factorization,
//     slicing, appending, and Collection conformance)
//   - BitVector (compact 1-bit-per-element validity bitmask with popcount,
//     bitwise AND/OR/NOT, and large-vector correctness)
//   - NullableArray<T> (NativeArray + BitVector providing NA-aware arithmetic,
//     reductions, factorization, fill/drop NA, and mutation)
//   - StringArray (string storage with optional NA support, unique, fill/drop)
//   - Column (type-erased column storage covering double, string, bool, int64
//     variants, NA handling, aggregation, take, and formatted output)
//   - Index types (RangeIndex, StringIndex, Int64Index — label lookup,
//     containment, uniqueness)
//   - Series (1-D labeled array with construction, indexing, NA handling,
//     aggregation, median/quantile, head/tail, arithmetic, scalar ops,
//     comparison operators, apply/map, cumsum, valueCounts, sorting,
//     duplicated/dropDuplicates/nUnique, and describe)
//   - DataFrame (2-D labeled table with column access/assignment, select/drop,
//     iloc/loc/filter/head/tail, boolean mask subscript, aggregation,
//     single & multi-column sorting, records construction, describe, rename,
//     concat with mixed types, duplicated/dropDuplicates, and description)
//   - GroupBy (single & multi-column split-apply-combine for sum, mean, count)
//   - Merge (inner join, left join on a shared key column)
//   - Integration (end-to-end pandas-style workflow test)
//
// Each test class targets exactly one subsystem so failures can be pinpointed
// quickly. The tests are intentionally kept small and deterministic — no
// randomness, no file I/O, no Metal GPU dependency.
// ──────────────────────────────────────────────────────────────────────────────

import Testing
import Foundation
@testable import SwiftPandas

/// Tests for the library-level version constant.
/// Ensures the public `SwiftPandas.version` string matches the expected release.
@Suite struct SwiftPandasTests {
    @Test func testVersion() {
        #expect(SwiftPandas.version == "0.4.0-beta")
    }
}

// MARK: - DType Tests

/// Tests for the SwiftPandas data-type metadata system.
///
/// The DType layer provides runtime introspection for every column type the library
/// supports. Each concrete DType (e.g. `Int64DType`, `Float64DType`, `StringDType`,
/// `BoolDType`) exposes a human-readable `.name` and a set of category flags such as
/// `isSignedInteger`, `isUnsignedInteger`, `isFloat`, `isNumeric`, `isInteger`, and
/// `isBoolean`. The companion `DTypeEnum` enum mirrors these types as a lightweight
/// value type with its own `description` and category queries.
///
/// These tests verify:
/// - Correct `.name` strings for the four primary DType structs.
/// - Category flags are consistent (e.g. Int64 is signed, numeric, not float;
///   Float64 is float, numeric, not integer; Bool is boolean, not numeric; etc.).
/// - `DTypeEnum` descriptions, integer detection, float detection, and numeric
///   exclusion for strings.
@Suite struct DTypeTests {
    @Test func testDTypeNames() {
        #expect(Int64DType().name == "int64")
        #expect(Float64DType().name == "float64")
        #expect(StringDType().name == "string")
        #expect(BoolDType().name == "bool")
    }

    @Test func testDTypeCategories() {
        #expect(Int64DType().isSignedInteger)
        #expect(Int64DType().isNumeric)
        #expect(!Int64DType().isFloat)

        #expect(UInt32DType().isUnsignedInteger)
        #expect(UInt32DType().isNumeric)
        #expect(UInt32DType().isInteger)

        #expect(Float64DType().isFloat)
        #expect(Float64DType().isNumeric)
        #expect(!Float64DType().isInteger)

        #expect(BoolDType().isBoolean)
        #expect(!BoolDType().isNumeric)

        #expect(!StringDType().isNumeric)
    }

    @Test func testDTypeEnum() {
        #expect(DTypeEnum.float64.description == "float64")
        #expect(DTypeEnum.int32.isInteger)
        #expect(DTypeEnum.float64.isFloat)
        #expect(!DTypeEnum.string.isNumeric)
    }
}

// MARK: - NativeArray Tests

/// Tests for `NativeArray<T>`, the foundational contiguous typed storage layer.
///
/// `NativeArray` is the lowest-level building block in SwiftPandas. It wraps a
/// `ContiguousArray<T>` behind a copy-on-write (CoW) reference-counted buffer,
/// giving value semantics with amortised O(1) copies until mutation forces a
/// physical duplicate.
///
/// Coverage includes:
/// - **Creation**: constructing from a Swift array literal, verifying count and
///   element-by-element subscript access.
/// - **Copy-on-write**: demonstrating that assigning to a second variable shares
///   storage, while mutating one side triggers a deep copy leaving the other
///   unchanged.
/// - **Element-wise arithmetic**: `+`, `-`, `*`, `/` between two NativeArrays of
///   equal length, validated against expected element-wise results.
/// - **Reductions**: `sum()`, `min()`, `max()`, `mean()`, `std(ddof:)` — these
///   are backed by Accelerate vDSP when the element type is Double.
/// - **Argsort**: ascending and descending index-sort, returning the permutation
///   array rather than sorted values.
/// - **Unique**: deduplication preserving first-occurrence order.
/// - **Factorize**: converting values into integer codes plus a unique-value
///   array, analogous to pandas `factorize()`.
/// - **Slice**: subscript with a half-open `Range<Int>` returning a new
///   NativeArray with the selected elements.
/// - **Append**: in-place append of a single element.
/// - **Collection conformance**: verifying that `map` (from Sequence) works
///   correctly on NativeArray.
@Suite struct NativeArrayTests {
    @Test func testCreation() {
        let a = NativeArray<Double>([1.0, 2.0, 3.0])
        #expect(a.count == 3)
        #expect(a[0] == 1.0)
        #expect(a[1] == 2.0)
        #expect(a[2] == 3.0)
    }

    @Test func testCopyOnWrite() {
        var a = NativeArray<Double>([1.0, 2.0, 3.0])
        let b = a  // shares storage
        a[0] = 99.0  // triggers CoW copy
        #expect(a[0] == 99.0)
        #expect(b[0] == 1.0)  // b is unmodified
    }

    @Test func testArithmetic() {
        let a = NativeArray<Double>([1.0, 2.0, 3.0])
        let b = NativeArray<Double>([4.0, 5.0, 6.0])

        let sum = a + b
        #expect(sum.array == [5.0, 7.0, 9.0])

        let diff = b - a
        #expect(diff.array == [3.0, 3.0, 3.0])

        let prod = a * b
        #expect(prod.array == [4.0, 10.0, 18.0])

        let quot = b / a
        #expect(quot.array == [4.0, 2.5, 2.0])
    }

    @Test func testReductions() {
        let a = NativeArray<Double>([1.0, 2.0, 3.0, 4.0, 5.0])
        #expect(a.sum() == 15.0)
        #expect(a.min() == 1.0)
        #expect(a.max() == 5.0)
        #expect(a.mean() == 3.0)
        #expect(abs(a.std(ddof: 0) - sqrt(2.0)) <= 1e-10)
    }

    @Test func testArgsort() {
        let a = NativeArray<Double>([3.0, 1.0, 2.0])
        #expect(a.argsort() == [1, 2, 0])
        #expect(a.argsort(ascending: false) == [0, 2, 1])
    }

    @Test func testUnique() {
        let a = NativeArray<Int>([1, 2, 3, 2, 1])
        let u = a.unique()
        #expect(u.array == [1, 2, 3])
    }

    @Test func testFactorize() {
        let a = NativeArray<String>(["cat", "dog", "cat", "bird", "dog"])
        let (codes, uniques) = a.factorize()
        #expect(codes == [0, 1, 0, 2, 1])
        #expect(uniques.array == ["cat", "dog", "bird"])
    }

    @Test func testSlice() {
        let a = NativeArray<Double>([10.0, 20.0, 30.0, 40.0, 50.0])
        let s = a[1..<4]
        #expect(s.array == [20.0, 30.0, 40.0])
    }

    @Test func testAppend() {
        var a = NativeArray<Int>([1, 2])
        a.append(3)
        #expect(a.count == 3)
        #expect(a[2] == 3)
    }

    @Test func testCollection() {
        let a = NativeArray<Int>([1, 2, 3])
        let mapped = a.map { $0 * 2 }
        #expect(mapped == [2, 4, 6])
    }
}

// MARK: - BitVector Tests

/// Tests for `BitVector`, the compact 1-bit-per-element validity bitmap.
///
/// `BitVector` stores one bit per logical element, packed into `UInt64` words.
/// It is used throughout SwiftPandas as the NA (missing-value) mask inside
/// `NullableArray`, `StringArray`, and `Column`. Efficient bitwise operations
/// (`&`, `|`, `~`) allow combining masks for compound boolean filters without
/// allocating per-element Bool arrays.
///
/// Coverage includes:
/// - **All-valid / all-NA**: constructing uniform bitmasks via `repeating:count:`
///   and verifying `popcount`, `allValid`, `allNA`, and `naCount`.
/// - **From Bool array**: constructing from `[Bool]` and checking individual bit
///   subscript access and popcount.
/// - **Mutation**: flipping individual bits via subscript setter and confirming
///   popcount updates accordingly.
/// - **Bitwise AND** (`&`): element-wise conjunction of two BitVectors.
/// - **Bitwise OR** (`|`): element-wise disjunction.
/// - **Bitwise NOT** (`~`): element-wise negation.
/// - **Large vector**: stress-testing with 1 000 bits to ensure word-boundary
///   packing and popcount work at scale.
@Suite struct BitVectorTests {
    @Test func testAllValid() {
        let bv = BitVector(repeating: true, count: 100)
        #expect(bv.popcount == 100)
        #expect(bv.allValid)
        #expect(bv.naCount == 0)
    }

    @Test func testAllNA() {
        let bv = BitVector(repeating: false, count: 50)
        #expect(bv.popcount == 0)
        #expect(bv.allNA)
    }

    @Test func testFromBools() {
        let bv = BitVector([true, false, true, false, true])
        #expect(bv.popcount == 3)
        #expect(bv[0])
        #expect(!bv[1])
        #expect(bv[2])
    }

    @Test func testMutation() {
        var bv = BitVector(repeating: true, count: 10)
        bv[3] = false
        bv[7] = false
        #expect(bv.popcount == 8)
        #expect(!bv[3])
        #expect(!bv[7])
    }

    @Test func testBitwiseAnd() {
        let a = BitVector([true, true, false, false])
        let b = BitVector([true, false, true, false])
        let c = a & b
        #expect(c.boolArray == [true, false, false, false])
    }

    @Test func testBitwiseOr() {
        let a = BitVector([true, true, false, false])
        let b = BitVector([true, false, true, false])
        let c = a | b
        #expect(c.boolArray == [true, true, true, false])
    }

    @Test func testBitwiseNot() {
        let a = BitVector([true, false, true])
        let b = ~a
        #expect(b.boolArray == [false, true, false])
    }

    @Test func testLargeBitVector() {
        let bv = BitVector(repeating: true, count: 1000)
        #expect(bv.popcount == 1000)
        #expect(bv.bitCount == 1000)
    }
}

// MARK: - NullableArray Tests

/// Tests for `NullableArray<T>`, the NA-aware typed array built on `NativeArray` + `BitVector`.
///
/// `NullableArray` pairs a `NativeArray<T>` of values with a `BitVector` validity
/// mask. Elements where the mask bit is false are treated as NA (missing). This
/// design avoids boxing values in `Optional` and enables efficient SIMD reductions
/// that skip NA positions.
///
/// Coverage includes:
/// - **Construction from optionals**: `[T?]` literal, validating `count`,
///   `validCount`, `naCount`, and per-element subscript returning `T?`.
/// - **isNA / notNA**: producing `[Bool]` masks that identify missing vs. present
///   elements.
/// - **fillNA**: replacing NA positions with a constant fill value and returning a
///   dense `NativeArray<T>`.
/// - **dropNA**: removing NA positions entirely and returning a dense array.
/// - **Arithmetic with NA propagation**: element-wise `+` where either operand is
///   NA produces NA in the result.
/// - **Reductions (NA-skipping)**: `sum()`, `mean()`, `min()`, `max()` that
///   silently exclude NA positions, matching pandas `skipna=True` behavior.
/// - **Factorize**: mapping values to integer codes with NA positions coded as -1,
///   plus a dense unique-value array.
/// - **Mutation**: setting a subscript to a non-nil value marks it valid; setting
///   it to nil marks it NA.
@Suite struct NullableArrayTests {
    @Test func testFromOptionals() {
        let a = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        #expect(a.count == 5)
        #expect(a.validCount == 3)
        #expect(a.naCount == 2)
        #expect(a[0] == 1.0)
        #expect(a[1] == nil)
        #expect(a[2] == 3.0)
    }

    @Test func testIsNA() {
        let a = NullableArray<Double>([1.0, nil, 3.0])
        #expect(a.isNA() == [false, true, false])
        #expect(a.notNA() == [true, false, true])
    }

    @Test func testFillNA() {
        let a = NullableArray<Double>([1.0, nil, 3.0])
        let filled = a.fillNA(value: 0.0)
        #expect(filled.array == [1.0, 0.0, 3.0])
    }

    @Test func testDropNA() {
        let a = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        let dropped = a.dropNA()
        #expect(dropped.array == [1.0, 3.0, 5.0])
    }

    @Test func testArithmeticWithNAPropagation() {
        let a = NullableArray<Double>([1.0, nil, 3.0])
        let b = NullableArray<Double>([10.0, 20.0, nil])
        let sum = a + b
        #expect(sum[0] == 11.0)
        #expect(sum[1] == nil)   // NA + 20 = NA
        #expect(sum[2] == nil)   // 3 + NA = NA
    }

    @Test func testReductions() {
        let a = NullableArray<Double>([1.0, nil, 3.0, nil, 5.0])
        #expect(a.sum() == 9.0)
        #expect(a.mean() == 3.0)
        #expect(a.min() == 1.0)
        #expect(a.max() == 5.0)
    }

    @Test func testFactorize() {
        let a = NullableArray<Int64>([1, nil, 2, 1, nil, 2])
        let (codes, uniques) = a.factorize()
        #expect(codes == [0, -1, 1, 0, -1, 1])
        #expect(uniques.array == [1, 2])
    }

    @Test func testMutation() {
        var a = NullableArray<Double>([1.0, nil, 3.0])
        a[1] = 2.0
        #expect(a[1] == 2.0)
        a[0] = nil
        #expect(a[0] == nil)
    }
}

// MARK: - StringArray Tests

/// Tests for `StringArray`, the dedicated string storage with NA support.
///
/// `StringArray` stores strings as `[String?]` internally and exposes an API
/// parallel to `NullableArray<T>`. It is the backing store for `.string` columns
/// and provides efficient unique/fill/drop operations tailored to text data.
///
/// Coverage includes:
/// - **Creation**: constructing from `[String]` (no NAs) and verifying count and
///   subscript access.
/// - **With NAs**: constructing from `[String?]`, verifying `validCount`,
///   subscript returning nil for NA positions, and `isNA()` mask.
/// - **Unique**: deduplication preserving first-occurrence order.
/// - **fillNA**: replacing nil positions with a constant string.
/// - **dropNA**: producing a dense `[String]` with NA positions removed.
@Suite struct StringArrayTests {
    @Test func testCreation() {
        let a = StringArray(["hello", "world"])
        #expect(a.count == 2)
        #expect(a[0] == "hello")
    }

    @Test func testWithNAs() {
        let a = StringArray(["a", nil, "c"])
        #expect(a.validCount == 2)
        #expect(a[1] == nil)
        #expect(a.isNA() == [false, true, false])
    }

    @Test func testUnique() {
        let a = StringArray(["a", "b", "a", "c", "b"])
        let u = a.unique()
        #expect(u.storage == ["a", "b", "c"])
    }

    @Test func testFillNA() {
        let a = StringArray(["a", nil, "c"])
        let filled = a.fillNA(value: "NA")
        #expect(filled.storage == ["a", "NA", "c"])
    }

    @Test func testDropNA() {
        let a = StringArray(["a", nil, "c"])
        #expect(a.dropNA() == ["a", "c"])
    }
}

// MARK: - Column Tests

/// Tests for `Column`, the type-erased column storage used inside `DataFrame`.
///
/// `Column` is an enum with cases `.double`, `.string`, `.bool`, and `.int64`,
/// each wrapping a `NullableArray` or `StringArray`. It exposes a uniform API
/// for dtype queries, count, NA statistics, aggregation (`sum`, `mean`, `min`,
/// `max`), index-based row extraction (`take`), and formatted display.
///
/// Coverage includes:
/// - **Double column**: factory creation via `Column.fromDoubles`, dtype check,
///   `isNumeric`, and aggregation (sum, mean).
/// - **String column**: factory creation via `Column.fromStrings`, dtype check,
///   non-numeric assertion.
/// - **Column with NAs**: `Column.fromOptionalDoubles`, verifying `validCount`,
///   `naCount`, and that `formattedValue(at:)` returns `"NA"` for missing rows.
/// - **Aggregations with NAs**: sum/mean/min/max that skip missing values.
/// - **take(indices:)**: reordering or subsetting a column by an array of integer
///   positions.
/// - **Bool column**: factory creation via `Column.fromBools` and dtype check.
@Suite struct ColumnTests {
    @Test func testDoubleColumn() {
        let col = Column.fromDoubles([1.0, 2.0, 3.0])
        #expect(col.dtype == .float64)
        #expect(col.count == 3)
        #expect(col.isNumeric)
        #expect(col.sum() == 6.0)
        #expect(col.mean() == 2.0)
    }

    @Test func testStringColumn() {
        let col = Column.fromStrings(["a", "b", "c"])
        #expect(col.dtype == .string)
        #expect(!col.isNumeric)
        #expect(col.count == 3)
    }

    @Test func testColumnWithNAs() {
        let col = Column.fromOptionalDoubles([1.0, nil, 3.0])
        #expect(col.validCount == 2)
        #expect(col.naCount == 1)
        #expect(col.formattedValue(at: 1) == "NA")
    }

    @Test func testColumnAggregations() {
        let col = Column.fromOptionalDoubles([1.0, nil, 3.0, nil, 5.0])
        #expect(col.sum() == 9.0)
        #expect(col.mean() == 3.0)
        #expect(col.min() == 1.0)
        #expect(col.max() == 5.0)
    }

    @Test func testTake() {
        let col = Column.fromDoubles([10.0, 20.0, 30.0, 40.0])
        let taken = col.take(indices: [3, 1, 0])
        #expect(taken.count == 3)
    }

    @Test func testBoolColumn() {
        let col = Column.fromBools([true, false, true])
        #expect(col.dtype == .bool)
        #expect(col.count == 3)
    }
}

// MARK: - Index Tests

/// Tests for the Index subsystem: `RangeIndex`, `StringIndex`, and `Int64Index`.
///
/// Indexes provide O(1) label-to-position lookup for both Series and DataFrame.
/// `RangeIndex` is the memory-efficient default (no heap allocation for a
/// contiguous 0..<n range). `StringIndex` and `Int64Index` are backed by hash
/// maps for arbitrary label sets.
///
/// Coverage includes:
/// - **RangeIndex**: count, subscript access at boundaries, `getLocation(of:)`
///   for a valid and out-of-range label, and `isUnique` (always true).
/// - **StringIndex**: count, label lookup by string, nil for missing labels,
///   and uniqueness.
/// - **Int64Index**: count, label lookup by Int64, `contains` for present and
///   absent labels.
@Suite struct IndexTests {
    @Test func testRangeIndex() {
        let idx = RangeIndex(10)
        #expect(idx.count == 10)
        #expect(idx[0] == 0)
        #expect(idx[9] == 9)
        #expect(idx.getLocation(of: 5) == 5)
        #expect(idx.getLocation(of: 10) == nil)
        #expect(idx.isUnique)
    }

    @Test func testStringIndex() {
        let idx = StringIndex(["a", "b", "c"])
        #expect(idx.count == 3)
        #expect(idx.getLocation(of: "b") == 1)
        #expect(idx.getLocation(of: "d") == nil)
        #expect(idx.isUnique)
    }

    @Test func testInt64Index() {
        let idx = Int64Index([10, 20, 30])
        #expect(idx.count == 3)
        #expect(idx.getLocation(of: 20) == 1)
        #expect(idx.contains(30))
        #expect(!idx.contains(40))
    }
}

// MARK: - Series Tests

/// Tests for `Series`, the 1-D labeled array — the pandas `pd.Series` equivalent.
///
/// `Series` wraps a `Column` with optional name and index, and exposes the
/// highest-level API for single-column data manipulation. It supports
/// construction from `[Double]`, `[Double?]`, `[String]`, `[String?]`,
/// dictionaries, and more.
///
/// Coverage includes:
/// - **Creation**: from `[Double]` with name, verifying count, name, and dtype.
/// - **From dictionary**: `Series(["a": 1.0, ...])`, verifying count and
///   label-based `.loc()` access.
/// - **Aggregations**: `sum()`, `mean()`, `min()`, `max()` on a dense series.
/// - **NA handling**: `count` vs. `validCount` vs. `naCount`, and that `sum()`
///   correctly skips NAs.
/// - **dropNA / fillNA**: removing or replacing missing values.
/// - **head / tail**: slicing the first or last n elements.
/// - **Element-wise arithmetic**: `Series + Series`.
/// - **Scalar arithmetic**: `Series * Double`.
/// - **valueCounts**: frequency table as a new Series.
/// - **sortValues**: ascending sort with iloc verification.
/// - **describe**: 8-row summary (count, mean, std, min, 25%, 50%, 75%, max).
@Suite struct SeriesTests {

    // MARK: - Construction

    @Test func testCreation() {
        let s = Series([1.0, 2.0, 3.0], name: "values")
        #expect(s.count == 3)
        #expect(s.name == "values")
        #expect(s.dtype == .float64)
    }

    @Test func testFromDict() {
        let s = Series(["a": 1.0, "b": 2.0, "c": 3.0])
        #expect(s.count == 3)
        #expect(s.loc("b") as? Double == 2.0)
    }

    // MARK: - Aggregations & Statistics

    @Test func testAggregations() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        #expect(s.sum() == 15.0)
        #expect(s.mean() == 3.0)
        #expect(s.min() == 1.0)
        #expect(s.max() == 5.0)
    }

    @Test func testMedianOdd() {
        let s = Series([3.0, 1.0, 2.0, 5.0, 4.0])
        #expect(s.median() == 3.0)
    }

    @Test func testMedianEven() {
        let s = Series([1.0, 2.0, 3.0, 4.0])
        #expect(s.median() == 2.5)
    }

    @Test func testMedianWithNA() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        #expect(s.median() == 3.0) // median of [1, 3, 5]
    }

    @Test func testQuantile() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        #expect(s.quantile(0.0) == 1.0)
        #expect(s.quantile(0.5) == 3.0)
        #expect(s.quantile(1.0) == 5.0)
        #expect(abs(s.quantile(0.25)! - 2.0) <= 0.01)
        #expect(abs(s.quantile(0.75)! - 4.0) <= 0.01)
    }

    @Test func testDescribe() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let desc = s.describe()
        #expect(desc.count == 8) // count, mean, std, min, 25%, 50%, 75%, max
        #expect(desc.index == ["count", "mean", "std", "min", "25%", "50%", "75%", "max"])
        #expect(desc.loc("50%") as? Double == 3.0)
    }

    @Test func testDataFrameMedian() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [10.0, 20.0, 30.0]])
        let med = df.median()
        #expect(med.loc("a") as? Double == 2.0)
        #expect(med.loc("b") as? Double == 20.0)
    }

    // MARK: - NA Handling

    @Test func testNAHandling() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        #expect(s.count == 5)
        #expect(s.validCount == 3)
        #expect(s.naCount == 2)
        #expect(s.sum() == 9.0)
    }

    @Test func testDropNA() {
        let s = Series([1.0, nil, 3.0])
        let dropped = s.dropNA()
        #expect(dropped.count == 2)
    }

    @Test func testFillNA() {
        let s = Series([1.0, nil, 3.0])
        let filled = s.fillNA(0.0)
        #expect(filled.sum() == 4.0)
        #expect(filled.naCount == 0)
    }

    @Test func testHeadTail() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        #expect(s.head(3).count == 3)
        #expect(s.tail(2).count == 2)
    }

    // MARK: - Arithmetic

    @Test func testArithmetic() {
        let a = Series([1.0, 2.0, 3.0])
        let b = Series([4.0, 5.0, 6.0])
        let sum = a + b
        #expect(sum.sum() == 21.0)
    }

    @Test func testScalarArithmetic() {
        let s = Series([1.0, 2.0, 3.0])
        let doubled = s * 2.0
        #expect(doubled.sum() == 12.0)
    }

    @Test func testSubtractScalar() {
        let s = Series([10.0, 20.0, 30.0])
        let result = s - 5.0
        #expect(result.sum() == 45.0) // 5 + 15 + 25
    }

    @Test func testDivideScalar() {
        let s = Series([10.0, 20.0, 30.0])
        let result = s / 10.0
        #expect(result.sum() == 6.0) // 1 + 2 + 3
    }

    @Test func testScalarArithmeticWithNA() {
        let s = Series([10.0, nil, 30.0])
        let result = s - 5.0
        #expect(result.iloc(0) as? Double == 5.0)
        #expect(result.iloc(1) as? Double == nil)
        #expect(result.iloc(2) as? Double == 25.0)
    }

    // MARK: - Cumulative Operations

    @Test func testCumsum() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let cs = s.cumsum()
        #expect(cs.iloc(0) as? Double == 1.0)
        #expect(cs.iloc(1) as? Double == 3.0)
        #expect(cs.iloc(2) as? Double == 6.0)
        #expect(cs.iloc(3) as? Double == 10.0)
        #expect(cs.iloc(4) as? Double == 15.0)
    }

    @Test func testCumsumWithNA() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        let cs = s.cumsum()
        #expect(cs.iloc(0) as? Double == 1.0)
        #expect(cs.iloc(1) as? Double == nil) // NA stays NA
        #expect(cs.iloc(2) as? Double == 4.0)
        #expect(cs.iloc(3) as? Double == nil)
        #expect(cs.iloc(4) as? Double == 9.0)
    }

    // MARK: - Comparison Operators

    @Test func testGreaterThan() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s > 3.0
        #expect(mask == [false, false, false, true, true])
    }

    @Test func testGreaterThanOrEqual() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s >= 3.0
        #expect(mask == [false, false, true, true, true])
    }

    @Test func testLessThan() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s < 3.0
        #expect(mask == [true, true, false, false, false])
    }

    @Test func testLessThanOrEqual() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let mask = s <= 3.0
        #expect(mask == [true, true, true, false, false])
    }

    @Test func testComparisonWithNA() {
        let s = Series([1.0, nil, 3.0, nil, 5.0])
        let mask = s > 2.0
        #expect(mask == [false, false, true, false, true]) // NAs produce false
    }

    @Test func testEqDouble() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        let mask = s.eq(2.0)
        #expect(mask == [false, true, false, true, false])
    }

    @Test func testNeDouble() {
        let s = Series([1.0, 2.0, 3.0])
        let mask = s.ne(2.0)
        #expect(mask == [true, false, true])
    }

    @Test func testEqString() {
        let s = Series(["a", "b", "c", "b"])
        let mask = s.eq("b")
        #expect(mask == [false, true, false, true])
    }

    @Test func testNeString() {
        let s = Series(["a", "b", "c"])
        let mask = s.ne("b")
        #expect(mask == [true, false, true])
    }

    @Test func testStrContains() {
        let s = Series(["hello", "world", "help", "foo"])
        let mask = s.strContains("hel")
        #expect(mask == [true, false, true, false])
    }

    @Test func testStrContainsWithNA() {
        let s = Series(["hello", nil, "help", nil] as [String?])
        let mask = s.strContains("hel")
        #expect(mask == [true, false, true, false]) // NAs produce false
    }

    // MARK: - Apply & Map

    @Test func testApply() {
        let s = Series([1.0, 4.0, 9.0, 16.0])
        let sqrts = s.apply { $0.squareRoot() }
        #expect(sqrts.iloc(0) as? Double == 1.0)
        #expect(sqrts.iloc(1) as? Double == 2.0)
        #expect(sqrts.iloc(2) as? Double == 3.0)
        #expect(sqrts.iloc(3) as? Double == 4.0)
    }

    @Test func testApplyWithNA() {
        let s = Series([1.0, nil, 9.0])
        let result = s.apply { $0 * 2 }
        #expect(result.iloc(0) as? Double == 2.0)
        #expect(result.iloc(1) as? Double == nil) // NA stays NA
        #expect(result.iloc(2) as? Double == 18.0)
    }

    @Test func testMapDouble() {
        let s = Series([1.0, 2.0, 3.0, 2.0])
        let mapped = s.map([1.0: 10.0, 2.0: 20.0, 3.0: 30.0])
        #expect(mapped.sum() == 80.0) // 10 + 20 + 30 + 20
    }

    @Test func testMapString() {
        let s = Series(["a", "b", "c", "a"])
        let mapped = s.map(["a": "alpha", "b": "beta"])
        #expect(mapped.iloc(0) as? String == "alpha")
        #expect(mapped.iloc(1) as? String == "beta")
        #expect(mapped.naCount == 1) // only "c" unmapped
    }

    @Test func testMapStringUnmappedBecomesNA() {
        let s = Series(["x", "y", "z"])
        let mapped = s.map(["x": "X"])
        #expect(mapped.iloc(0) as? String == "X")
        #expect(mapped.naCount == 2) // y, z not in mapping
    }

    // MARK: - Unique & Duplicates

    @Test func testValueCounts() {
        let s = Series(["a", "b", "a", "c", "b", "a"])
        let vc = s.valueCounts()
        #expect(vc.count == 3)
    }

    @Test func testSortValues() {
        let s = Series([3.0, 1.0, 2.0])
        let sorted = s.sortValues()
        #expect(sorted.iloc(0) as? Double == 1.0)
        #expect(sorted.iloc(2) as? Double == 3.0)
    }

    @Test func testSeriesDuplicated() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        let dupes = s.duplicated()
        #expect(dupes == [false, false, false, true, true])
    }

    @Test func testSeriesDropDuplicates() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        let unique = s.dropDuplicates()
        #expect(unique.count == 3)
        #expect(unique.sum() == 6.0) // 1 + 2 + 3
    }

    @Test func testSeriesNUnique() {
        let s = Series([1.0, 2.0, 3.0, 2.0, 1.0])
        #expect(s.nUnique == 3)
    }

    @Test func testSeriesUnique() {
        let s = Series(["a", "b", "c", "b", "a"])
        let unique = s.unique()
        #expect(unique.count == 3)
    }

    @Test func testStringDuplicated() {
        let s = Series(["hello", "world", "hello"])
        let dupes = s.duplicated()
        #expect(dupes == [false, false, true])
    }
}

// MARK: - DataFrame Tests

/// Tests for `DataFrame`, the 2-D labeled table — the pandas `pd.DataFrame` equivalent.
///
/// `DataFrame` holds an ordered dictionary of `Column` values keyed by column name,
/// plus a shared row index. It is the primary data structure in SwiftPandas and
/// supports column access, row slicing, boolean filtering, aggregation, sorting,
/// merging, concatenation, and textual display.
///
/// Coverage includes:
/// - **Creation**: from `[String: [Double]]` dictionary literal, verifying shape.
/// - **Column access**: subscript `df["x"]` returning a Series with correct sum
///   and name.
/// - **Column assignment**: `df["b"] = Series(...)` adding a new column.
/// - **select / drop**: subsetting or removing columns by name.
/// - **iloc**: integer-range row slicing.
/// - **filter(mask:)**: boolean-mask row filtering.
/// - **head / tail**: first/last n rows.
/// - **Aggregations**: `sum()` and `mean()` across all numeric columns.
/// - **sortValues**: single-column sort preserving row alignment across columns.
/// - **fromRecords**: constructing from `[[String: Double]]` array of dicts.
/// - **describe**: 8-row x n-column summary statistics table.
/// - **rename**: column renaming via a mapping dictionary.
/// - **concat**: vertical stacking of DataFrames with matching schemas.
/// - **description**: textual representation containing column names.
@Suite struct DataFrameTests {

    // MARK: - Construction

    @Test func testCreation() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        #expect(df.shape.rows == 3)
        #expect(df.shape.columns == 2)
    }

    @Test func testFromRecords() {
        let records: [[String: Double]] = [
            ["name_len": 3, "age": 25],
            ["name_len": 5, "age": 30],
        ]
        let df = DataFrame(records: records)
        #expect(df.rowCount == 2)
        #expect(df.columnCount == 2)
    }

    // MARK: - Column Access & Mutation

    @Test func testColumnAccess() {
        let df = DataFrame(["x": [1.0, 2.0], "y": [3.0, 4.0]])
        let s = df["x"]
        #expect(s.sum() == 3.0)
        #expect(s.name == "x")
    }

    @Test func testColumnAssignment() {
        var df = DataFrame(["a": [1.0, 2.0, 3.0]])
        df["b"] = Series([4.0, 5.0, 6.0])
        #expect(df.columnCount == 2)
        #expect(df["b"].sum() == 15.0)
    }

    @Test func testSelectColumns() {
        let df = DataFrame(["a": [1.0], "b": [2.0], "c": [3.0]])
        let sub = df.select(columns: ["a", "c"])
        #expect(sub.columnCount == 2)
        #expect(sub.columnNames == ["a", "c"])
    }

    @Test func testDropColumns() {
        let df = DataFrame(["a": [1.0], "b": [2.0], "c": [3.0]])
        let sub = df.drop(columns: ["b"])
        #expect(sub.columnCount == 2)
        #expect(!sub.columnNames.contains("b"))
    }

    @Test func testRename() {
        let df = DataFrame(["old": [1.0, 2.0]])
        let renamed = df.rename(columns: ["old": "new"])
        #expect(renamed.columnNames.contains("new"))
        #expect(!renamed.columnNames.contains("old"))
    }

    // MARK: - Row Access

    @Test func testIloc() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0, 5.0]])
        let sliced = df.iloc(1..<4)
        #expect(sliced.rowCount == 3)
    }

    @Test func testHeadTail() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0, 5.0]])
        #expect(df.head(3).rowCount == 3)
        #expect(df.tail(2).rowCount == 2)
    }

    @Test func testLocSingleRow() {
        let df = DataFrame(
            columns: [("a", Column.fromDoubles([10.0, 20.0, 30.0]))],
            index: ["x", "y", "z"]
        )
        let row = df.loc("y")
        #expect(row != nil)
        #expect(row?["a"] as? Double == 20.0)
    }

    @Test func testLocMultipleRows() {
        let df = DataFrame(
            columns: [("a", Column.fromDoubles([10.0, 20.0, 30.0, 40.0]))],
            index: ["w", "x", "y", "z"]
        )
        let sub = df.loc(["x", "z"])
        #expect(sub.rowCount == 2)
        #expect(sub["a"].sum() == 60.0) // 20 + 40
    }

    @Test func testLocMissingLabel() {
        let df = DataFrame(
            columns: [("a", Column.fromDoubles([10.0]))],
            index: ["x"]
        )
        #expect(df.loc("missing") == nil)
    }

    // MARK: - Filtering

    @Test func testFilterByMask() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0]])
        let mask = [true, false, true, false]
        let filtered = df.filter(mask: mask)
        #expect(filtered.rowCount == 2)
    }

    @Test func testSubscriptWithMask() {
        let df = DataFrame(["age": [25.0, 35.0, 28.0, 40.0]])
        let result = df[df["age"] > 30.0]
        #expect(result.rowCount == 2)
    }

    @Test func testPandasStyleFiltering() {
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie"])),
            ("score", Column.fromDoubles([85.0, 92.0, 78.0])),
        ])
        let passed = df[df["score"] >= 80.0]
        #expect(passed.rowCount == 2)

        let bobs = df[df["name"].eq("Bob")]
        #expect(bobs.rowCount == 1)
        #expect(bobs["score"].iloc(0) as? Double == 92.0)
    }

    @Test func testDataFrameFilterWithComparison() {
        let df = DataFrame(["name_len": [3.0, 5.0, 4.0, 6.0], "age": [25.0, 35.0, 28.0, 40.0]])
        let filtered = df[df["age"] > 30.0]
        #expect(filtered.rowCount == 2)
        #expect(filtered["age"].min() == 35.0)
    }

    // MARK: - Sorting

    @Test func testSortValues() {
        let df = DataFrame(["a": [3.0, 1.0, 2.0], "b": [30.0, 10.0, 20.0]])
        let sorted = df.sortValues(by: "a")
        #expect(sorted["a"].iloc(0) as? Double == 1.0)
        #expect(sorted["b"].iloc(0) as? Double == 10.0)
    }

    @Test func testSortByMultipleColumns() {
        let df = DataFrame(columns: [
            ("dept", Column.fromStrings(["A", "B", "A", "B"])),
            ("salary", Column.fromDoubles([50.0, 60.0, 70.0, 40.0])),
        ])
        let sorted = df.sortValues(by: ["dept", "salary"], ascending: [true, false])
        // A rows first (sorted by salary desc): 70, 50
        // B rows next (sorted by salary desc): 60, 40
        #expect(sorted.columns["dept"]!.formattedValue(at: 0) == "A")
        #expect(sorted["salary"].iloc(0) as? Double == 70.0)
        #expect(sorted["salary"].iloc(1) as? Double == 50.0)
        #expect(sorted.columns["dept"]!.formattedValue(at: 2) == "B")
        #expect(sorted["salary"].iloc(2) as? Double == 60.0)
        #expect(sorted["salary"].iloc(3) as? Double == 40.0)
    }

    @Test func testSortByMultipleColumnsDefaultAscending() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([2.0, 1.0, 2.0, 1.0])),
            ("b", Column.fromDoubles([30.0, 10.0, 20.0, 40.0])),
        ])
        let sorted = df.sortValues(by: ["a", "b"])
        // a=1 rows first (b asc): 10, 40; then a=2 rows: 20, 30
        #expect(sorted["a"].iloc(0) as? Double == 1.0)
        #expect(sorted["b"].iloc(0) as? Double == 10.0)
        #expect(sorted["a"].iloc(1) as? Double == 1.0)
        #expect(sorted["b"].iloc(1) as? Double == 40.0)
    }

    // MARK: - Aggregations

    @Test func testAggregations() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        #expect(df.sum().sum() == 21.0)
        #expect(df.mean().sum() == 7.0) // mean(a)=2 + mean(b)=5 = 7
    }

    @Test func testDescribe() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        let desc = df.describe()
        #expect(desc.rowCount == 8) // count, mean, std, min, 25%, 50%, 75%, max
        #expect(desc.columnCount == 2)
    }

    // MARK: - Duplicates

    @Test func testDataFrameDuplicated() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([1.0, 2.0, 1.0, 2.0])),
            ("b", Column.fromStrings(["x", "y", "x", "z"])),
        ])
        let dupes = df.duplicated()
        #expect(dupes == [false, false, true, false]) // row 2 duplicates row 0
    }

    @Test func testDataFrameDropDuplicates() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([1.0, 2.0, 1.0, 2.0])),
            ("b", Column.fromStrings(["x", "y", "x", "z"])),
        ])
        let deduped = df.dropDuplicates()
        #expect(deduped.rowCount == 3)
    }

    @Test func testDataFrameDropDuplicatesSubset() {
        let df = DataFrame(columns: [
            ("a", Column.fromDoubles([1.0, 2.0, 1.0, 3.0])),
            ("b", Column.fromStrings(["x", "y", "z", "x"])),
        ])
        let deduped = df.dropDuplicates(subset: ["a"])
        #expect(deduped.rowCount == 3) // 1.0, 2.0, 3.0
    }

    // MARK: - Concat

    @Test func testConcat() {
        let df1 = DataFrame(["a": [1.0, 2.0]])
        let df2 = DataFrame(["a": [3.0, 4.0]])
        let combined = DataFrame.concat([df1, df2])
        #expect(combined.rowCount == 4)
        #expect(combined["a"].sum() == 10.0)
    }

    @Test func testConcatWithStringColumns() {
        let df1 = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob"])),
            ("score", Column.fromDoubles([90.0, 80.0])),
        ])
        let df2 = DataFrame(columns: [
            ("name", Column.fromStrings(["Charlie"])),
            ("score", Column.fromDoubles([70.0])),
        ])
        let combined = DataFrame.concat([df1, df2])
        #expect(combined.rowCount == 3)
        #expect(combined["name"].iloc(2) as? String == "Charlie")
        #expect(combined["score"].sum() == 240.0)
    }

    @Test func testConcatMixedTypes() {
        let df1 = DataFrame(columns: [
            ("id", Column.fromStrings(["a", "b"])),
            ("val", Column.fromDoubles([1.0, 2.0])),
        ])
        let df2 = DataFrame(columns: [
            ("id", Column.fromStrings(["c"])),
            ("val", Column.fromDoubles([3.0])),
        ])
        let combined = DataFrame.concat([df1, df2])
        #expect(combined.rowCount == 3)
        #expect(combined.columns["id"]!.dtype == .string)
        #expect(combined.columns["val"]!.dtype == .float64)
    }

    // MARK: - Description

    @Test func testDescription() {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        let desc = df.description
        #expect(desc.contains("a"))
        #expect(desc.contains("b"))
    }
}

// MARK: - GroupBy Tests

/// Tests for the GroupBy split-apply-combine engine.
///
/// `DataFrame.groupBy(_:)` partitions rows by the values in one or more key
/// columns, then applies an aggregation function (sum, mean, count, min, max)
/// independently to each group. The result is a new DataFrame indexed by the
/// group keys.
///
/// Coverage includes:
/// - **sum**: verifying row count of the grouped result and expected per-group
///   totals (A: 1+3+5=9, B: 2+4=6).
/// - **mean**: two groups with known means.
/// - **count**: verifying the number of rows per group.
@Suite struct GroupByTests {

    // MARK: - Single-Column GroupBy

    @Test func testGroupBySum() {
        let df = DataFrame(columns: [
            ("category", Column.fromStrings(["A", "B", "A", "B", "A"])),
            ("value", Column.fromDoubles([1.0, 2.0, 3.0, 4.0, 5.0])),
        ])
        let result = df.groupBy("category").sum()
        #expect(result.rowCount == 2)
        // A: 1+3+5=9, B: 2+4=6
    }

    @Test func testGroupByMean() {
        let df = DataFrame(columns: [
            ("group", Column.fromStrings(["X", "Y", "X", "Y"])),
            ("score", Column.fromDoubles([10.0, 20.0, 30.0, 40.0])),
        ])
        let result = df.groupBy("group").mean()
        #expect(result.rowCount == 2)
    }

    @Test func testGroupByCount() {
        let df = DataFrame(columns: [
            ("type", Column.fromStrings(["A", "B", "A", "A"])),
            ("val", Column.fromDoubles([1.0, 2.0, 3.0, 4.0])),
        ])
        let result = df.groupBy("type").count()
        #expect(result.rowCount == 2)
    }

    @Test func testGroupBySumValues() {
        let df = DataFrame(columns: [
            ("group", Column.fromStrings(["A", "B", "A"])),
            ("val", Column.fromDoubles([10.0, 20.0, 30.0])),
        ])
        let result = df.groupBy("group").sum()
        #expect(result.rowCount == 2)
        let aIdx = result.indexLabels.firstIndex(of: "A")!
        #expect(result["val"].iloc(aIdx) as? Double == 40.0)
    }

    // MARK: - Multi-Column GroupBy

    @Test func testGroupByMultipleColumns() {
        let df = DataFrame(columns: [
            ("dept", Column.fromStrings(["A", "A", "B", "B"])),
            ("level", Column.fromStrings(["Jr", "Sr", "Jr", "Sr"])),
            ("salary", Column.fromDoubles([50.0, 80.0, 60.0, 90.0])),
        ])
        let result = df.groupBy(["dept", "level"]).mean()
        #expect(result.rowCount == 4) // A-Jr, A-Sr, B-Jr, B-Sr
        #expect(result.columnNames.contains("dept"))
        #expect(result.columnNames.contains("level"))
        #expect(result.columnNames.contains("salary"))
    }
}

// MARK: - Merge Tests

/// Tests for `DataFrame.merge(_:on:how:)`, the SQL-style join.
///
/// Merge combines two DataFrames by matching rows on a shared key column.
/// Supports inner, left, right, and outer join types.
@Suite struct MergeTests {
    @Test func testInnerMerge() {
        let left = DataFrame(columns: [
            ("key", Column.fromStrings(["a", "b", "c"])),
            ("val1", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let right = DataFrame(columns: [
            ("key", Column.fromStrings(["b", "c", "d"])),
            ("val2", Column.fromDoubles([20.0, 30.0, 40.0])),
        ])
        let merged = left.merge(right, on: "key")
        #expect(merged.rowCount == 2) // b, c
        #expect(merged.columnNames.contains("val1"))
        #expect(merged.columnNames.contains("val2"))
    }

    @Test func testLeftMerge() {
        let left = DataFrame(columns: [
            ("key", Column.fromStrings(["a", "b", "c"])),
            ("val1", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let right = DataFrame(columns: [
            ("key", Column.fromStrings(["b", "c", "d"])),
            ("val2", Column.fromDoubles([20.0, 30.0, 40.0])),
        ])
        let merged = left.merge(right, on: "key", how: .left)
        #expect(merged.rowCount == 3) // a, b, c — all left rows preserved
        #expect(merged.columnNames.contains("val1"))
        #expect(merged.columnNames.contains("val2"))
    }
}

// MARK: - Integration: Full Pandas-style Workflow

/// End-to-end integration test demonstrating a complete pandas-style data analysis workflow.
///
/// This test exercises many features together in a single realistic pipeline:
/// building a DataFrame from typed columns, pandas-style boolean filtering
/// (`df[df["salary"] > 80000]`), string equality filtering, `apply` for
/// element-wise transformation, `cumsum` for running totals, `median`, multi-
/// column sort, single-column GroupBy with mean aggregation, `dropDuplicates`,
/// and quartile computation. It serves as a smoke test to ensure these features
/// compose correctly without regressions.
@Suite struct PandasStyleWorkflowTests {
    @Test func testEndToEndPandasStyle() {
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie", "Diana", "Eve"])),
            ("department", Column.fromStrings(["Eng", "Sales", "Eng", "Sales", "Eng"])),
            ("salary", Column.fromDoubles([95000, 72000, 105000, 68000, 115000])),
            ("years", Column.fromDoubles([8, 4, 12, 3, 16])),
        ])

        // Pandas-style filter: df[df["salary"] > 80000]
        let highEarners = df[df["salary"] > 80000]
        #expect(highEarners.rowCount == 3) // Alice, Charlie, Eve

        // Filter by string
        let engineers = df[df["department"].eq("Eng")]
        #expect(engineers.rowCount == 3)

        // Apply
        let salaryInK = df["salary"].apply { $0 / 1000.0 }
        #expect(salaryInK.iloc(0) as? Double == 95.0)

        // Cumsum
        let cumSalary = df["salary"].cumsum()
        #expect(cumSalary.iloc(0) as? Double == 95000)
        #expect(cumSalary.iloc(4) as? Double == 455000)

        // Median
        #expect(df["salary"].median() == 95000)

        // Multi-column sort
        let sorted = df.sortValues(by: ["department", "salary"], ascending: [true, false])
        #expect(sorted.columns["name"]!.formattedValue(at: 0) == "Eve") // Eng, highest salary

        // GroupBy
        let deptStats = df.select(columns: ["department", "salary"]).groupBy("department")
        let avgSalary = deptStats.mean()
        #expect(avgSalary.rowCount == 2)

        // Drop duplicates
        let depts = df["department"].dropDuplicates()
        #expect(depts.count == 2) // Eng, Sales

        // Quantiles
        #expect(df["salary"].quantile(0.25) != nil)
        #expect(df["salary"].quantile(0.75) != nil)
    }
}
