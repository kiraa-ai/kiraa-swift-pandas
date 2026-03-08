// MARK: - MetalShaders.swift
// ---------------------------------------------------------------------------
// Embedded Metal Shading Language (MSL) Source Code for SwiftPandas GPU Kernels
// ---------------------------------------------------------------------------
//
// This file contains all Metal compute shader source code as Swift string
// literals. It exists solely for **Swift Package Manager (SPM) builds**, where
// `.metal` source files cannot be precompiled by the build system. In Xcode
// builds, the equivalent `.metal` files are compiled to `default.metallib` at
// build time, and this file is excluded via `#if SWIFT_PACKAGE`.
//
// The MSL source is split into three logical sections, concatenated at runtime
// into a single compilation unit (`allSource`):
//
// 1. **Common Types & Hashing** (`commonTypes`):
//    - Hash functions used by both GroupBy and Merge kernels.
//    - The `EMPTY_SLOT` sentinel constant (-1) for hash table initialization.
//    - The validity bitmap accessor for nullable column support.
//
// 2. **GroupBy Shaders** (`groupByShaders`):
//    - Phase 1: `groupby_hash_insert` — open-addressing hash table insertion
//      with CAS (compare-and-swap) for concurrent group ID assignment.
//    - Phase 2: Four parallel reduction kernels (`sum`, `min`, `max`, `count`)
//      that use atomic operations to accumulate per-group results.
//
// 3. **Merge Shaders** (`mergeShaders`):
//    - Phase 1: `merge_hash_build` — builds a hash table from the right table's
//      keys, with chained linked lists for handling duplicate keys.
//    - Phase 2: `merge_hash_probe` — each left-table row probes the hash table
//      to find matching right-table rows, writing output index pairs.
//
// Hash Function Design:
//
//   `hash_uint` implements the **MurmurHash3 finalizer** (fmix32), a
//   well-known bit-mixing function that provides excellent avalanche properties
//   (every input bit affects every output bit). The three rounds of
//   XOR-shift-multiply thoroughly scramble the input bits, producing a
//   near-uniform distribution even for sequential integer keys. This is
//   critical for open-addressing hash tables where clustering degrades
//   performance. The specific magic constants (0x85ebca6b, 0xc2b2ae35) were
//   chosen by Austin Appleby in the original MurmurHash3 design for optimal
//   bit avalanche.
//
//   `hash_int32` reinterprets a signed int as unsigned via `as_type<uint>`
//   (a bitwise cast, not a value conversion) before hashing, ensuring negative
//   keys are hashed without sign-extension artifacts.
//
//   `hash_combine` merges two hash values using the Boost `hash_combine`
//   formula. The magic constant `0x9e3779b9` is the integer part of the
//   golden ratio (2^32 / phi), which ensures good distribution when combining
//   hashes. The bidirectional shifts (`<< 6`, `>> 2`) mix bits from both
//   inputs asymmetrically, reducing collision rates for ordered pairs. This
//   function is available for multi-column key hashing scenarios.
//
// Validity Bitmap Access Pattern:
//
//   SwiftPandas stores nullable column validity as a `BitVector` backed by
//   `[UInt64]` words, where bit `i` being set indicates that row `i` contains
//   a valid (non-null) value. Since Metal shaders operate on 32-bit types,
//   each UInt64 word is accessed as a pair of UInt32 halves. The `is_valid`
//   function computes the correct half-word index and bit position:
//
//   - `wordIdx = idx / 64` — which UInt64 word contains bit `idx`
//   - `bitIdx = idx % 64` — position within that 64-bit word
//   - `halfIdx = wordIdx * 2 + (bitIdx >= 32 ? 1 : 0)` — which UInt32 half
//   - `localBit = bitIdx % 32` — position within the 32-bit half
//
//   Bits are stored LSB-first (least significant bit = lowest index).
//
// GroupBy Phase 1 — Hash Insert with CAS:
//
//   The `groupby_hash_insert` kernel implements a lock-free, open-addressing
//   hash table using atomic compare-and-swap (CAS) operations. Each GPU thread
//   processes one row, inserting its factorized group code into the table:
//
//   1. Hash the code and compute the initial slot (`hash & mask`; the table
//      capacity is always a power of two, so `& mask` is equivalent to `% capacity`).
//   2. Attempt a CAS on `ht_keys[slot]`: if the slot is empty (`EMPTY_SLOT`),
//      claim it by writing the code. On success, atomically increment
//      `nextGroupId` to assign a unique group ID, store it in `ht_group_ids`,
//      and write the mapping to `row_to_group`.
//   3. If the CAS fails because another thread already claimed the slot:
//      - If the existing key matches our code, read the group ID that was
//        assigned. A spin-wait loop handles the race condition where the
//        winning thread has written the key but hasn't yet written the group ID.
//      - If the existing key is different (hash collision), linear-probe to
//        the next slot (`slot = (slot + 1) & mask`) and retry.
//
//   All atomics use `memory_order_relaxed` because correctness depends only on
//   the atomicity of individual operations, not on inter-thread ordering of
//   different memory locations.
//
// GroupBy Phase 2 — Parallel Reductions with Atomic Operations:
//
//   Each reduction kernel (sum, min, max, count) launches one thread per row.
//   Every thread reads its value and the row-to-group mapping, then atomically
//   updates the group's accumulator:
//
//   - **Sum**: Uses `atomic_fetch_add_explicit` on `atomic_float` accumulators.
//     Atomic float addition is natively supported on Apple GPUs (Metal 3.0+).
//   - **Min/Max**: Uses an atomic CAS loop pattern. The thread loads the
//     current accumulator value, checks if its value would improve the result,
//     and if so attempts a CAS. If the CAS fails (another thread updated the
//     value concurrently), it reloads and retries. The loop terminates when
//     either the CAS succeeds or the current value is already better.
//   - **Count**: Simply increments an `atomic_uint` counter per group.
//
//   All reduction kernels also maintain a `counts` array (via atomic increment)
//   to track the number of valid values per group, which is needed for `mean`
//   computation (sum / count) on the CPU side after readback.
//
// Merge Phase 1 — Hash Build with Chaining:
//
//   The `merge_hash_build` kernel inserts the right table's factorized key
//   codes into an open-addressing hash table. Unlike GroupBy's hash table
//   which stores one entry per unique key, the merge hash table must handle
//   **duplicate keys** in the right table (many-to-many joins). This is
//   accomplished using a separate `chain_next` linked list array:
//
//   1. Hash the code and probe for the correct slot via linear probing.
//   2. If the slot is empty (CAS succeeds), store the row index directly.
//   3. If the slot already contains the same key (duplicate), use
//      `atomic_exchange` to atomically swap in the new row index while
//      retrieving the previous head of the chain. The previous head is then
//      stored in `chain_next[tid]`, forming a singly-linked list of all
//      right-table rows with the same key. The chain is effectively built
//      in LIFO (stack) order.
//
// Merge Phase 2 — Hash Probe:
//
//   The `merge_hash_probe` kernel processes each left-table row by probing
//   the hash table built in Phase 1:
//
//   1. Hash the left code and linear-probe to find the matching slot.
//   2. If found, walk the `chain_next` linked list starting from the slot's
//      `row_index`, emitting an `(out_left[tid], out_right[ridx])` index pair
//      for every right-table row in the chain.
//   3. Output position is obtained via `atomic_fetch_add` on `outCount`,
//      which acts as a lock-free output cursor. If `outCount` exceeds
//      `maxOutput`, the pair is silently dropped (the caller detects this
//      overflow and falls back to CPU).
//   4. If the slot is empty (`EMPTY_SLOT`), the left row has no match (inner
//      join semantics: unmatched rows produce no output).
// ---------------------------------------------------------------------------

