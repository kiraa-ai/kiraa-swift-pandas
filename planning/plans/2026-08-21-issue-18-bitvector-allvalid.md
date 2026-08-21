# BitVector `allValid` Derived-From-Bits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `BitVector.allValid` a pure function of the bitmap by deleting the `_knownAllValid` cache, so the 13 acceptance tests in `BitVectorInvariantTests` go green and a stale "all valid" answer becomes unrepresentable.

**Architecture:** `BitVector` (`Sources/SwiftPandas/Core/Missing/BitVector.swift`) currently stores three properties: `words`, `bitCount`, and a cached Bool `_knownAllValid` that `allValid` trusts before falling back to a popcount. This plan removes the third property and its four write sites, makes `allValid` compute `popcount == bitCount` on every call (the same way `allNA` and `naCount` already work), and rewrites the doc comments that described the cache. No operator, no consumer, and no call site outside `BitVector.swift` changes, except two comment lines in `PandasArray.swift`.

**Tech Stack:** Swift 5.9, SwiftPM, XCTest. macOS with a Metal-capable GPU (the full suite includes `MetalTests`).

**Spec:** `docs/superpowers/designs/2026-08-21-issue-18-bitvector-allvalid.md` — Design 1 (locked on PR #19). The acceptance tests already exist and are RED: `Tests/SwiftPandasTests/BitVectorInvariantTests.swift`.

## Global Constraints

- Design 1 only. Do not add a cache, a `private(set)`, a mutation helper, or a custom `==` — those belong to the rejected Design 2.
- `BitVector`'s public API surface does not change: same initializers, same properties, same operators, same signatures. Only `allValid`'s complexity changes (O(1)-when-cached → O(*n*/64) always).
- No file outside `Sources/SwiftPandas/Core/Missing/BitVector.swift` and `Sources/SwiftPandas/Core/Array/PandasArray.swift` is modified.
- Do not edit `Tests/SwiftPandasTests/BitVectorInvariantTests.swift`. If a test in it cannot pass, stop and report — do not "fix" the test.
- Comments follow `swift-coding-practices.md` §17 and must stand on their own: describe what exists and why. Never write "the fix", "the defect", "before/after", "issue #18", or any change narrative into a code comment.
- Each task ends with `swift build` clean (zero warnings introduced) and a commit on the branch given by the orchestrator.
- Commit messages end with the `Co-Authored-By` / `Claude-Session` trailers shown in each task.

## Orchestration notes (for the orchestrator, not the task subagents)

- Tasks are sequential; each depends on the previous commit. Do not dispatch them in parallel.
- Task 1 is the only task that changes behaviour. Tasks 2–3 are documentation. Task 4 is verification only and produces no code change.
- Before dispatching Task 1, confirm the RED baseline yourself: `swift test --filter BitVectorInvariantTests` must report `Executed 13 tests, with 15 failures`. If it doesn't, the branch is not at the expected starting point.
- Between tasks, run the two-stage review from subagent-driven-development (spec compliance, then code quality). The spec-compliance reviewer should check the Global Constraints above verbatim.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/SwiftPandas/Core/Missing/BitVector.swift` | The validity bitmap type. Owns storage (`words`, `bitCount`), element access, popcount-derived queries (`popcount`, `naCount`, `allValid`, `allNA`), bitwise operators, `append`/`concat`/`take`. | Remove the `_knownAllValid` stored property and its four writes; make `allValid` derived; rewrite four doc passages that described the cache. |
| `Sources/SwiftPandas/Core/Array/PandasArray.swift` | Protocol all array types conform to; provides default `validCount`. | Two comment lines: stop describing `NullableArray.validCount` as O(1). |
| `Tests/SwiftPandasTests/BitVectorInvariantTests.swift` | Acceptance tests for the invariant (already on the branch, RED). | **Unchanged.** Goes green in Task 1. |
| `Tests/SwiftPandasTests/SwiftPandasTests.swift` (`BitVectorTests`, lines 235–291) | Existing BitVector unit tests. | **Unchanged.** Must stay green. |
| `Tests/SwiftPandasTests/BenchmarkTests.swift` | 1M-row timing tests. | **Unchanged.** Used as the performance gate in Task 4. |

---

### Task 1: Delete the `_knownAllValid` cache and derive `allValid` from the bits

**Files:**
- Modify: `Sources/SwiftPandas/Core/Missing/BitVector.swift:94-103` (property declaration), `:121`, `:148`, `:183`, `:326` (the four writes), `:216-225` (`allValid`)
- Test: `Tests/SwiftPandasTests/BitVectorInvariantTests.swift` (exists; do not edit)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `public var allValid: Bool { popcount == bitCount }` on `BitVector`. No other signature changes. Later tasks rely on `_knownAllValid` no longer existing anywhere in `Sources/`.

- [ ] **Step 1: Confirm the tests are RED before touching code**

Run: `swift test --filter BitVectorInvariantTests 2>&1 | grep -E "Executed 13|' passed"`

Expected output (exactly two tests pass, the rest fail):
```
Test Case '-[SwiftPandasTests.BitVectorInvariantTests test_derivedNA_isVisibleElementwise]' passed
Test Case '-[SwiftPandasTests.BitVectorInvariantTests test_or_withAllValidLhs_staysAllValid]' passed
Executed 13 tests, with 15 failures (1 unexpected)
```
If the count differs, stop and report to the orchestrator.

- [ ] **Step 2: Remove the stored property**

In `Sources/SwiftPandas/Core/Missing/BitVector.swift`, delete lines 94–103 in their entirety — the doc comment and the declaration:

```swift
    /// A cached optimization flag indicating whether all bits are known to be
    /// set (all valid).
    ///
    /// When `true`, callers can skip scanning the `words` array entirely.
    /// This flag is set to `true` only during construction with
    /// `repeating: true`; it is conservatively reset to `false` by any
    /// operation that might introduce a zero bit (e.g., subscript set,
    /// `append(contentsOf:)`). The flag is **not** automatically re-derived
    /// after mutations — it is a one-way latch toward `false`.
    internal var _knownAllValid: Bool
```

After this step the struct's stored properties are exactly `words` and `bitCount`. Leave the blank line that preceded the block so `// MARK: - Initializers` is still separated from `bitCount`.

- [ ] **Step 3: Remove the four write sites**

Delete each of these lines (line numbers are pre-edit; after Step 2 they shift up by 10, so search by content, not number):

| Original line | Inside | Line to delete |
|---|---|---|
| 121 | `init(repeating:count:)` | `        self._knownAllValid = value` |
| 148 | `init(_ bools: [Bool])` | `        self._knownAllValid = false` |
| 183 | `subscript(index:) set` | `            if !newValue { _knownAllValid = false }` |
| 326 | `append(contentsOf:)` | `        _knownAllValid = false` |

Delete the whole line in each case, not just the expression. Do not leave an empty statement or a dangling comment.

- [ ] **Step 4: Make `allValid` derived**

Replace the `allValid` property (originally lines 216–225) with:

```swift
    /// Whether every element is valid (no NAs present).
    ///
    /// Computed from the words on every call, the same way ``allNA`` and
    /// ``naCount`` are. There is no cached answer to keep in sync, so this
    /// property can never disagree with the bits — which matters because
    /// many fast paths skip reading the bitmap entirely when it is `true`.
    ///
    /// - Complexity: O(*n* / 64) where *n* is `bitCount` (one hardware
    ///   popcount per word).
    public var allValid: Bool {
        popcount == bitCount
    }
```

- [ ] **Step 5: Build and confirm no reference to the flag remains**

Run: `swift build 2>&1 | grep -E "error|warning" ; grep -rn "_knownAllValid" Sources/ Tests/ || echo "no references"`

Expected: no build errors, no new warnings, and `no references`. (Doc comments that still mention the flag are handled in Task 2; if `grep` shows any, note them but they do not block this task as long as the build is clean — a comment cannot break compilation.)

- [ ] **Step 6: Run the acceptance tests — all 13 must pass**

Run: `swift test --filter BitVectorInvariantTests 2>&1 | grep -E "Executed 13|error:"`

Expected:
```
Executed 13 tests, with 0 failures (0 unexpected)
```
If any test still fails, the cause is in production code, not the test. Re-check Steps 2–4; do not edit the test file.

- [ ] **Step 7: Run the existing BitVector and core test classes**

Run: `swift test --filter 'BitVectorTests|NewFeaturesTests|CSVDataFrameTests|SPBTests|VectorColumnTests' 2>&1 | grep -E "Executed|error:"`

Expected: every `Executed N tests` line reports `0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Sources/SwiftPandas/Core/Missing/BitVector.swift
git commit -m "fix(BitVector): derive allValid from the bits; drop _knownAllValid cache

allValid now returns popcount == bitCount on every call, matching allNA
and naCount. The cached flag was a one-way latch maintained by hand in
each mutator; with no cache there is nothing to keep in sync, so the
bitmap's bits and its allValid answer can no longer disagree. Also makes
the synthesized Equatable compare bits and count only.

BitVectorInvariantTests: 13/13 green.

Closes #18

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0153n5DTiEAENoDNoGjdvru2"
```

---

### Task 2: Rewrite the `BitVector.swift` doc comments that described the cache

**Files:**
- Modify: `Sources/SwiftPandas/Core/Missing/BitVector.swift` — file header bullet (originally lines 47–51), `init(_ bools:)` note (originally 142–145), subscript doc (originally 168–171)

**Interfaces:**
- Consumes: Task 1's commit (the flag no longer exists, so these comments are now describing something that isn't there).
- Produces: nothing code-level. Later tasks rely on `grep -rn "_knownAllValid" Sources/` returning nothing.

