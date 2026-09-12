# merge_hash_build Duplicate-Key Race Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make GPU inner joins return every match when the build (right) side has duplicate join keys, by giving `merge_hash_build` a single insert path in both shader copies.

**Architecture:** The locked design (Design 2 in the spec) collapses the kernel's two insert paths — CAS winner vs. duplicate — into one: claim the slot's key if empty, then *every* thread pushes itself onto the slot's chain via `atomic_exchange` + `chain_next` link. The `-1` sentinel already means "empty chain," so the first inserter needs no special path. A spurious weak-CAS failure retries the same slot. No host Swift, probe kernel, or API changes.

**Tech Stack:** Metal Shading Language (MSL) compute kernels, Swift/XCTest, SwiftPM + XcodeGen.

**Spec:** `docs/superpowers/designs/2026-08-31-issue-27-merge-hash-build-race.md` (Design 2 — locked by maintainer)

## Global Constraints

- The kernel exists twice and MUST change identically in both places: `Sources/SwiftPandas/Metal/Shaders/MergeShaders.metal` (Xcode-only; `exclude:`d in Package.swift) and the string literal in `Sources/SwiftPandas/Metal/MetalShaders.swift` (what actually runs under `swift test` / SPM).
- MSL device atomics accept ONLY `memory_order_relaxed` — release/acquire will not compile. Relaxed is sound because build and probe run in separate command buffers, each `waitUntilCompleted` (`MetalContext.swift:296-315`).
- Comments must be timeless: describe what the code does and why for a zero-context reader. Never reference the defect, "the fix," or before/after.
- Commits: conventional-commit style, Markos is sole author — NO `Co-Authored-By`, `Claude-Session`, or "Generated with" trailers, ever.
- Environment: Metal-capable Mac; `SWIFTPANDAS_USE_BINARY` must be unset.
- Execute on a fresh branch off `main` (suggested: `fix/issue-27-merge-hash-build-race`). Every commit leaves the suite green — RED evidence is recorded in the PR, not committed as a failing state.
- Release/version bump (Package.swift checksum, README, `SwiftPandasInfo.version`, XCFramework) is out of scope — maintainer handles it separately.

---

### Task 1: RED — high-contention regression test

**Files:**
- Modify: `Tests/SwiftPandasTests/MetalTests.swift` (insert after `testInnerJoinDuplicateKeys`, which ends at line 488)

**Interfaces:**
- Consumes: `MetalMerge.innerJoin(left:right:on:) -> DataFrame?`, `Column.fromStrings(_:)`, `Column.fromDoubles(_:)`, `DataFrame(columns:)` — all exactly as used by the existing tests in this class.
- Produces: test method `MetalMergeTests.testInnerJoinHighContentionDuplicateKeys` (Task 2 runs it).

Rationale (from the spec): the two existing duplicate-key tests fail on this machine but reportedly pass on narrower GPUs — their contention is too thin to race reliably everywhere. Many build rows over few distinct keys contends maximally on any Metal device, making this the durable regression guard.

- [ ] **Step 1: Write the test**