// Only needed for SPM builds where Metal shaders can't be precompiled.
// Xcode builds use .metal files compiled to default.metallib at build time.
#if SWIFT_PACKAGE
import Metal

/// Container for Metal Shading Language (MSL) source code strings.
///
/// All GPU compute kernels used by SwiftPandas are defined here as string
/// literals and compiled at runtime via `MTLDevice.makeLibrary(source:options:)`.
/// This enum is never instantiated — it serves purely as a namespace for the
/// static source strings.
internal enum MetalShaders {

    /// Combined MSL source for all shaders, formed by concatenating the
    /// common type definitions, GroupBy kernels, and Merge kernels into a
    /// single compilation unit.
    static let allSource: String = commonTypes + groupByShaders + mergeShaders

    // MARK: - Common Types & Hashing

    /// MSL source defining hash functions, the EMPTY_SLOT sentinel, and the
    /// validity bitmap accessor used by all kernels.
    static let commonTypes: String = """
    #include <metal_stdlib>
    using namespace metal;

    // MurmurHash3 finalizer (fmix32): a bit-mixing function with excellent
    // avalanche properties. Three rounds of XOR-shift-multiply ensure every
    // input bit affects every output bit, producing near-uniform hash
    // distribution even for sequential integer keys. The magic constants
    // 0x85ebca6b and 0xc2b2ae35 were selected by Austin Appleby for optimal
    // avalanche in the original MurmurHash3 specification.
    inline uint hash_uint(uint key) {
        key ^= key >> 16;
        key *= 0x85ebca6b;
        key ^= key >> 13;
        key *= 0xc2b2ae35;
        key ^= key >> 16;
        return key;
    }

    // Hashes a signed int32 by bitwise-reinterpreting it as unsigned first.
    // as_type<uint> performs a raw bitcast (not a value conversion), so
    // negative values like -1 (0xFFFFFFFF) are hashed as large unsigned ints
    // without sign-extension artifacts.
    inline uint hash_int32(int key) {
        return hash_uint(as_type<uint>(key));
    }

    // Combines two hash values using the Boost hash_combine formula.
    // The constant 0x9e3779b9 is the integer part of 2^32 / phi (golden
    // ratio), chosen because it produces a maximally spread sequence under
    // modular arithmetic. The asymmetric bidirectional shifts (<< 6, >> 2)
    // mix bits from both inputs, reducing collision rates for ordered pairs
    // (i.e., hash_combine(a, b) != hash_combine(b, a) in most cases).
    // Used for multi-column key hashing in GroupBy/Merge operations.
    inline uint hash_combine(uint h1, uint h2) {
        return h1 ^ (h2 + 0x9e3779b9 + (h1 << 6) + (h1 >> 2));
    }

    // Sentinel value indicating an unoccupied hash table slot.
    // Initialized via memset(0xFF) on the CPU side (0xFFFFFFFF = -1 in two's
    // complement signed representation).
    constant int EMPTY_SLOT = -1;

    // Checks whether row `idx` has a valid (non-null) value by reading the
    // packed validity bitmap.
    //
    // The bitmap is stored as [UInt64] words on the Swift side (BitVector),
    // but Metal only supports 32-bit atomic/scalar types. Each UInt64 word
    // is therefore accessed as a pair of adjacent UInt32 values in device
    // memory (little-endian layout on Apple GPUs).
    //
    // Indexing math:
    //   wordIdx  = idx / 64        — which UInt64 word
    //   bitIdx   = idx % 64        — bit position in that 64-bit word
    //   halfIdx  = wordIdx*2 + (bitIdx >= 32 ? 1 : 0) — which UInt32 half
    //   localBit = bitIdx % 32     — bit position within the UInt32 half
    //
    // Bits are stored LSB-first: bit 0 of word 0 corresponds to row 0.
    inline bool is_valid(device const uint* validity_words, uint idx) {
        uint wordIdx = idx / 64;
        uint bitIdx = idx % 64;
        uint halfIdx = wordIdx * 2 + (bitIdx >= 32 ? 1 : 0);
        uint localBit = bitIdx % 32;
        return (validity_words[halfIdx] >> localBit) & 1;
    }
    """

