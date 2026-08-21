# Design: `BitVector.allValid` staleness (issue #18)

Status: **DESIGN 1 LOCKED** (review on PR #19, 2026-08-21). Tests written RED — see below. Implementation plan pending explicit go-ahead.
Issue: https://github.com/kiraa-ai/kiraa-swift-pandas/issues/18

## What the issue is

`BitVector` is the validity bitmap under every nullable column. It keeps a cached Bool, `_knownAllValid`, so `allValid` can answer in O(1). The cache is a one-way latch maintained by convention: every mutator that can clear a bit must reset it. Two operators don't — `&` and prefix `~` copy the struct (flag included) and mutate `words` directly. The result is a mask whose bits say "row 1 is NA" while `allValid` says `true`.

`NullableArray.+ - * /` build their result mask with `lhs.mask & rhs.mask`, so one all-valid operand poisons every operator-derived column. Downstream, ~36 fast paths trust `allValid`; the worst — `take(indices:)`, `take(mask:)`, `concat` — manufacture a fresh all-ones mask on the `true` branch, erasing the NA permanently. Symptom: `df["t"] = df["a"] + df["b"]` reads correctly element-by-element, then `sortValues`, boolean filter, `groupBy.mean()` and `toCSV()` surface the raw payload (`14.0`, or `inf` for `/`) where `nil` belongs. SPB write+read throws `corrupt` instead.

All claims in the issue were reproduced verbatim (package-only repro, v0.8.0-beta).

**What we are designing:** how `BitVector` answers `allValid` so that a stale answer is impossible — not merely patched in the two operators found today.

## Code in question

`Sources/SwiftPandas/Core/Missing/BitVector.swift`

| Lines | What | Role in the defect |
|---|---|---|
| 94–103 | `internal var _knownAllValid: Bool` + doc: "one-way latch toward `false`", reset "by any operation that might introduce a zero bit" | The convention. Only three writers exist in the whole repo: `:121` (`init(repeating:)`), `:148` (`init([Bool])` → `false`), `:183` (subscript set), `:326` (`append`). |
| 222–225 | `allValid` — `if _knownAllValid { return true }; return popcount == bitCount` | Sole reader of the flag. Trusts it unconditionally. |
| 258–265 | `static func &` — `var result = lhs; result.words[i] &= rhs.words[i]` | Copies `lhs._knownAllValid`; AND can clear bits; never resets. **Bug.** |
| 295–306 | `prefix static func ~` — `var result = bv; result.words[i] = ~…` | Copies the flag; NOT of all-ones is all-zeros; never resets. **Bug** (worse: `popcount == 0` with `allValid == true`). |
| 276–283 | `static func \|` | Same shape; safe only because OR can't clear a bit. |
| 375 | `concat` fast path: `if vectors.allSatisfy({ $0.allValid }) { return BitVector(repeating: true, …) }` | Amplifier not named in the issue — fabricates all-ones from a stale input. |
| 78 | `public struct BitVector: Sendable, Equatable` — synthesized `==` | Latent second bug: `==` compares the flag too, so `BitVector(repeating: true, count: 4) != BitVector([true,true,true,true])`. Nothing observes this today (`NullableArray.==` is bit-wise), but it is the same cache leaking. |

Why it's the issue, technically: the invariant "flag ⇒ all bits set" lives in a comment, not in the type. `words` is `internal var`, so any code in the module — including two operators in the same file — can break the invariant with a one-line word write. Consumers can't defend themselves: `take(indices:)` (`NullableArray.swift:360`) and `take(mask:trueCount:)` (`:415`) return `BitVector(repeating: true, count: n)` on the fast path, so a wrong `true` is unrecoverable.

Facts from exploration that constrain the design:

- **`allValid` is never hot.** All 36 call sites are evaluated once per column per operation (zero per-row sites; comparisons and `valueCounts` hoist it above their loops; reductions already pay a full `popcount` via `validCount` one line earlier). The largest realistic cost of O(n/64) is ~6 extra popcounts of ~15.6K words on a 1M×6 frame — tens of microseconds against ms-scale ops.
- **`popcount` is already uncached** (`:203`) and is the baseline everywhere else (`naCount`, `allNA`, `validCount`).
- **Every external `.words` use is a read** (`NullableArray.swift:217`, `MetalGroupBy.swift:252`, `SPBWriter.swift:110`, `VectorArray.swift:51`), so `private(set)` compiles with zero call-site changes.
- **No existing test can observe the bug**: `testBitwiseAnd/Or/Not` (`SwiftPandasTests.swift:266–284`) build operands with `BitVector([Bool])`, whose flag is already `false`.
- Two doc comments advertise the O(1) cache: `PandasArray.swift:182–183` ("shadow this default with an O(1) property"), `BitVector.swift:47–51` (file header).

---

## Proposed Design 1 — Delete the cache; `allValid` is derived

Make the stale state unrepresentable. `allValid` becomes a pure function of `words`, like `popcount`, `naCount` and `allNA` already are.

### `Sources/SwiftPandas/Core/Missing/BitVector.swift`

**Remove** lines 94–103 (declaration + doc):

```swift
// BEFORE
    /// A cached optimization flag indicating whether all bits are known to be
    /// set (all valid).
    /// … (doc)
    internal var _knownAllValid: Bool
```
```swift
// AFTER
    (deleted)
```

**Change** `allValid`, lines 217–225:

```swift
// BEFORE
    /// Whether every element is valid (no NAs present).
    ///
    /// Returns `true` immediately if the `_knownAllValid` cache flag is set;
    /// otherwise falls back to comparing `popcount == bitCount`.
    ///
    /// - Complexity: O(1) when cached, O(*n* / 64) otherwise.
    public var allValid: Bool {
        if _knownAllValid { return true }
        return popcount == bitCount
    }
```
```swift
// AFTER
    /// Whether every element is valid (no NAs present).
    ///
    /// Derived from the words on every call — there is no cached flag, so
    /// this can never disagree with the bits (see issue #18).
    ///
    /// - Complexity: O(*n* / 64) where *n* is `bitCount` (hardware popcount).
    public var allValid: Bool {
        popcount == bitCount
    }
```

**Remove** the four flag writes (one line each):

| Line | Before | After |
|---|---|---|
| 121 | `self._knownAllValid = value` | (deleted) |
| 148 | `self._knownAllValid = false` | (deleted) |
| 183 | `if !newValue { _knownAllValid = false }` | (deleted) |
| 326 | `_knownAllValid = false` | (deleted) |

**Remove** the now-false doc notes: file header bullet at lines 47–51 ("`_knownAllValid` is a cached flag…") and the `- Note:` on `init(_ bools:)` at lines 142–145.

**Unchanged:** `&`, `|`, `~`, `concat`, `take`. With no cache there is nothing for them to forget; `concat`'s fast path at `:375` becomes correct because its input is now correct.

### `Sources/SwiftPandas/Core/Array/PandasArray.swift:182–183`

```swift
// BEFORE
    /// ``NullableArray``, which delegates to ``BitVector.popcount``) shadow
    /// this default with an O(1) property.
```
```swift
// AFTER
    /// ``NullableArray``, which delegates to ``BitVector.popcount``) shadow
    /// this default with an O(*n* / 64) word-wise popcount.
```

### Tests — `Tests/SwiftPandasTests/BitVectorInvariantTests.swift` (committed on this branch, RED)

Written first, per TDD, against unmodified v0.8.0-beta. The file is in this PR; the full source is reproduced here for review.

```swift
import XCTest
@testable import SwiftPandas

/// Acceptance tests for issue #18: `BitVector.allValid` must never disagree
/// with the bits. Written RED against v0.8.0-beta (the `&` / `~` operators
/// leave the `_knownAllValid` latch stale) before any production change.
///
/// Every test here names the production change that makes it fail: a cached
/// all-valid answer that is not re-derived from `words`.
final class BitVectorInvariantTests: XCTestCase {

    // MARK: - Unit: the latch

    func test_and_withAllValidLhs_reportsNotAllValid() {
        var hasNA = BitVector(repeating: true, count: 4)
        hasNA[1] = false

        let anded = BitVector(repeating: true, count: 4) & hasNA

        XCTAssertFalse(anded[1])
        XCTAssertEqual(anded.popcount, 3)
        XCTAssertFalse(anded.allValid)
    }

    func test_and_multiWordUnalignedTail_reportsNotAllValid() {
        // 130 bits = 2 full words + a 2-bit tail; clear a bit in each region.
        var hasNA = BitVector(repeating: true, count: 130)
        hasNA[0] = false
        hasNA[70] = false
        hasNA[129] = false

        let anded = BitVector(repeating: true, count: 130) & hasNA

        XCTAssertEqual(anded.popcount, 127)
        XCTAssertFalse(anded.allValid)
    }

    func test_not_ofAllValid_reportsNotAllValid() {
        let inverted = ~BitVector(repeating: true, count: 4)

        XCTAssertEqual(inverted.popcount, 0)
        XCTAssertFalse(inverted.allValid)
        XCTAssertTrue(inverted.allNA)
    }

    func test_or_withAllValidLhs_staysAllValid() {
        // Pins the currently-correct `|` semantics so the fix cannot regress it.
        var hasNA = BitVector(repeating: true, count: 4)
        hasNA[1] = false

        let ored = BitVector(repeating: true, count: 4) | hasNA

        XCTAssertEqual(ored.popcount, 4)
        XCTAssertTrue(ored.allValid)
    }

    func test_concat_ofAllValidAndMaskWithNA_reportsNotAllValid() {
        var hasNA = BitVector(repeating: true, count: 3)
        hasNA[0] = false
        // Route the NA through `&` so the input carries the stale latch.
        let stale = BitVector(repeating: true, count: 3) & hasNA

        let joined = BitVector.concat([BitVector(repeating: true, count: 5), stale])

        XCTAssertEqual(joined.bitCount, 8)
        XCTAssertEqual(joined.popcount, 7)
        XCTAssertFalse(joined[5])
        XCTAssertFalse(joined.allValid)
    }

    func test_equatable_ignoresHowTheMaskWasBuilt() {
        // Same bits, different construction path → must be equal.
        XCTAssertEqual(BitVector(repeating: true, count: 4),
                       BitVector([true, true, true, true]))
    }

    // MARK: - End to end: operator-derived NA survives bulk operations

    private func frameWithDerivedNA() -> DataFrame {
        var df = DataFrame()
        df["a"] = Series([13.0, 14.0, 20.0, 21.0], name: "a")
        df["b"] = Series([0.5, nil, 0.2, 0.3], name: "b")
        df["t"] = df["a"] + df["b"]
        return df
    }

    private func doubles(_ s: Series) -> [Double?] {
        (0..<s.count).map { s[$0] as? Double }
    }

    func test_derivedNA_isVisibleElementwise() {
        // Control: the element path is correct today and must stay so.
        let df = frameWithDerivedNA()
        XCTAssertEqual(doubles(df["t"]), [13.5, nil, 20.2, 21.3])
    }

    func test_derivedNA_survivesSort() {
        let sorted = frameWithDerivedNA().sortValues(by: ["a"])
        XCTAssertEqual(doubles(sorted["t"]), [13.5, nil, 20.2, 21.3])
    }

    func test_derivedNA_survivesBooleanFilter() {
        let df = frameWithDerivedNA()
        let filtered = df[df["a"] > 13.0]
        XCTAssertEqual(doubles(filtered["t"]), [nil, 20.2, 21.3])
    }

    func test_derivedNA_isExcludedFromGroupByMean() {
        let g = frameWithDerivedNA().groupBy("a").mean()
        // Key 14.0 has a single row whose "t" is NA → the group mean is NA.
        // Group keys become the result's index labels.
        let keys = g.indexLabels
        guard let row = keys.firstIndex(where: { Double($0) == 14.0 }) else {
            return XCTFail("groupBy result has no key 14.0: \(keys)")
        }
        XCTAssertNil(doubles(g["t"])[row])
    }

    func test_derivedNA_rendersAsEmptyCellInCSV() {
        let csv = frameWithDerivedNA().toCSV()
        let rows = csv.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows[0], "a,b,t")
        XCTAssertEqual(rows[2], "14,,")
    }

    func test_derivedNA_roundTripsThroughSPB() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitvector-invariant-\(UUID().uuidString).spb")
        defer { try? FileManager.default.removeItem(at: url) }

        try frameWithDerivedNA().writeSPB(to: url)
        let back = try DataFrame.readSPB(from: url)

        XCTAssertEqual(doubles(back["t"]), [13.5, nil, 20.2, 21.3])
    }

    func test_derivedNA_survivesSort_forAllArithmeticOperators() {
        var df = frameWithDerivedNA()
        df["m"] = df["a"] - df["b"]
        df["x"] = df["a"] * df["b"]
        df["d"] = df["a"] / df["b"]

        let sorted = df.sortValues(by: ["a"], ascending: [false])

        XCTAssertNil(doubles(sorted["m"])[2], "subtraction-derived NA erased")
        XCTAssertNil(doubles(sorted["x"])[2], "multiplication-derived NA erased")
        XCTAssertNil(doubles(sorted["d"])[2], "division-derived NA erased")
    }
}
```

**Observed RED run** (`swift test --filter BitVectorInvariantTests`, before any production change):

| Test | Result | Failure (verbatim) |
|---|---|---|
| `test_and_withAllValidLhs_reportsNotAllValid` | FAIL | `:22 XCTAssertFalse failed` — `allValid` is `true` |
| `test_and_multiWordUnalignedTail_reportsNotAllValid` | FAIL | `:35 XCTAssertFalse failed` |
| `test_not_ofAllValid_reportsNotAllValid` | FAIL | `:42 XCTAssertFalse failed` — popcount 0, `allValid` true |
| `test_or_withAllValidLhs_staysAllValid` | **pass** (control) | pins current `\|` semantics |
| `test_concat_ofAllValidAndMaskWithNA_reportsNotAllValid` | FAIL | `:66 ("8") is not equal to ("7")` — concat fabricated all-ones; `:67`, `:68` |
| `test_equatable_ignoresHowTheMaskWasBuilt` | FAIL | `:73 ("BitVector(4/4 valid)") is not equal to ("BitVector(4/4 valid)")` — flag leaks into `==` |
| `test_derivedNA_isVisibleElementwise` | **pass** (control) | element path is correct today |
| `test_derivedNA_survivesSort` | FAIL | `:99 [13.5, 14.0, 20.2, 21.3]` vs expected `[13.5, nil, …]` |
| `test_derivedNA_survivesBooleanFilter` | FAIL | `:105 [14.0, 20.2, 21.3]` vs `[nil, 20.2, 21.3]` |
| `test_derivedNA_isExcludedFromGroupByMean` | FAIL | `:116 XCTAssertNil failed: "14.0"` |
| `test_derivedNA_rendersAsEmptyCellInCSV` | FAIL | `:123 ("14,,14") is not equal to ("14,,")` |
| `test_derivedNA_roundTripsThroughSPB` | FAIL | `caught error: "corrupt SPB data: column 't' row 1: null cell has non-zero payload"` |
| `test_derivedNA_survivesSort_forAllArithmeticOperators` | FAIL | `:145 "14.0"`, `:146 "0.0"`, `:147 "inf"` |

`Executed 13 tests, with 15 failures` — 11 red for the defect, 2 green controls. Every red test fails on the assertion that names the stale flag, not on setup.

Benchmark gate for the GREEN step: run `BenchmarkTests` `testCB_DataFrameFiltering`, `testCC_DataFrameSorting`, `testDA_CSVIO`, `testBB_SeriesArithmetic` before/after; accept if within noise.

### How it solves the problem

The bug class is "cache disagrees with source of truth". Removing the cache removes the class, not the instance: any operator added in the future is correct by construction, the `Equatable` leak disappears (synthesized `==` now compares only `words` + `bitCount`), and `BitVector` gets simpler — fewer stored properties, no convention to document. Cost is O(n/64) per `allValid`, which the call census shows is never on a per-row path.

---

## Proposed Design 2 — Keep the cache; make the latch compiler-enforced (NOT SELECTED)

Keep O(1) `allValid`, but close the door that let `&`/`~` bypass the latch: `words` becomes `private(set)`, and the only way to mutate it from inside the type is through one helper that resets the flag first.

### `Sources/SwiftPandas/Core/Missing/BitVector.swift`

**Change** line 85:

```swift
// BEFORE
    internal var words: [UInt64]
```
```swift
// AFTER
    internal private(set) var words: [UInt64]
```

**Add** after line 103 (below `_knownAllValid`):

```swift
    /// The single door to raw word mutation. Resets the all-valid latch
    /// *before* running `body`, so no caller can clear a bit while the
    /// cache still says "all set". Every mutator in this file routes
    /// through here; the `private(set)` on `words` makes bypassing it a
    /// compile error.
    private mutating func withWordMutation(_ body: (inout [UInt64]) -> Void) {
        _knownAllValid = false
        body(&words)
    }
```

**Change** `&`, lines 258–265:

```swift
// BEFORE
        var result = lhs
        for i in 0..<result.words.count {
            result.words[i] &= rhs.words[i]
        }
        return result
```
```swift
// AFTER
        var result = lhs
        result.withWordMutation { w in
            for i in 0..<w.count { w[i] &= rhs.words[i] }
        }
        return result
```

**Change** `|`, lines 276–283 — same shape as `&`. Note this makes `|` *conservative*: all-valid `|` anything now reports `allValid` via popcount rather than O(1). Acceptable; `|` is not on any fast path.

**Change** `~`, lines 295–306:

```swift
// BEFORE
        var result = bv
        for i in 0..<result.words.count {
            result.words[i] = ~result.words[i]
        }
        if result.bitCount % 64 != 0 {
            let trailingBits = result.bitCount % 64
            result.words[result.words.count - 1] &= (1 << trailingBits) - 1
        }
        return result
```
```swift
// AFTER
        var result = bv
        result.withWordMutation { w in
            for i in 0..<w.count { w[i] = ~w[i] }
            if bv.bitCount % 64 != 0 {
                let trailingBits = bv.bitCount % 64
                w[w.count - 1] &= (1 << trailingBits) - 1
            }
        }
        return result
```

**Change** subscript `set` (lines 181–191) and `append(contentsOf:)` (lines 325–349) to mutate through `withWordMutation` too, and delete their now-redundant manual `_knownAllValid = false` lines (`:183`, `:326`). The two initializers keep writing `words` directly in `init` (allowed — `private(set)` permits writes inside the type; the helper is about *mutation after construction*).

**Add** a debug tripwire to `allValid`, lines 222–225:

```swift
// AFTER
    public var allValid: Bool {
        assert(!_knownAllValid || popcount == bitCount, "stale _knownAllValid")
        if _knownAllValid { return true }
        return popcount == bitCount
    }
```

**Add** a custom `==` so the flag stops leaking into equality:

```swift
    public static func == (lhs: BitVector, rhs: BitVector) -> Bool {
        lhs.bitCount == rhs.bitCount && lhs.words == rhs.words
    }
```

### Tests

The same `BitVectorInvariantTests` file applies unchanged; the `assert` tripwire is verified by code review, not a test (there is no way to bypass the helper without a compile error).

### How it solves the problem

The invariant moves from a comment to the type system. `words` can't be written outside `BitVector`, and inside `BitVector` the only post-init write path resets the latch first. The O(1) fast path survives for masks built with `repeating: true` that are never mutated. Cost: ~40 more lines than Design 1, a helper whose only job is to guard a flag, a custom `==`, and a cache that the call census says no consumer needs.

---

## Recommendation — Design 1 (locked)

Design 1 is better than Design 2 on every axis that matters here:

- **Correctness class, not instance.** Design 2 fixes the latch for every mutator *in this file*. Design 1 removes the thing that can be wrong. There is no future operator, no `init` variant, no `unsafe` word write that can re-introduce the bug, because `allValid` has nothing to be out of sync with.
- **It is measurably free.** The only reason the cache exists is O(1) `allValid`. The census found zero per-row consumers; the reductions already pay `popcount` one line earlier; the benchmark suite covers every fast path named in the issue and runs on NA-free data, so a regression would be visible. Design 2 keeps paying complexity for a speed-up no caller can observe.
- **It fixes the second bug for free.** Synthesized `Equatable` becomes correct with no custom `==`. Design 2 needs an extra override to get the same result.
- **It makes `BitVector` shallower to read and deeper as a module.** Three stored properties become two; three doc passages that describe the convention are deleted instead of rewritten; the interface (`allValid`, `popcount`, `allNA`, `naCount`) becomes uniformly "derived from bits, O(n/64)" with no special case to remember.

Why not the issue's P2 (targeted invalidation in `&` and `~`)? It is the smallest diff, but it keeps the invariant convention-maintained — the issue itself says "the next operator added can regress it" — and it would also need to reason separately about `concat` and the `Equatable` leak. It was not presented as a design because it does not deserve serious consideration next to the two above.

Design 2 is the right choice only if a measurement shows `allValid` on a hot path. None exists in this repo; if a downstream consumer has one, that is the fact that would flip this recommendation.

## Next steps

1. ~~Review comments lock the design.~~ **Done — Design 1 locked (PR #19 review, 2026-08-21).**
2. ~~Tests written first and shown RED.~~ **Done — `BitVectorInvariantTests.swift` on this branch, 11 red / 2 control green.**
3. On explicit go-ahead in this PR: write the implementation plan (`/writing-plans`) and add it to this PR — not before.
4. After the plan is approved in this PR and implementation is explicitly authorised: branch off, implement GREEN against these tests, run the full suite + benchmark gate, then test and merge.
5. This PR stays open as the design/plan thread; #18 closes from the implementation.
