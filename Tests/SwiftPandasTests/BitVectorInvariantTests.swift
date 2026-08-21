// ===----------------------------------------------------------------------===//
//
// BitVectorInvariantTests.swift
// SwiftPandasTests
//
// Background: https://github.com/kiraa-ai/kiraa-swift-pandas/issues/18
//
// ## The invariant under test
//
// `BitVector` is the validity bitmap beneath every nullable column: bit *i*
// set means row *i* holds a value, cleared means row *i* is NA. The property
// `BitVector.allValid` answers "are all bits set?". It must agree with the
// bits on every call. `allValid == true` while any bit is cleared is never
// acceptable, no matter how the bitmap was produced.
//
// ## Why this matters
//
// Roughly 36 fast paths in the library branch on `allValid` and, when it is
// `true`, skip reading the bitmap entirely. The worst of them —
// `NullableArray.take(indices:)`, `take(mask:trueCount:)`, and
// `BitVector.concat` — go further and *manufacture a fresh all-ones bitmap*
// for their result. So a wrong `true` is not a slow path; it permanently
// erases every NA in the column. Whatever value happens to sit under the NA
// bit is promoted to a real value in sorts, filters, group-bys, CSV output,
// and statistics, with no error or warning.
//
// The operators `&`, `|`, `~` and `concat` are the places where a bitmap is
// derived from other bitmaps, which makes them the natural places for
// `allValid` and the bits to drift apart. `NullableArray`'s `+ - * /` build
// their result mask as `lhs.mask & rhs.mask`, so `&` in particular sits under
// every piece of column arithmetic in the library.
//
// ## How to read this file
//
// - "Unit" tests exercise `BitVector` directly and assert that `allValid`,
//   `popcount`, and the individual bits tell the same story.
// - "End to end" tests build one tiny frame whose NA was produced by column
//   arithmetic and push it through each bulk operation that trusts
//   `allValid`, asserting the NA is still there on the other side.
// - Two tests are labelled "control". They pin behaviour that is correct by
//   construction and must stay that way: the element-wise read path, and the
//   `|` operator (which can only set bits).
//
// ===----------------------------------------------------------------------===//

import XCTest
@testable import SwiftPandas

/// Verifies that `BitVector.allValid` always agrees with the bitmap, and that
/// an NA produced by column arithmetic survives every bulk operation.
///
/// See the file header for the invariant and why it matters.
final class BitVectorInvariantTests: XCTestCase {

    // MARK: - Fixture constants

    /// Bit count small enough to reason about by hand; fits in one 64-bit word.
    private static let smallBitCount = 4

    /// Bit count that spans two full 64-bit words plus a 2-bit tail
    /// (`130 = 64 + 64 + 2`). Exercises the multi-word loop and the
    /// "clear the padding bits in the last word" branch of the operators.
    private static let multiWordBitCount = 130

    /// Index of the row that carries the NA in the end-to-end fixture frame
    /// (see `makeFrameWithDerivedNA()`). Zero-based.
    private static let naRow = 1

    // MARK: - Unit: `&`

    /// `all-valid & mask-with-one-NA` must report `allValid == false`.
    ///
    /// This is the exact mask that `NullableArray.+` produces when one operand
    /// has no NAs and the other has one, so it is the most common shape a
    /// derived bitmap takes in practice. The test checks the bit, the
    /// popcount, and `allValid` together: all three must agree that exactly
    /// one row is NA.
    ///
    /// Guards against `&` deriving its `allValid` answer from either operand
    /// instead of from the bits it actually produced.
    func test_and_withAllValidLhs_reportsNotAllValid() {
        // Given: an all-valid mask, and a mask with exactly one NA at `naRow`
        let allValid = BitVector(repeating: true, count: Self.smallBitCount)
        var hasNA = BitVector(repeating: true, count: Self.smallBitCount)
        hasNA[Self.naRow] = false

        // When: they are ANDed (the result-mask rule for binary arithmetic)
        let anded = allValid & hasNA

        // Then: the bit, the popcount, and `allValid` all agree that one row is NA
        XCTAssertFalse(anded[Self.naRow], "the NA bit itself must be cleared")
        XCTAssertEqual(anded.popcount, Self.smallBitCount - 1, "exactly one bit should be cleared")
        XCTAssertFalse(anded.allValid, "allValid must not claim all bits are set when one is cleared")
    }