    // MARK: - GroupBy Shaders

    /// MSL source for GroupBy Phase 1 (hash insert) and Phase 2 (parallel
    /// reduction) kernels. See the file-level comment for detailed algorithmic
    /// documentation.
    static let groupByShaders: String = """

    // -----------------------------------------------------------------------
    // GroupBy Phase 1: Hash Insert
    // -----------------------------------------------------------------------
    // Purpose: Map each row's factorized group code to a dense group ID
    // (0, 1, 2, ...) via a lock-free, open-addressing hash table.
    //
    // Input:  codes[N]        — factorized integer code per row (-1 = null)
    // Output: row_to_group[N] — group ID per row (-1 = null row, excluded)
    //
    // Algorithm: Each thread claims a hash table slot via atomic CAS. The
    // first thread to insert a given code also assigns it a unique group ID
    // via atomic_fetch_add on nextGroupId. Subsequent threads with the same
    // code spin-wait until the group ID is written, then read it.
    //
    // The hash table uses power-of-two capacity with linear probing.
    // Load factor is kept below 50% (capacity = 2 * numDistinctCodes) to
    // minimize probe chain length and reduce contention.
    // -----------------------------------------------------------------------

    struct GroupByParams {
        uint n;              // Number of rows (threads to launch)
        uint capacity;       // Hash table capacity (power of two)
        atomic_uint nextGroupId;  // Monotonically increasing group ID counter
    };

    kernel void groupby_hash_insert(
        device const int*      codes         [[buffer(0)]],
        device atomic_int*     ht_keys       [[buffer(1)]],
        device atomic_int*     ht_group_ids  [[buffer(2)]],
        device int*            row_to_group  [[buffer(3)]],
        device GroupByParams&  params        [[buffer(4)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= params.n) return;

        int code = codes[tid];
        // Null rows (code < 0) are excluded from all groups
        if (code < 0) {
            row_to_group[tid] = -1;
            return;
        }

        // Power-of-two masking: equivalent to (slot % capacity) but branchless
        uint mask = params.capacity - 1;
        uint slot = hash_int32(code) & mask;

        while (true) {
            // Attempt to claim this slot with our code via CAS
            int expected = EMPTY_SLOT;
            if (atomic_compare_exchange_weak_explicit(
                    &ht_keys[slot], &expected, code,
                    memory_order_relaxed, memory_order_relaxed)) {
                // We won the slot — assign a new group ID atomically
                uint gid = atomic_fetch_add_explicit(
                    &params.nextGroupId, 1, memory_order_relaxed);
                atomic_store_explicit(
                    &ht_group_ids[slot], (int)gid, memory_order_relaxed);
                row_to_group[tid] = (int)gid;
                return;
            }
            // CAS failed — another thread already claimed this slot
            int current = atomic_load_explicit(&ht_keys[slot], memory_order_relaxed);
            if (current == code) {
                // Same key — read the group ID (spin-wait if the winning thread
                // hasn't written it yet; this window is extremely short)
                int gid = atomic_load_explicit(&ht_group_ids[slot], memory_order_relaxed);
                while (gid == EMPTY_SLOT) {
                    gid = atomic_load_explicit(&ht_group_ids[slot], memory_order_relaxed);
                }
                row_to_group[tid] = gid;
                return;
            }
            // Different key — hash collision, linear probe to next slot
            slot = (slot + 1) & mask;
        }
    }

    // -----------------------------------------------------------------------
    // GroupBy Phase 2: Parallel Reduction Kernels
    // -----------------------------------------------------------------------
    // Each kernel launches one thread per row. Every thread reads its value
    // and the row-to-group mapping, then atomically updates the group's
    // accumulator. This "scatter" pattern avoids the need for segmented
    // reductions or sorting by group.
    //
    // All kernels skip null rows (gid < 0) and invalid values (bitmap check).
    //
    // Sum:   atomic_fetch_add on atomic_float (hardware-supported on Apple GPU)
    // Min:   atomic CAS loop — retry until our value >= current minimum
    // Max:   atomic CAS loop — retry until our value <= current maximum
    // Count: atomic_fetch_add on atomic_uint (counts valid non-null rows)
    //
    // The counts array is maintained by all kernels (not just count) because
    // the CPU needs it to compute mean = sum / count after GPU readback.
    // -----------------------------------------------------------------------

    kernel void groupby_reduce_sum(
        device const float*    values         [[buffer(0)]],
        device const uint*     validity_words [[buffer(1)]],
        device const int*      row_to_group   [[buffer(2)]],
        device atomic_float*   accum          [[buffer(3)]],
        device atomic_uint*    counts         [[buffer(4)]],
        device const uint&     n              [[buffer(5)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= n) return;
        int gid = row_to_group[tid];
        if (gid < 0) return;
        if (!is_valid(validity_words, tid)) return;

        float val = values[tid];
        atomic_fetch_add_explicit(&accum[gid], val, memory_order_relaxed);
        atomic_fetch_add_explicit(&counts[gid], 1, memory_order_relaxed);
    }

    // Min reduction: uses atomic CAS loop because Metal has no atomic_min for
    // floats. Loads the current minimum, checks if our value is smaller, and
    // attempts to swap. The CAS may fail if another thread updated concurrently,
    // in which case `old` is refreshed with the new value and we retry.
    kernel void groupby_reduce_min(
        device const float*    values         [[buffer(0)]],
        device const uint*     validity_words [[buffer(1)]],
        device const int*      row_to_group   [[buffer(2)]],
        device atomic_float*   accum          [[buffer(3)]],
        device atomic_uint*    counts         [[buffer(4)]],
        device const uint&     n              [[buffer(5)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= n) return;
        int gid = row_to_group[tid];
        if (gid < 0) return;
        if (!is_valid(validity_words, tid)) return;

        float val = values[tid];
        float old = atomic_load_explicit(&accum[gid], memory_order_relaxed);
        while (val < old) {
            if (atomic_compare_exchange_weak_explicit(
                    &accum[gid], &old, val,
                    memory_order_relaxed, memory_order_relaxed)) {
                break;
            }
            // CAS failed: `old` now holds the updated value; loop re-checks
        }
        atomic_fetch_add_explicit(&counts[gid], 1, memory_order_relaxed);
    }

    // Max reduction: symmetric to min, but checks (val > old) instead.
    kernel void groupby_reduce_max(
        device const float*    values         [[buffer(0)]],
        device const uint*     validity_words [[buffer(1)]],
        device const int*      row_to_group   [[buffer(2)]],
        device atomic_float*   accum          [[buffer(3)]],
        device atomic_uint*    counts         [[buffer(4)]],
        device const uint&     n              [[buffer(5)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= n) return;
        int gid = row_to_group[tid];
        if (gid < 0) return;
        if (!is_valid(validity_words, tid)) return;

        float val = values[tid];
        float old = atomic_load_explicit(&accum[gid], memory_order_relaxed);
        while (val > old) {
            if (atomic_compare_exchange_weak_explicit(
                    &accum[gid], &old, val,
                    memory_order_relaxed, memory_order_relaxed)) {
                break;
            }
            // CAS failed: `old` now holds the updated value; loop re-checks
        }
        atomic_fetch_add_explicit(&counts[gid], 1, memory_order_relaxed);
    }

    // Count reduction: the simplest kernel — just counts valid rows per group.
    // Does not need a values buffer since it only checks validity.
    kernel void groupby_reduce_count(
        device const uint*     validity_words [[buffer(0)]],
        device const int*      row_to_group   [[buffer(1)]],
        device atomic_uint*    counts         [[buffer(2)]],
        device const uint&     n              [[buffer(3)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= n) return;
        int gid = row_to_group[tid];
        if (gid < 0) return;
        if (!is_valid(validity_words, tid)) return;

        atomic_fetch_add_explicit(&counts[gid], 1, memory_order_relaxed);
    }
    """

