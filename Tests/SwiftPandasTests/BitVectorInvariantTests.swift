// ===----------------------------------------------------------------------===//
//
// BitVectorInvariantTests.swift
// SwiftPandasTests
//
// Acceptance tests for GitHub issue #18:
// https://github.com/kiraa-ai/kiraa-swift-pandas/issues/18
//
// ## The invariant under test
//
// `BitVector` is the validity bitmap beneath every nullable column: bit *i*
// set means row *i* holds a value, cleared means row *i* is NA. The property
// `BitVector.allValid` answers "are all bits set?". It MUST agree with the
// bits on every call — there is no situation in which `allValid == true` and
// some bit is cleared is acceptable.
//
// ## Why this matters
//
// Roughly 36 fast paths in the library branch on `allValid` and, when it is
// `true`, skip reading the bitmap entirely. The worst of them —
// `NullableArray.take(indices:)`, `take(mask:trueCount:)`, and
// `BitVector.concat` — go further and *manufacture a fresh all-ones bitmap*
// for their result. So a wrong `true` is not a slow path; it permanently
// erases every NA in the column. The placeholder value stored under the NA
// bit (whatever the arithmetic happened to compute) is promoted to a real
// value in sorts, filters, group-bys, CSV output, and statistics.
//
// ## The defect these tests were written against (v0.8.0-beta)
//
// `allValid` consulted a cached flag, `_knownAllValid`, that had to be reset
// by hand in every mutator. The `&` and prefix `~` operators forgot to reset
// it. Because `NullableArray`'s `+ - * /` build their result mask with
// `lhs.mask & rhs.mask`, any arithmetic against an all-valid operand produced
// a mask whose bits were right but whose `allValid` lied.
//
// ## How to read this file
//
// - "Unit" tests exercise `BitVector` directly and assert that `allValid`,
//   `popcount`, and the individual bits tell the same story.
// - "End to end" tests build one tiny frame with an operator-derived NA and
//   push it through each bulk operation that trusts `allValid`, asserting the
//   NA is still there on the other side.
// - Two tests are labelled "control". They pass both before and after the
//   fix; they exist to pin behaviour that the fix must not disturb.
//
// These tests were written first and run RED before any production change
// (TDD). If one of them fails in the future, the cached-flag bug — or a new
// bug of the same shape — has come back.
//
// ===----------------------------------------------------------------------===//

import XCTest
@testable import SwiftPandas