    /// Same as the single-word case, but across two full words and an
    /// unaligned tail, with a cleared bit in each region.
    ///
    /// Guards against `allValid` being derived from a subset of the words
    /// (first word only, last word only, full words only) rather than all of
    /// them.
    func test_and_multiWordUnalignedTail_reportsNotAllValid() {
        // Given: three NAs — one in word 0, one in word 1, one in the 2-bit tail
        let clearedBits = [0, 70, Self.multiWordBitCount - 1]
        let allValid = BitVector(repeating: true, count: Self.multiWordBitCount)
        var hasNA = BitVector(repeating: true, count: Self.multiWordBitCount)
        for bit in clearedBits {
            hasNA[bit] = false
        }

        // When
        let anded = allValid & hasNA

        // Then
        XCTAssertEqual(anded.popcount, Self.multiWordBitCount - clearedBits.count)
        XCTAssertFalse(anded.allValid)
    }

    // MARK: - Unit: `~`

    /// `~all-valid` is all-NA and must say so through every accessor.
    ///
    /// Inversion is the one operator that can take a bitmap from "every bit
    /// set" to "no bit set" in a single step, so it is the strongest check
    /// that `allValid` is computed from the result rather than carried over
    /// from the operand. `popcount`, `allValid`, and `allNA` must agree.
    ///
    /// Guards against prefix `~` reporting its operand's `allValid` answer
    /// for a result that has no set bits at all.
    func test_not_ofAllValid_reportsNotAllValid() {
        // Given: an all-valid mask
        let allValid = BitVector(repeating: true, count: Self.smallBitCount)

        // When: every bit is inverted
        let inverted = ~allValid

        // Then: no bit is set, and every way of asking agrees
        XCTAssertEqual(inverted.popcount, 0, "inverting all-ones must clear every bit")
        XCTAssertFalse(inverted.allValid, "a mask with zero set bits cannot be all-valid")
        XCTAssertTrue(inverted.allNA)
    }

    // MARK: - Unit: `|` control

    /// CONTROL — `all-valid | anything` genuinely is all-valid and must
    /// report so.
    ///
    /// OR can only set bits, never clear them, so an all-valid left operand
    /// always yields an all-valid result. This test pins that `allValid` is
    /// not pessimistic: a bitmap whose bits are all set must answer `true`,
    /// not a conservative `false`. Without it, the other tests in this file
    /// could be satisfied by an `allValid` that simply always returns `false`.
    func test_or_withAllValidLhs_staysAllValid() {
        // Given: an all-valid mask and a mask with one NA
        let allValid = BitVector(repeating: true, count: Self.smallBitCount)
        var hasNA = BitVector(repeating: true, count: Self.smallBitCount)
        hasNA[Self.naRow] = false

        // When: they are ORed
        let ored = allValid | hasNA

        // Then: the NA is filled in and the result really is all-valid
        XCTAssertEqual(ored.popcount, Self.smallBitCount)
        XCTAssertTrue(ored.allValid)
    }

    // MARK: - Unit: `concat`

    /// `BitVector.concat` has a fast path: if every input reports `allValid`,
    /// it returns a brand-new all-ones bitmap without copying any bits. That
    /// fast path is only safe if every input's `allValid` is truthful.
    ///
    /// The NA input is deliberately produced by `&` rather than by the
    /// subscript setter, so that `concat` receives a bitmap that came out of
    /// an operator — the kind of input it sees when concatenating columns
    /// that were themselves computed.
    ///
    /// Guards against `concat` taking its fabricate-all-ones fast path on an
    /// input that contains a cleared bit.
    func test_concat_ofAllValidAndMaskWithNA_reportsNotAllValid() {
        // Given: a 5-bit all-valid mask, and a 3-bit mask with an NA at bit 0
        //        that was produced by `&`
        let leadingBits = 5
        let trailingBits = 3
        var hasNA = BitVector(repeating: true, count: trailingBits)
        hasNA[0] = false
        let derivedMask = BitVector(repeating: true, count: trailingBits) & hasNA

        // When: they are concatenated — the NA should land at index 5
        let joined = BitVector.concat([BitVector(repeating: true, count: leadingBits), derivedMask])
        let expectedNAIndex = leadingBits

        // Then: the NA is present in the joined bitmap and `allValid` knows it
        XCTAssertEqual(joined.bitCount, leadingBits + trailingBits)
        XCTAssertEqual(joined.popcount, leadingBits + trailingBits - 1, "concat must carry the NA across")
        XCTAssertFalse(joined[expectedNAIndex])
        XCTAssertFalse(joined.allValid)
    }

    // MARK: - Unit: Equatable