- [ ] **Step 1: Locate every remaining mention**

Run: `grep -n "_knownAllValid\|re-derive\|cached flag\|short-circuits" Sources/SwiftPandas/Core/Missing/BitVector.swift`

Expected: three hits — in the file-header "Performance Considerations" list, in the `- Note:` on `init(_ bools:)`, and in the `- Behavior (set):` of the subscript doc. If there are more, include them in the steps below using the same rule: describe what the code does now.

- [ ] **Step 2: Replace the file-header bullet**

Find this block in the `// ## Performance Considerations` section near the top of the file:

```swift
// - **`_knownAllValid`** is a cached flag that short-circuits `allValid`
//   checks without scanning the words array. It is conservatively set to
//   `false` whenever a mutation *might* introduce a zero bit; it is only
//   set to `true` when the vector is known to be all-ones at construction
//   time.
```

Replace it with:

```swift
// - **Derived queries** — `popcount`, `naCount`, `allValid`, and `allNA` are
//   all computed from the words on each call (one hardware popcount per
//   word). Nothing about the bitmap's contents is cached, so no mutation
//   path can leave a summary out of sync with the bits.
```

- [ ] **Step 3: Replace the `init(_ bools:)` note**

Find, in the doc comment immediately above `public init(_ bools: [Bool])`:

