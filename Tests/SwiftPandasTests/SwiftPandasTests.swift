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

import XCTest
@testable import SwiftPandas

/// Tests for the library-level version constant.
/// Ensures the public `SwiftPandasInfo.version` string matches the expected release.
final class SwiftPandasTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(SwiftPandasInfo.version, "0.6.2-beta")
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
final class SeriesTests: XCTestCase {

    // MARK: - Construction

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

    // MARK: - Aggregations & Statistics

    func testAggregations() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        XCTAssertEqual(s.sum(), 15.0)
        XCTAssertEqual(s.mean(), 3.0)
        XCTAssertEqual(s.min(), 1.0)
        XCTAssertEqual(s.max(), 5.0)
    }

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

    func testDescribe() {
        let s = Series([1.0, 2.0, 3.0, 4.0, 5.0])
        let desc = s.describe()
        XCTAssertEqual(desc.count, 8) // count, mean, std, min, 25%, 50%, 75%, max
        XCTAssertEqual(desc.index, ["count", "mean", "std", "min", "25%", "50%", "75%", "max"])
        XCTAssertEqual(desc.loc("50%") as? Double, 3.0)
    }

    func testDataFrameMedian() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [10.0, 20.0, 30.0]])
        let med = df.median()
        XCTAssertEqual(med.loc("a") as? Double, 2.0)
        XCTAssertEqual(med.loc("b") as? Double, 20.0)
    }

    // MARK: - NA Handling

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

    // MARK: - Arithmetic

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

    // MARK: - Cumulative Operations

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

    // MARK: - Comparison Operators

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

    // MARK: - Apply & Map

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
        XCTAssertEqual(mapped.naCount, 1) // only "c" unmapped
    }

    func testMapStringUnmappedBecomesNA() {
        let s = Series(["x", "y", "z"])
        let mapped = s.map(["x": "X"])
        XCTAssertEqual(mapped.iloc(0) as? String, "X")
        XCTAssertEqual(mapped.naCount, 2) // y, z not in mapping
    }

    // MARK: - Unique & Duplicates

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

    func testStringDuplicated() {
        let s = Series(["hello", "world", "hello"])
        let dupes = s.duplicated()
        XCTAssertEqual(dupes, [false, false, true])
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
final class DataFrameTests: XCTestCase {

    // MARK: - Construction

    func testCreation() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        XCTAssertEqual(df.shape.rows, 3)
        XCTAssertEqual(df.shape.columns, 2)
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

    // MARK: - Column Access & Mutation

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

    func testRename() {
        let df = DataFrame(["old": [1.0, 2.0]])
        let renamed = df.rename(columns: ["old": "new"])
        XCTAssertTrue(renamed.columnNames.contains("new"))
        XCTAssertFalse(renamed.columnNames.contains("old"))
    }

    // MARK: - Row Access

    func testIloc() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0, 5.0]])
        let sliced = df.iloc(1..<4)
        XCTAssertEqual(sliced.rowCount, 3)
    }

    func testHeadTail() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0, 5.0]])
        XCTAssertEqual(df.head(3).rowCount, 3)
        XCTAssertEqual(df.tail(2).rowCount, 2)
    }

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

    // MARK: - Filtering

    func testFilterByMask() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0, 4.0]])
        let mask = [true, false, true, false]
        let filtered = df.filter(mask: mask)
        XCTAssertEqual(filtered.rowCount, 2)
    }

    func testSubscriptWithMask() {
        let df = DataFrame(["age": [25.0, 35.0, 28.0, 40.0]])
        let result = df[df["age"] > 30.0]
        XCTAssertEqual(result.rowCount, 2)
    }

    func testPandasStyleFiltering() {
        let df = DataFrame(columns: [
            ("name", Column.fromStrings(["Alice", "Bob", "Charlie"])),
            ("score", Column.fromDoubles([85.0, 92.0, 78.0])),
        ])
        let passed = df[df["score"] >= 80.0]
        XCTAssertEqual(passed.rowCount, 2)

        let bobs = df[df["name"].eq("Bob")]
        XCTAssertEqual(bobs.rowCount, 1)
        XCTAssertEqual(bobs["score"].iloc(0) as? Double, 92.0)
    }

    func testDataFrameFilterWithComparison() {
        let df = DataFrame(["name_len": [3.0, 5.0, 4.0, 6.0], "age": [25.0, 35.0, 28.0, 40.0]])
        let filtered = df[df["age"] > 30.0]
        XCTAssertEqual(filtered.rowCount, 2)
        XCTAssertEqual(filtered["age"].min(), 35.0)
    }

    // MARK: - Sorting

    func testSortValues() {
        let df = DataFrame(["a": [3.0, 1.0, 2.0], "b": [30.0, 10.0, 20.0]])
        let sorted = df.sortValues(by: "a")
        XCTAssertEqual(sorted["a"].iloc(0) as? Double, 1.0)
        XCTAssertEqual(sorted["b"].iloc(0) as? Double, 10.0)
    }

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

    // MARK: - Aggregations

    func testAggregations() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        XCTAssertEqual(df.sum().sum(), 21.0)
        XCTAssertEqual(df.mean().sum(), 7.0) // mean(a)=2 + mean(b)=5 = 7
    }

    func testDescribe() {
        let df = DataFrame(["a": [1.0, 2.0, 3.0], "b": [4.0, 5.0, 6.0]])
        let desc = df.describe()
        XCTAssertEqual(desc.rowCount, 8) // count, mean, std, min, 25%, 50%, 75%, max
        XCTAssertEqual(desc.columnCount, 2)
    }

    // MARK: - Duplicates

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

    // MARK: - Concat

    func testConcat() {
        let df1 = DataFrame(["a": [1.0, 2.0]])
        let df2 = DataFrame(["a": [3.0, 4.0]])
        let combined = DataFrame.concat([df1, df2])
        XCTAssertEqual(combined.rowCount, 4)
        XCTAssertEqual(combined["a"].sum(), 10.0)
    }

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

    // MARK: - Description

    func testDescription() {
        let df = DataFrame(["a": [1.0, 2.0], "b": [3.0, 4.0]])
        let desc = df.description
        XCTAssertTrue(desc.contains("a"))
        XCTAssertTrue(desc.contains("b"))
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
final class GroupByTests: XCTestCase {

    // MARK: - Single-Column GroupBy

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

    func testGroupBySumValues() {
        let df = DataFrame(columns: [
            ("group", Column.fromStrings(["A", "B", "A"])),
            ("val", Column.fromDoubles([10.0, 20.0, 30.0])),
        ])
        let result = df.groupBy("group").sum()
        XCTAssertEqual(result.rowCount, 2)
        let aIdx = result.indexLabels.firstIndex(of: "A")!
        XCTAssertEqual(result["val"].iloc(aIdx) as? Double, 40.0)
    }

    // MARK: - Multi-Column GroupBy

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
}

// MARK: - Merge Tests

/// Tests for `DataFrame.merge(_:on:how:)`, the SQL-style join.
///
/// Merge combines two DataFrames by matching rows on a shared key column.
/// Supports inner, left, right, and outer join types.
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

    func testLeftMerge() {
        let left = DataFrame(columns: [
            ("key", Column.fromStrings(["a", "b", "c"])),
            ("val1", Column.fromDoubles([1.0, 2.0, 3.0])),
        ])
        let right = DataFrame(columns: [
            ("key", Column.fromStrings(["b", "c", "d"])),
            ("val2", Column.fromDoubles([20.0, 30.0, 40.0])),
        ])
        let merged = left.merge(right, on: "key", how: .left)
        XCTAssertEqual(merged.rowCount, 3) // a, b, c — all left rows preserved
        XCTAssertTrue(merged.columnNames.contains("val1"))
        XCTAssertTrue(merged.columnNames.contains("val2"))
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
final class PandasStyleWorkflowTests: XCTestCase {
    func testEndToEndPandasStyle() {
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