    /// Two bitmaps with identical bits must compare equal regardless of how
    /// they were constructed.
    ///
    /// `BitVector` is a value type whose identity is its bits and its length.
    /// `BitVector(repeating: true, count: n)` and a `BitVector` built from an
    /// array of `n` `true`s describe the same bitmap and must be `==`. Any
    /// additional stored state that participates in equality would make
    /// equal bitmaps compare unequal, which is a surprise that is very hard
    /// to diagnose from a failing assertion elsewhere.
    ///
    /// Guards against `==` considering anything other than the bits and the
    /// bit count.
    func test_equatable_ignoresHowTheMaskWasBuilt() {
        // Given: the same four set bits, built two different ways
        let builtByRepeating = BitVector(repeating: true, count: Self.smallBitCount)
        let builtFromBools = BitVector([Bool](repeating: true, count: Self.smallBitCount))

        // Then: they are equal
        XCTAssertEqual(builtByRepeating, builtFromBools)
    }

    // MARK: - End-to-end fixture

    /// Builds the smallest frame that carries an NA produced by arithmetic.
    ///
    /// Columns:
    /// - `a` — four plain doubles, no NAs. Its mask is all-valid.
    /// - `b` — four doubles with an NA at row `naRow` (index 1). Built from an
    ///   optional array, so its mask is set bit-by-bit at construction.
    /// - `t` — `a + b`. Row `naRow` is NA because `b` is NA there. Its mask
    ///   is computed as `a.mask & b.mask`, which makes `t` the column whose
    ///   validity depends on the `&` operator telling the truth.
    ///
    /// Reading `t` element by element yields `[13.5, nil, 20.2, 21.3]`. The
    /// values are chosen so every result is distinct and a leaked placeholder
    /// (`14.0`, i.e. `14 + 0`) is immediately recognisable in a failure
    /// message.
    ///
    /// - Returns: A `DataFrame` with columns `a`, `b`, `t` and four rows.
    private func makeFrameWithDerivedNA() -> DataFrame {
        var df = DataFrame()
        df["a"] = Series([13.0, 14.0, 20.0, 21.0], name: "a")
        df["b"] = Series([0.5, nil, 0.2, 0.3], name: "b")
        df["t"] = df["a"] + df["b"]
        return df
    }

    /// Reads every element of a numeric `Series` as `Double?`, with `nil` for NA.
    ///
    /// `Series`'s positional subscript returns `Any?`; this helper narrows it
    /// so the assertions below can compare against plain `[Double?]` literals.
    ///
    /// - Parameter series: A `.double` column.
    /// - Returns: One entry per row; `nil` where the row is NA.
    private func doubles(_ series: Series) -> [Double?] {
        (0..<series.count).map { series[$0] as? Double }
    }

    // MARK: - End to end: the derived NA must survive every bulk operation

    /// CONTROL — reading the derived column one element at a time shows the NA.
    ///
    /// The per-element read path consults the bitmap bit by bit and never
    /// asks `allValid`, so it is the ground truth the bulk-operation tests
    /// below are compared against. If this test fails, the fixture itself is
    /// wrong and the other end-to-end results cannot be interpreted.
    func test_derivedNA_isVisibleElementwise() {
        // Given / When
        let df = makeFrameWithDerivedNA()

        // Then
        XCTAssertEqual(doubles(df["t"]), [13.5, nil, 20.2, 21.3])
    }

    /// Sorting routes every column through `NullableArray.take(indices:)`,
    /// whose `allValid` fast path returns a fresh all-ones mask instead of
    /// gathering the source bits.
    ///
    /// Sorting by `a` (already ascending) leaves row order unchanged, so the
    /// only thing that can differ from the element-wise read is the gather
    /// dropping the NA.
    ///
    /// Guards against the sort gather discarding the NA of an
    /// arithmetic-derived column.
    func test_derivedNA_survivesSort() {
        // Given
        let df = makeFrameWithDerivedNA()

        // When: rows are gathered by sort order (identity order here)
        let sorted = df.sortValues(by: ["a"])

        // Then: the NA is still at the same position
        XCTAssertEqual(doubles(sorted["t"]), [13.5, nil, 20.2, 21.3])
    }

    /// Boolean filtering routes columns through `take(mask:trueCount:)`, whose
    /// `allValid` fast path also returns a fresh all-ones mask.
    ///
    /// The predicate `a > 13.0` keeps rows 1–3, so the NA row becomes the
    /// first surviving row.
    ///
    /// Guards against the filter gather discarding the NA of an
    /// arithmetic-derived column.
    func test_derivedNA_survivesBooleanFilter() {
        // Given
        let df = makeFrameWithDerivedNA()

        // When: rows where `a > 13` are kept (drops row 0 only)
        let filtered = df[df["a"] > 13.0]

        // Then: the NA row survives as the first row
        XCTAssertEqual(doubles(filtered["t"]), [nil, 20.2, 21.3])
    }