```swift
    /// - Note: The `_knownAllValid` flag is set to `false` regardless of
    ///   input, because scanning for all-true would cost the same as the
    ///   construction itself. Use `init(repeating:count:)` when you know
    ///   all elements are valid.
```

Replace it with:

```swift
    /// - Note: Prefer `init(repeating:count:)` when every element is known to
    ///   be valid; it fills whole words at once instead of setting bits one
    ///   at a time.
```

- [ ] **Step 4: Replace the subscript setter description**

Find, in the doc comment above `public subscript(index: Int) -> Bool`:

```swift
    /// - Behavior (set): Setting to `false` clears the bit and
    ///   conservatively resets `_knownAllValid` to `false`. Setting to
    ///   `true` sets the bit but does **not** re-derive `_knownAllValid`
    ///   (doing so would require an O(*n*) scan).
```

Replace it with:

```swift
    /// - Behavior (set): Setting to `false` clears the bit (marks the element
    ///   NA); setting to `true` sets it (marks the element valid). No other
    ///   state is touched.
```

- [ ] **Step 5: Verify nothing else mentions the flag and the build is clean**

Run: `grep -rn "_knownAllValid" Sources/ Tests/ || echo "no references"; swift build 2>&1 | grep -E "error|warning" || echo "build clean"`

Expected:
```
no references
build clean
```

- [ ] **Step 6: Run the BitVector tests to confirm comments-only change**

Run: `swift test --filter 'BitVectorInvariantTests|BitVectorTests' 2>&1 | grep -E "Executed|error:"`

Expected: both `Executed` lines report `0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/SwiftPandas/Core/Missing/BitVector.swift
git commit -m "docs(BitVector): describe derived queries; remove cache narrative

File header, init(_ bools:) note, and subscript setter doc now describe
what the type does: every summary query is computed from the words on
each call and no mutation path touches any other state.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0153n5DTiEAENoDNoGjdvru2"
```

---

### Task 3: Correct the `validCount` complexity note in `PandasArray.swift`

**Files:**
- Modify: `Sources/SwiftPandas/Core/Array/PandasArray.swift:181-183`

**Interfaces:**
- Consumes: nothing code-level; this is the last place in `Sources/` that advertises an O(1) validity summary.
- Produces: nothing.

- [ ] **Step 1: Read the current comment**

Run: `sed -n 178,186p Sources/SwiftPandas/Core/Array/PandasArray.swift`

Expected:
```swift
public extension PandasArray {
    /// Default implementation: counts the number of `false` entries in ``isNA()``.
    ///
    /// Concrete types that maintain a precomputed validity count (such as
    /// ``NullableArray``, which delegates to ``BitVector.popcount``) shadow
    /// this default with an O(1) property.
    var validCount: Int {
        isNA().filter { !$0 }.count
    }
```

- [ ] **Step 2: Replace the three-line explanation**

Replace:

```swift
    /// Concrete types that maintain a precomputed validity count (such as
    /// ``NullableArray``, which delegates to ``BitVector.popcount``) shadow
    /// this default with an O(1) property.
```

with:

```swift
    /// Concrete types backed by a validity bitmap (such as ``NullableArray``,
    /// which delegates to ``BitVector.popcount``) shadow this default with a
    /// word-wise popcount: O(*n* / 64) rather than O(*n*).
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|warning" || echo "build clean"`