    // MARK: - Merge Shaders

    /// MSL source for Merge (hash join) Phase 1 (hash build) and Phase 2
    /// (hash probe) kernels. See the file-level comment for detailed
    /// algorithmic documentation.
    static let mergeShaders: String = """

    // -----------------------------------------------------------------------
    // Merge Phase 1: Hash Build
    // -----------------------------------------------------------------------
    // Purpose: Build a hash table from the right table's factorized key codes,
    // supporting duplicate keys via a per-row linked list (chain_next).
    //
    // Input:  right_codes[N] — factorized integer code per right-table row
    // Output: hash_table     — open-addressing table of (key, row_index) pairs
    //         chain_next[N]  — linked list: chain_next[i] = previous row with
    //                          same key, or -1 if this is the oldest entry
    //
    // The hash table stores one slot per unique key. When a duplicate key is
    // inserted, the new row atomically replaces the slot's row_index (via
    // atomic_exchange), and the previous row_index is saved in chain_next.
    // This builds a LIFO singly-linked list of all right-table rows sharing
    // the same key, enabling many-to-many join semantics in Phase 2.
    // -----------------------------------------------------------------------

    struct MergeHashEntry {
        atomic_int key;        // Factorized key code (EMPTY_SLOT = unoccupied)
        atomic_int row_index;  // Head of the chain for this key
    };

    struct MergeBuildParams {
        uint n;         // Number of right-table rows
        uint capacity;  // Hash table capacity (power of two)
    };

    kernel void merge_hash_build(
        device const int*        right_codes  [[buffer(0)]],
        device MergeHashEntry*   hash_table   [[buffer(1)]],
        device atomic_int*       chain_next   [[buffer(2)]],
        device MergeBuildParams& params       [[buffer(3)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= params.n) return;

        int code = right_codes[tid];
        if (code < 0) return;  // Null key — skip

        uint mask = params.capacity - 1;
        uint slot = hash_int32(code) & mask;

        while (true) {
            // Try to claim an empty slot via CAS
            int expected = EMPTY_SLOT;
            if (atomic_compare_exchange_weak_explicit(
                    &hash_table[slot].key, &expected, code,
                    memory_order_relaxed, memory_order_relaxed)) {
                // First row with this key in this slot — store directly
                atomic_store_explicit(
                    &hash_table[slot].row_index, (int)tid,
                    memory_order_relaxed);
                return;
            }
            int current = atomic_load_explicit(
                &hash_table[slot].key, memory_order_relaxed);
            if (current == code) {
                // Duplicate key — prepend to the chain. atomic_exchange
                // atomically swaps in our row index and returns the previous
                // head, which we link via chain_next to form a LIFO list.
                int old_head = atomic_exchange_explicit(
                    &hash_table[slot].row_index, (int)tid,
                    memory_order_relaxed);
                atomic_store_explicit(
                    &chain_next[tid], old_head,
                    memory_order_relaxed);
                return;
            }
            // Hash collision (different key) — linear probe
            slot = (slot + 1) & mask;
        }
    }

    // -----------------------------------------------------------------------
    // Merge Phase 2: Hash Probe
    // -----------------------------------------------------------------------
    // Purpose: For each left-table row, find all matching right-table rows
    // and emit (left_index, right_index) pairs into the output arrays.
    //
    // Input:  left_codes[N]  — factorized integer code per left-table row
    //         hash_table     — built in Phase 1
    //         chain_next     — linked list for duplicate right keys
    // Output: out_left[M], out_right[M] — matched index pairs
    //         params.outCount — total number of output pairs (atomic counter)
    //
    // Each thread walks the chain_next linked list for its matching key,
    // emitting one output pair per right-table match. The output position
    // is claimed via atomic_fetch_add on outCount, providing a lock-free
    // output cursor. If outCount exceeds maxOutput, pairs are silently
    // dropped — the CPU side detects this overflow condition and falls back
    // to CPU-based merge.
    //
    // For inner join semantics: left rows with no match (empty slot hit)
    // produce no output and are effectively filtered out.
    // -----------------------------------------------------------------------

    struct MergeProbeParams {
        uint n;              // Number of left-table rows
        uint capacity;       // Hash table capacity (must match build phase)
        atomic_uint outCount; // Atomic output cursor (initialized to 0)
        uint maxOutput;      // Maximum output pairs before overflow
    };

    kernel void merge_hash_probe(
        device const int*        left_codes   [[buffer(0)]],
        device MergeHashEntry*   hash_table   [[buffer(1)]],
        device const int*        chain_next   [[buffer(2)]],
        device int*              out_left     [[buffer(3)]],
        device int*              out_right    [[buffer(4)]],
        device MergeProbeParams& params       [[buffer(5)]],
        uint tid [[thread_position_in_grid]]
    ) {
        if (tid >= params.n) return;

        int code = left_codes[tid];
        if (code < 0) return;  // Null key — no match possible

        uint mask = params.capacity - 1;
        uint slot = hash_int32(code) & mask;

        while (true) {
            int key = atomic_load_explicit(
                &hash_table[slot].key, memory_order_relaxed);
            // Empty slot means no match exists (inner join: skip)
            if (key == EMPTY_SLOT) return;
            if (key == code) {
                // Found matching key — walk the chain to emit all matches
                int ridx = atomic_load_explicit(
                    &hash_table[slot].row_index, memory_order_relaxed);
                while (ridx >= 0) {
                    // Claim an output slot atomically
                    uint pos = atomic_fetch_add_explicit(
                        &params.outCount, 1, memory_order_relaxed);
                    if (pos < params.maxOutput) {
                        out_left[pos] = (int)tid;
                        out_right[pos] = ridx;
                    }
                    // Follow the chain to the next right-table row with same key
                    ridx = chain_next[ridx];
                }
                return;
            }
            // Hash collision (different key) — linear probe
            slot = (slot + 1) & mask;
        }
    }
    """
}
#endif