Insert after line 488 of `Tests/SwiftPandasTests/MetalTests.swift` (immediately after `testInnerJoinDuplicateKeys`'s closing brace):

```swift
    func testInnerJoinHighContentionDuplicateKeys() {
        // Many build-side rows over few distinct keys drives maximal
        // concurrent insertion into the same hash slots, exercising the
        // build kernel's chain push under contention on any GPU width.
        let rightN = 50_000
        let keyCount = 4

        var rightIds = [String]()
        var rightVals = [Double]()
        for i in 0..<rightN {
            rightIds.append("k\(i % keyCount)")
            rightVals.append(Double(i))
        }
        let leftIds = (0..<keyCount).map { "k\($0)" }

        let left = DataFrame(columns: [
            ("id", Column.fromStrings(leftIds)),
            ("lval", Column.fromDoubles([Double](repeating: 0, count: keyCount))),
        ])
        let right = DataFrame(columns: [
            ("id", Column.fromStrings(rightIds)),
            ("rval", Column.fromDoubles(rightVals)),
        ])

        guard let result = MetalMerge.innerJoin(left: left, right: right, on: "id") else {
            XCTFail("GPU merge returned nil")
            return
        }

        // Each right row matches exactly one left row (one left row per key).
        XCTAssertEqual(result.rowCount, rightN)
    }
```

Output-capacity sanity (no code needed, just why this passes the overflow guard): `MetalMerge.swift:157` computes `maxOutput = min(leftN * rightN, leftN * 10 + rightN * 10 + 100_000)` = min(200,000, 600,040) = 200,000; expected `outCount` is 50,000, well under it.

- [ ] **Step 2: Run the three duplicate-key tests to verify RED**

Run:
```bash
swift test --filter 'MetalMergeTests/(testInnerJoinHighContentionDuplicateKeys|testInnerJoinDuplicateKeys|testInnerJoinCorrectness)'
```

Expected: ALL THREE FAIL with `XCTAssertEqual failed` on row counts below the expected value (new test: fewer than 50,000; existing: fewer than 5 and fewer than 40,000). Counts vary run to run — that is the race. If the new test PASSES here, it is not contending hard enough: stop and raise `rightN` (e.g. 200,000 / 2 keys) until it fails, before proceeding.

- [ ] **Step 3: Record the RED evidence**

Copy the three failure lines verbatim into the implementation PR description (or a PR comment) under a "RED before fix" heading. Do NOT commit yet — the commit lands with the green implementation in Task 2 so every commit keeps the suite green.

---

### Task 2: GREEN — single insert path in both shader copies

**Files:**
- Modify: `Sources/SwiftPandas/Metal/Shaders/MergeShaders.metal:32-54` (the insert loop)
- Modify: `Sources/SwiftPandas/Metal/MetalShaders.swift:484-512` (the same loop in the MSL string)
- Modify: `Sources/SwiftPandas/Metal/MetalShaders.swift:120-127` (file-level narrative, insert-algorithm steps)
- Modify: `Sources/SwiftPandas/Metal/MetalShaders.swift:452-456` (merge-section narrative)
- Test: `Tests/SwiftPandasTests/MetalTests.swift` (from Task 1; no further edits)

**Interfaces:**
- Consumes: `testInnerJoinHighContentionDuplicateKeys` from Task 1.
- Produces: the corrected `merge_hash_build` kernel. Kernel signature, buffer indices, `MergeHashEntry` layout, and `chain_next` semantics are UNCHANGED — `merge_hash_probe` and all host code are untouched.

- [ ] **Step 1: Replace the insert loop in `MergeShaders.metal`**

At `Sources/SwiftPandas/Metal/Shaders/MergeShaders.metal`, replace lines 32-54 exactly:

BEFORE:
```metal
    while (true) {
        int expected = EMPTY_SLOT;
        if (atomic_compare_exchange_weak_explicit(
                &hash_table[slot].key, &expected, code,
                memory_order_relaxed, memory_order_relaxed)) {
            atomic_store_explicit(
                &hash_table[slot].row_index, (int)tid,
                memory_order_relaxed);
            return;
        }
        int current = atomic_load_explicit(
            &hash_table[slot].key, memory_order_relaxed);
        if (current == code) {
            int old_head = atomic_exchange_explicit(
                &hash_table[slot].row_index, (int)tid,
                memory_order_relaxed);
            atomic_store_explicit(
                &chain_next[tid], old_head,
                memory_order_relaxed);
            return;
        }
        slot = (slot + 1) & mask;
    }
```

AFTER:
```metal
    while (true) {
        // Claim the slot's key if empty. On failure `expected` holds the key
        // currently in the slot; a weak CAS may also fail spuriously, leaving
        // `expected` == EMPTY_SLOT — retry the same slot in that case so one
        // key can never occupy two slots.
        int expected = EMPTY_SLOT;
        bool claimed = atomic_compare_exchange_weak_explicit(
                &hash_table[slot].key, &expected, code,
                memory_order_relaxed, memory_order_relaxed);
        if (claimed || expected == code) {
            // The slot owns this key. Every inserting thread pushes its row
            // the same way: swap it in as the chain head and link the previous
            // head (or the -1 empty-chain sentinel) behind it. Chains are
            // complete only once the kernel finishes; relaxed ordering
            // suffices because the probe runs in a later command buffer,
            // after this dispatch completes.
            int old_head = atomic_exchange_explicit(
                &hash_table[slot].row_index, (int)tid,
                memory_order_relaxed);
            atomic_store_explicit(
                &chain_next[tid], old_head,
                memory_order_relaxed);
            return;
        }
        if (expected != EMPTY_SLOT) {
            // Occupied by a different key — linear-probe onward.
            slot = (slot + 1) & mask;
        }
    }
```

- [ ] **Step 2: Make the identical replacement in the MSL string**

At `Sources/SwiftPandas/Metal/MetalShaders.swift`, replace lines 484-512 (the same loop, currently commented with "Try to claim an empty slot via CAS" / "First row with this key in this slot — store directly" / "Duplicate key — prepend to the chain..." / "Hash collision (different key) — linear probe") with the IDENTICAL code block from Step 1 — same code, same comments, at the string literal's 4-space indent. The two copies must be functionally identical after this step.

- [ ] **Step 3: Update the file-level narrative in `MetalShaders.swift`**

Replace lines 120-127:

BEFORE:
```
//   1. Hash the code and probe for the correct slot via linear probing.
//   2. If the slot is empty (CAS succeeds), store the row index directly.
//   3. If the slot already contains the same key (duplicate), use
//      `atomic_exchange` to atomically swap in the new row index while
//      retrieving the previous head of the chain. The previous head is then
//      stored in `chain_next[tid]`, forming a singly-linked list of all
//      right-table rows with the same key. The chain is effectively built
//      in LIFO (stack) order.
```

AFTER:
```
//   1. Hash the code and probe for the owning slot via linear probing,
//      claiming the slot's key with a CAS when the slot is empty.
//   2. Once the slot owns the key, every inserting thread — including the
//      one that just claimed it — pushes its row onto the slot's chain the
//      same way: `atomic_exchange` swaps the new row index into the slot
//      while retrieving the previous head (-1 for an empty chain), which is
//      then stored in `chain_next[tid]`. This forms a LIFO singly-linked
//      list of all right-table rows sharing the same key.
```

- [ ] **Step 4: Update the merge-section narrative in `MetalShaders.swift`**

Replace lines 452-456:

BEFORE:
```
    // The hash table stores one slot per unique key. When a duplicate key is
    // inserted, the new row atomically replaces the slot's row_index (via
    // atomic_exchange), and the previous row_index is saved in chain_next.
    // This builds a LIFO singly-linked list of all right-table rows sharing
    // the same key, enabling many-to-many join semantics in Phase 2.
```

AFTER:
```
    // The hash table stores one slot per unique key. Every insert pushes its
    // row onto the slot's chain: atomic_exchange swaps the new row_index in
    // while returning the previous head (-1 for an empty chain), which is
    // saved in chain_next. This builds a LIFO singly-linked list of all
    // right-table rows sharing the same key, enabling many-to-many join
    // semantics in Phase 2. Chains are complete only when this kernel's
    // dispatch finishes; the probe runs in a separate command buffer after
    // that (MetalContext.dispatch waits per dispatch), which is what makes
    // relaxed atomic ordering sufficient throughout.
```

- [ ] **Step 5: Run the three tests to verify GREEN**

Run:
```bash
swift test --filter 'MetalMergeTests/(testInnerJoinHighContentionDuplicateKeys|testInnerJoinDuplicateKeys|testInnerJoinCorrectness)'
```

Expected: all three PASS (5, 40,000, and 50,000 rows respectively).

- [ ] **Step 6: Verify stability across repeated runs**

The race was non-deterministic, so one green run proves little. Run:
```bash
for i in $(seq 1 10); do
  swift test --filter 'MetalMergeTests' 2>&1 | grep -E "Executed .* failures" | head -1
done
```

Expected: 10 lines, every one reporting `0 failures`. Any failure in any iteration means the fix is wrong — stop and re-examine; do not proceed or weaken the tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/SwiftPandas/Metal/Shaders/MergeShaders.metal Sources/SwiftPandas/Metal/MetalShaders.swift Tests/SwiftPandasTests/MetalTests.swift
git commit -m "fix(Metal): merge_hash_build pushes every row through a single chain insert path"
```

---

### Task 3: Verification sweep — full suite, Xcode shader compile, copy parity

**Files:**
- No source changes. Verification only.

**Interfaces:**
- Consumes: the committed fix from Task 2.
- Produces: evidence for the implementation PR that both copies compile, all tests pass, and the copies are in lockstep.

- [ ] **Step 1: Run the full test suite**

Run:
```bash
swift test 2>&1 | tail -20
```

Expected: 0 failures across both test targets (library + CLI; the daemon tests exec the freshly built binary). Any failure — including in non-Metal suites — must be investigated before proceeding; if it also fails on `main` unfixed, note it in the PR rather than absorbing it here.

- [ ] **Step 2: Compile the `.metal` copy via Xcode**

`swift test` never compiles `MergeShaders.metal` (it is `exclude:`d from SPM), so an MSL syntax error there would go unnoticed until an Xcode build. Run:

```bash
xcodebuild build -scheme SwiftPandas -configuration Release 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (If the project needs regenerating first: `xcodegen generate`, then rebuild. Never edit the `.xcodeproj` by hand.)

- [ ] **Step 3: Verify the two shader copies are functionally identical**

Run this from the repo root:

```bash
python3 - <<'EOF'
import re
swift = open('Sources/SwiftPandas/Metal/MetalShaders.swift').read()
metal = ""
for f in ['GroupByShaders.metal', 'MergeShaders.metal', 'VectorSearchShaders.metal']:
    metal += open(f'Sources/SwiftPandas/Metal/Shaders/{f}').read() + "\n"

def kernels(src):
    out = {}
    for m in re.finditer(r'kernel void (\w+)\(', src):
        start = src.index('{', m.start())
        depth, j = 0, start
        while j < len(src):
            if src[j] == '{': depth += 1
            elif src[j] == '}':
                depth -= 1
                if depth == 0: break
            j += 1
        body = re.sub(r'//.*', '', src[m.start():j+1])
        out[m.group(1)] = re.sub(r'\s+', ' ', body).strip()
    return out

ks, km = kernels(swift), kernels(metal)
assert set(ks) == set(km), (set(ks) ^ set(km))
bad = [n for n in ks if ks[n] != km[n]]
print("DRIFTED:", bad) if bad else print("all kernels identical")
EOF
```

Expected: `all kernels identical`. Any `DRIFTED` output means Step 1 and Step 2 of Task 2 diverged — fix before opening the PR.

- [ ] **Step 4: Record evidence in the implementation PR**

Paste into the PR description: the RED output from Task 1 Step 3, the GREEN output from Task 2 Step 5, the 10× stability lines from Task 2 Step 6, and the parity/`BUILD SUCCEEDED` confirmations from this task. The PR closes #25 and #27.