Expected: `build clean`

- [ ] **Step 4: Commit**

```bash
git add Sources/SwiftPandas/Core/Array/PandasArray.swift
git commit -m "docs(PandasArray): validCount on bitmap-backed arrays is O(n/64), not O(1)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0153n5DTiEAENoDNoGjdvru2"
```

---

### Task 4: Full-suite and benchmark gate (verification only, no code change)

**Files:**
- None modified. Produces a short report for the orchestrator to paste into PR #19.

**Interfaces:**
- Consumes: the three commits from Tasks 1–3.
- Produces: pass/fail evidence for the spec's acceptance criteria and benchmark gate.

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:" | tail -20`

Expected: the final line is `Executed 576 tests, with 2 failures (0 unexpected)` — 563 pre-existing + 13 new. The two failures are the pre-existing, unrelated GPU failures `MetalMergeTests.testInnerJoinCorrectness` and `MetalMergeTests.testInnerJoinDuplicateKeys`, which also fail on `main` before this branch. **Any other failure is a regression introduced by Tasks 1–3 — stop and report it with the full error line.** Do not attempt to fix it in this task.

- [ ] **Step 2: Capture the benchmark gate on this branch**

Run each benchmark three times and record the printed timings (the tests print their own timing tables to stdout):

```bash
for t in testBB_SeriesArithmetic testCB_DataFrameFiltering testCC_DataFrameSorting testDA_CSVIO; do
  swift test --filter "BenchmarkTests/$t" 2>&1 | grep -E "ms|µs|Executed"
done
```

Record every line that reports a time. These four exercise, respectively: `NullableArray` binary arithmetic (two `allValid` evaluations per op), `take(mask:trueCount:)`, `take(indices:)` via sort, and the CSV writer's per-column `allValid` check — the fast paths the spec names.

- [ ] **Step 3: Capture the same benchmarks on the base commit**

```bash
BASE=$(git merge-base HEAD main)
git stash --include-untracked   # only if the tree is dirty; otherwise skip
git checkout -q "$BASE"
for t in testBB_SeriesArithmetic testCB_DataFrameFiltering testCC_DataFrameSorting testDA_CSVIO; do
  swift test --filter "BenchmarkTests/$t" 2>&1 | grep -E "ms|µs|Executed"
done
git checkout -q -
git stash pop                    # only if you stashed
```

- [ ] **Step 4: Compare and write the report**

The spec's acceptance bar is "within noise". Treat a benchmark as passing if the branch's min-of-3 timing is within 10% of the base's min-of-3 or within 1 ms absolute, whichever is larger. Produce this table (fill in real numbers):

```
| Benchmark | base (min of 3) | branch (min of 3) | delta | pass? |
|---|---|---|---|---|
| testBB_SeriesArithmetic | … | … | … | … |
| testCB_DataFrameFiltering | … | … | … | … |
| testCC_DataFrameSorting | … | … | … | … |
| testDA_CSVIO | … | … | … | … |

Full suite: Executed 576 tests, with 2 failures (both pre-existing MetalMergeTests, also failing on main).
```

If any row fails the bar, report it — do not change code. The orchestrator decides whether to accept, re-measure, or escalate to the PR.

- [ ] **Step 5: No commit**

This task changes no files. Return the report text to the orchestrator.

---

## Self-review against the spec

**Spec coverage** (Design 1 section of the design doc):
- Remove declaration `:94–103` → Task 1 Step 2. ✔
- Change `allValid` `:217–225` → Task 1 Step 4. ✔
- Remove writes `:121, :148, :183, :326` → Task 1 Step 3. ✔
- Remove doc notes at header `:47–51` and init `:142–145` → Task 2 Steps 2–3. ✔ (Task 2 Step 4 additionally fixes the subscript doc at `:168–171`, which the spec's census missed but which names the deleted flag.)
- `PandasArray.swift:182–183` → Task 3. ✔
- `&`, `|`, `~`, `concat`, `take` unchanged → Global Constraints + no task touches them. ✔
- Seven acceptance behaviours → all covered by the existing 13 tests; Task 1 Step 6 requires 13/13. ✔
- Benchmark gate on `testCB/testCC/testDA/testBB` → Task 4. ✔
- `Equatable` falls out for free → `test_equatable_ignoresHowTheMaskWasBuilt` in Task 1 Step 6. ✔

**Placeholder scan:** no TBD/TODO; every code step shows the exact text. Task 4's table has `…` cells by design — they are measurement outputs the executor fills in, and the step says so.

**Type consistency:** only one symbol is introduced/changed — `allValid: Bool` — and it is spelled identically in every task. The four deleted lines are quoted verbatim from the current file.
