# Design: `merge_hash_build` duplicate-key race (#27)

## State what the issue is

GPU inner joins silently drop matches whenever the build (right) side has duplicate join keys, and the loss is non-deterministic — the same join returns a different short row count each run.

`merge_hash_build` inserts each right-table row into a hash table; rows sharing a key form a LIFO chain through `chain_next`. The thread that wins the CAS on a slot's key publishes the key first and stores the chain head (its own row index) one instruction later, unconditionally. Any thread carrying the same key that arrives between those two operations sees the published key, takes the duplicate path, and pushes itself onto the chain correctly. The winner's late store then overwrites the chain head with its own row — whose `chain_next` is still the `-1` sentinel — so every row pushed during that window becomes unreachable. The probe kernel walks winner → `-1` and stops.

Verified on this machine (Apple Silicon, current `main`):

- `MetalMergeTests/testInnerJoinDuplicateKeys` — got 3, expected 5
- `MetalMergeTests/testInnerJoinCorrectness` — got 3,640, expected 40,000 (issue observed 16,460 / 16,080 / 25,200 on the same test)

We are designing the corrected insert path for the build kernel.

## Code in question

The kernel exists **twice** (SPM cannot compile `.metal`, so the same MSL lives in a string literal); any change lands in both:

- `Sources/SwiftPandas/Metal/Shaders/MergeShaders.metal:32-54` — Xcode-compiled copy; buggy winner branch at lines 33-41
- `Sources/SwiftPandas/Metal/MetalShaders.swift:484-513` — runtime-compiled string copy; buggy winner branch at lines 486-495

```metal
while (true) {
    int expected = EMPTY_SLOT;
    if (atomic_compare_exchange_weak_explicit(
            &hash_table[slot].key, &expected, code,
            memory_order_relaxed, memory_order_relaxed)) {
        atomic_store_explicit(                       // ← clobbers the chain head
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

The winner's `atomic_store` assumes the slot is still untouched — but the key became visible to every other thread the moment the CAS landed, so the slot's chain may already hold rows. Interleaving that loses rows (three rows, one key):

1. t0 wins the CAS (`key = code`); `row_index` still `-1`
2. t1 exchanges in: head = 1, `chain_next[1] = -1`
3. t2 exchanges in: head = 2, `chain_next[2] = 1`
4. t0 stores: head = 0, `chain_next[0] = -1` → probe emits row 0 only; rows 1 and 2 are orphaned

Supporting facts, verified:

- `chain_next` is memset to `-1` host-side before the build (`Sources/SwiftPandas/Metal/MetalMerge.swift:128-129`), so an exchange on an untouched slot returns the `-1` sentinel.
- Build and probe run in separate command buffers, each with `waitUntilCompleted` (`Sources/SwiftPandas/Metal/MetalContext.swift:296-315`), so relaxed atomics need no cross-kernel ordering.
- The duplicate path and the probe kernel are correct; only the winner branch is wrong.

## Proposed Design 1 — winner pushes instead of storing

Minimal diff: change only the CAS-success branch so the winner links onto whatever the slot holds, exactly like the duplicate path.

BEFORE (`MergeShaders.metal:33-41`, same shape at `MetalShaders.swift:486-495`):

```metal
        int expected = EMPTY_SLOT;
        if (atomic_compare_exchange_weak_explicit(
                &hash_table[slot].key, &expected, code,
                memory_order_relaxed, memory_order_relaxed)) {
            atomic_store_explicit(
                &hash_table[slot].row_index, (int)tid,
                memory_order_relaxed);
            return;
        }
```

AFTER:

```metal
        int expected = EMPTY_SLOT;
        if (atomic_compare_exchange_weak_explicit(
                &hash_table[slot].key, &expected, code,
                memory_order_relaxed, memory_order_relaxed)) {
            // The key is visible to other threads as soon as the CAS lands,
            // so the slot's chain may already hold rows. Push onto whatever
            // is there rather than assuming the slot is untouched.
            int old_head = atomic_exchange_explicit(
                &hash_table[slot].row_index, (int)tid,
                memory_order_relaxed);
            atomic_store_explicit(
                &chain_next[tid], old_head,
                memory_order_relaxed);
            return;
        }
```

Why it works: after the key is published, *every* insert into the slot — winner included — is an atomic exchange-and-link. Uncontended, the exchange returns `-1` and the result is byte-identical to today. Contended, the exchange returns the racers' current head and the winner links onto it; no row is ever unreachable because each push atomically threads the previous head behind the new one.

Changes: the two winner branches only (~6 lines each in the two files). This is the fix proposed in the issue, validated there in a standalone harness (0 wrong results in 180 runs).

## Proposed Design 2 — one push path for every row

Restructure the loop so "claim the key" and "find the key already claimed" both fall into a single push sequence. The failed CAS writes the observed key into `expected` (MSL semantics), so the separate re-load disappears.

BEFORE (`MergeShaders.metal:32-54`, same shape at `MetalShaders.swift:484-512`): the full loop shown in *Code in question*.

AFTER:

```metal
    while (true) {
        // Claim the slot's key if empty. On failure, `expected` holds the
        // key currently in the slot.
        int expected = EMPTY_SLOT;
        bool claimed = atomic_compare_exchange_weak_explicit(
                &hash_table[slot].key, &expected, code,
                memory_order_relaxed, memory_order_relaxed);
        if (claimed || expected == code) {
            // This slot owns our key. Every inserting thread pushes itself
            // the same way: swap our row in as the chain head and link the
            // previous head (or the -1 sentinel) behind us.
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
        // expected == EMPTY_SLOT: the weak CAS failed spuriously; retry the
        // same slot so one key can never end up split across two slots.
    }
```

Why it works: same push invariant as Design 1, but there is only one insert path, so the invariant cannot diverge again. It also closes a second, latent hazard: `atomic_compare_exchange_weak_explicit` is permitted to fail spuriously (there is no strong variant in MSL). The current loop — and Design 1's — responds to any CAS failure by re-loading the key and, on seeing `EMPTY_SLOT`, advancing to the next slot. A spurious failure on an empty slot would therefore seed the same key into a *second* slot; the probe stops after the first matching slot's chain, dropping the second — the same symptom class as #27. Never observed on Apple GPUs, but permitted by the spec. Design 2 retries the same slot instead.

Changes: replace the loop body in both files (~20 lines each); the narrative comments above each copy (`MergeShaders.metal:3-5`, `MetalShaders.swift:440-457`) get updated to describe the single push path.

## Recommendation

**Design 2.**

The bug exists because insertion had two code paths with two different invariants, and the winner's invariant — "the slot is still untouched" — is false from the instant its CAS lands. Design 1 patches that path; Design 2 removes the distinction, leaving one invariant ("publish the key if needed, then push yourself onto the chain") that holds for every thread. One path is also the only version that closes the spurious-CAS-failure hazard, which Design 1 leaves in place.

Cost is negligible: the contended path executes identical atomics to Design 1; the uncontended path gains one `chain_next` store that writes `-1` over the `-1` already memset there. The diff is larger than Design 1's, but the resulting kernel is shorter than today's (the re-load disappears) and every line of it is exercised by the unique-key tests as well as the duplicate-key tests.

## Next steps

Per the working agreement: lock a design in this PR's review, then show the RED tests in this doc (both existing `MetalMergeTests` failures are already RED on `main`; the test phase should also weigh a production-shape stress case — ~18,500 build rows over ~615 keys — since the 3-row test races only narrowly), then add the `/writing-plans` implementation plan to this PR, then implement on explicit go-ahead. Any implementation must change both shader copies in lockstep.