/// Verifies that `BitVector.allValid` can never disagree with the bitmap, and
/// that an NA produced by column arithmetic survives every bulk operation.
///
/// See the file header for the full background on issue #18.
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

    // MARK: - Unit: `&` must not report all-valid after clearing a bit

    /// `all-valid & mask-with-one-NA` must report `allValid == false`.
    ///
    /// This is the exact mask that `NullableArray.+` produces when one operand
    /// has no NAs and the other has one — the most common way the defect in
    /// issue #18 was reached.
    ///
    /// - Fails when: `allValid` returns a cached answer inherited from the
    ///   left-hand operand instead of re-deriving it from the ANDed bits.
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
    /// Guards against a fix that only inspects the first (or last) word.
    ///
    /// - Fails when: `allValid` is cached, or is derived from a subset of the
    ///   words rather than all of them.
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

    // MARK: - Unit: `~` must not report all-valid after inverting all-ones

    /// `~all-valid` is all-NA and must say so.
    ///
    /// This is the most extreme form of the defect: before the fix the result
    /// had `popcount == 0` *and* `allValid == true` at the same time.
    ///
    /// - Fails when: prefix `~` copies a cached "all valid" answer from its
    ///   operand instead of deriving the answer from the inverted bits.
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

    /// CONTROL — `all-valid | anything` genuinely is all-valid, and must keep
    /// reporting so after the fix.
    ///
    /// OR can only set bits, never clear them, so this operator was correct
    /// even with the cached flag. The test exists so a fix cannot accidentally
    /// make `|` *pessimistic* (e.g. by returning `false` unconditionally).
    ///
    /// - Fails when: `allValid` returns `false` for a mask whose bits are all set.
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

    // MARK: - Unit: `concat` must not fabricate an all-ones result

    /// `BitVector.concat` has a fast path: if every input reports `allValid`,
    /// it returns a brand-new all-ones bitmap without copying any bits. Feed
    /// it an input whose `allValid` is wrong and the NA is gone for good.
    ///
    /// The NA input is deliberately built through `&` so that it carries the
    /// stale answer the defect produced; building it with the subscript setter
    /// would not reproduce the bug.
    ///
    /// - Fails when: an input mask reports `allValid == true` despite a cleared
    ///   bit, causing `concat` to take its fabricate-all-ones fast path.
    func test_concat_ofAllValidAndMaskWithNA_reportsNotAllValid() {
        // Given: a 5-bit all-valid mask, and a 3-bit mask with an NA at bit 0
        //        that was produced by `&` (so it is "stale" under the old code)
        let leadingBits = 5
        let trailingBits = 3
        var hasNA = BitVector(repeating: true, count: trailingBits)
        hasNA[0] = false
        let staleMask = BitVector(repeating: true, count: trailingBits) & hasNA

        // When: they are concatenated — the NA should land at index 5
        let joined = BitVector.concat([BitVector(repeating: true, count: leadingBits), staleMask])
        let expectedNAIndex = leadingBits

        // Then: the NA is present in the joined bitmap and `allValid` knows it
        XCTAssertEqual(joined.bitCount, leadingBits + trailingBits)
        XCTAssertEqual(joined.popcount, leadingBits + trailingBits - 1, "concat must carry the NA across")
        XCTAssertFalse(joined[expectedNAIndex])
        XCTAssertFalse(joined.allValid)
    }

    // MARK: - Unit: Equatable

    /// Two masks with identical bits must compare equal regardless of how they
    /// were constructed.
    ///
    /// `BitVector`'s `==` is synthesized over its stored properties. With a
    /// cached flag as a stored property, `BitVector(repeating: true, count: 4)`
    /// (flag `true`) and `BitVector([true, true, true, true])` (flag `false`)
    /// compared *unequal* despite having the same bits — a second symptom of
    /// the same cache. No production code observed this, but it is the kind
    /// of surprise that costs hours when it finally does.
    ///
    /// - Fails when: `==` considers any state other than the bits and the count.
    func test_equatable_ignoresHowTheMaskWasBuilt() {
        // Given: the same four set bits, built two different ways
        let builtByRepeating = BitVector(repeating: true, count: Self.smallBitCount)
        let builtFromBools = BitVector([Bool](repeating: true, count: Self.smallBitCount))

        // Then: they are equal
        XCTAssertEqual(builtByRepeating, builtFromBools)
    }

    // MARK: - End-to-end fixture

    /// Builds the smallest frame that reproduces issue #18.
    ///
    /// Columns:
    /// - `a` — four plain doubles, no NAs. Its mask is all-valid.
    /// - `b` — four doubles with an NA at row `naRow` (index 1). Built from an
    ///   optional array, so its mask is correct by construction.
    /// - `t` — `a + b`. Row `naRow` is NA because `b` is NA there. Under the
    ///   defect, `t`'s mask has the right bits but reports `allValid == true`,
    ///   because it was computed as `a.mask & b.mask`.
    ///
    /// Reading `t` element by element returns `[13.5, nil, 20.2, 21.3]` both
    /// before and after the fix; the bug only shows up when a bulk operation
    /// trusts `allValid`. The values are chosen so every result is distinct
    /// and the erased placeholder (`14.0`, i.e. `14 + 0`) is easy to spot.
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
    /// This passes before and after the fix. It documents that the defect was
    /// invisible to element-wise reads, which is why it went unnoticed, and
    /// pins the baseline the remaining tests compare against.
    ///
    /// - Fails when: the per-element read path stops consulting the bitmap.
    func test_derivedNA_isVisibleElementwise() {
        // Given / When
        let df = makeFrameWithDerivedNA()

        // Then
        XCTAssertEqual(doubles(df["t"]), [13.5, nil, 20.2, 21.3])
    }

    /// Sorting routes every column through `NullableArray.take(indices:)`,
    /// whose `allValid` fast path returns a fresh all-ones mask.
    ///
    /// Sorting by `a` (already ascending) leaves row order unchanged, so any
    /// difference from the element-wise read is the gather erasing the NA.
    ///
    /// - Fails when: the gather trusts a wrong `allValid` and drops the NA
    ///   (observed under the defect: `14.0` where `nil` belongs).
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
    /// The predicate `a > 13.0` keeps rows 1–3, so the NA row is the first
    /// surviving row.
    ///
    /// - Fails when: the filter gather trusts a wrong `allValid` and drops the NA.
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
    /// - Fails when: the aggregate treats the NA row's placeholder as a real
    ///   value (observed under the defect: mean `14.0`).
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
    /// the bitmap. A wrong `true` prints the placeholder into the cell that
    /// should be empty — with *no gather involved*, so this is the simplest
    /// user-visible form of the bug.
    ///
    /// Row 2 of the output (after the header) is the NA row: `a=14`, `b` empty,
    /// and `t` must also be empty.
    ///
    /// - Fails when: the writer prints a value for an NA cell
    ///   (observed under the defect: `14,,14` instead of `14,,`).
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
    /// and its reader rejects any file where an NA cell has a non-zero payload.
    ///
    /// Under the defect the writer emitted NA-bit + non-zero payload and the
    /// reader threw `corrupt SPB data … null cell has non-zero payload`. After
    /// the fix the round trip must succeed and preserve the NA.
    ///
    /// - Fails when: `writeSPB` trusts a wrong `allValid` (read throws), or the
    ///   NA does not survive the round trip.
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
    /// (`lhs.mask & rhs.mask`), so all three carried the defect. This test
    /// pins each one with a single assertion per operator.
    ///
    /// The frame is sorted *descending* by `a` so the gather is a genuine
    /// permutation (not the identity), which moves the NA row from index 1 to
    /// index 2. The placeholder each operator leaves under the NA bit differs
    /// (`14 - 0 = 14`, `14 * 0 = 0`, `14 / 0 = inf`) and is named in the
    /// failure message to make a regression easy to attribute.
    ///
    /// - Fails when: any of the three operators produces a mask whose
    ///   `allValid` is wrong, so the sort gather erases its NA.
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