    /// GroupBy aggregation uses `allValid` to choose an unchecked accumulation
    /// loop that never looks at the bitmap.
    ///
    /// Grouping by `a` gives one row per group. The group keyed `14.0`
    /// contains exactly one row, whose `t` is NA — so the mean of `t` for that
    /// group has no valid inputs and must itself be NA.
    ///
    /// Guards against the aggregate counting an NA row's stored placeholder
    /// as a real value.
    func test_derivedNA_isExcludedFromGroupByMean() {
        // Given
        let df = makeFrameWithDerivedNA()
        let naGroupKey = 14.0

        // When: grouped by `a` and averaged. Group keys become index labels.
        let means = df.groupBy("a").mean()

        // Then: the single-row NA group has an NA mean
        let labels = means.indexLabels
        guard let row = labels.firstIndex(where: { Double($0) == naGroupKey }) else {
            return XCTFail("groupBy result has no group keyed \(naGroupKey); labels were \(labels)")
        }
        XCTAssertNil(doubles(means["t"])[row], "a group whose only row is NA must have an NA mean")
    }

    /// The CSV writer uses `allValid` to choose a formatter that never checks
    /// the bitmap. Unlike the gather-based tests above, no row movement is
    /// involved here: the writer simply formats each cell in order, so this
    /// is the most direct observation of whether `allValid` is truthful.
    ///
    /// Row 2 of the output (after the header) is the NA row: `a=14`, `b` empty,
    /// and `t` must also be empty.
    ///
    /// Guards against the writer printing a value into a cell whose row is NA.
    func test_derivedNA_rendersAsEmptyCellInCSV() {
        // Given
        let df = makeFrameWithDerivedNA()
        let headerLine = 0
        let naLine = headerLine + 1 + Self.naRow

        // When
        let csvLines = df.toCSV().split(separator: "\n").map(String.init)

        // Then
        XCTAssertEqual(csvLines[headerLine], "a,b,t")
        XCTAssertEqual(csvLines[naLine], "14,,", "the NA cell in column t must be empty")
    }

    /// SPB (SwiftPandas Binary) is the durable on-disk format. Its writer uses
    /// `allValid` to stream the raw data buffer instead of a null-zeroed copy,
    /// and its reader rejects any file in which an NA cell has a non-zero
    /// payload. A column whose `allValid` disagrees with its bits therefore
    /// produces a file the reader refuses to load.
    ///
    /// Guards against an arithmetic-derived NA being written with a non-zero
    /// payload, or not surviving the round trip.
    ///
    /// - Throws: Re-throws any SPB write/read error so it is reported as a failure.
    func test_derivedNA_roundTripsThroughSPB() throws {
        // Given: a unique temp file, removed on every exit path
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitvector-invariant-\(UUID().uuidString).spb")
        defer { try? FileManager.default.removeItem(at: url) }
        let df = makeFrameWithDerivedNA()

        // When
        try df.writeSPB(to: url)
        let roundTripped = try DataFrame.readSPB(from: url)

        // Then
        XCTAssertEqual(doubles(roundTripped["t"]), [13.5, nil, 20.2, 21.3])
    }

    /// `-`, `*`, and `/` build their result mask the same way `+` does
    /// (`lhs.mask & rhs.mask`). This test pins each one with a single
    /// assertion per operator so a regression is attributed to the operator
    /// that caused it.
    ///
    /// The frame is sorted *descending* by `a` so the gather is a genuine
    /// permutation (not the identity), which moves the NA row from index 1 to
    /// index 2. Each operator leaves a different placeholder under the NA bit
    /// (`14 - 0 = 14`, `14 * 0 = 0`, `14 / 0 = inf`), so a failure message
    /// also reveals which value leaked.
    ///
    /// Guards against any of the three operators producing a bitmap whose
    /// `allValid` disagrees with its bits.
    func test_derivedNA_survivesSort_forAllArithmeticOperators() {
        // Given: one derived column per remaining operator
        var df = makeFrameWithDerivedNA()
        df["difference"] = df["a"] - df["b"]
        df["product"] = df["a"] * df["b"]
        df["quotient"] = df["a"] / df["b"]
        let naRowAfterDescendingSort = 2

        // When: a non-identity gather
        let sorted = df.sortValues(by: ["a"], ascending: [false])

        // Then: each operator's NA is still an NA
        XCTAssertNil(doubles(sorted["difference"])[naRowAfterDescendingSort], "subtraction-derived NA erased")
        XCTAssertNil(doubles(sorted["product"])[naRowAfterDescendingSort], "multiplication-derived NA erased")
        XCTAssertNil(doubles(sorted["quotient"])[naRowAfterDescendingSort], "division-derived NA erased")
    }
}
