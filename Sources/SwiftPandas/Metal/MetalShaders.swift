import Metal

/// Metal Shading Language source code for all GPU compute kernels.
/// Compiled at runtime via MTLDevice.makeLibrary(source:options:).
internal enum MetalShaders {

    /// Combined MSL source for all shaders.
    static let allSource: String = commonTypes + groupByShaders + mergeShaders

    // MARK: - Common Types & Hashing

    static let commonTypes: String = """
    #include <metal_stdlib>
    using namespace metal;

    // MurmurHash3-style finalizer for integer hashing
    inline uint hash_uint(uint key) {
        key ^= key >> 16;
        key *= 0x85ebca6b;
        key ^= key >> 13;
        key *= 0xc2b2ae35;
        key ^= key >> 16;
        return key;
    }

    inline uint hash_int32(int key) {
        return hash_uint(as_type<uint>(key));
    }

    inline uint hash_combine(uint h1, uint h2) {
        return h1 ^ (h2 + 0x9e3779b9 + (h1 << 6) + (h1 >> 2));
    }

    constant int EMPTY_SLOT = -1;

    // Check validity bit in a packed bitmap.
    // BitVector stores [UInt64] words, accessed as pairs of uint32 on GPU.
    // Bit i is at words[i/64], bit position (i%64), LSB-first.
    inline bool is_valid(device const uint* validity_words, uint idx) {
        uint wordIdx = idx / 64;
        uint bitIdx = idx % 64;
        uint halfIdx = wordIdx * 2 + (bitIdx >= 32 ? 1 : 0);
        uint localBit = bitIdx % 32;
        return (validity_words[halfIdx] >> localBit) & 1;
    }
    """

    // MARK: - GroupBy Shaders

    static let groupByShaders: String = """

    // GroupBy Phase 1: Hash Insert
    // Maps each row's factorized code to a group ID via open-addressing hash table.
    // Output: row_to_group[N] mapping each row to its group index.

    struct GroupByParams {
        uint n;
        uint capacity;
        atomic_uint nextGroupId;
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
        if (code < 0) {
            row_to_group[tid] = -1;
            return;
        }

        uint mask = params.capacity - 1;
        uint slot = hash_int32(code) & mask;

        while (true) {
            int expected = EMPTY_SLOT;
            if (atomic_compare_exchange_weak_explicit(
                    &ht_keys[slot], &expected, code,
                    memory_order_relaxed, memory_order_relaxed)) {
                uint gid = atomic_fetch_add_explicit(
                    &params.nextGroupId, 1, memory_order_relaxed);
                atomic_store_explicit(
                    &ht_group_ids[slot], (int)gid, memory_order_relaxed);
                row_to_group[tid] = (int)gid;
                return;
            }
            int current = atomic_load_explicit(&ht_keys[slot], memory_order_relaxed);
            if (current == code) {
                int gid = atomic_load_explicit(&ht_group_ids[slot], memory_order_relaxed);
                while (gid == EMPTY_SLOT) {
                    gid = atomic_load_explicit(&ht_group_ids[slot], memory_order_relaxed);
                }
                row_to_group[tid] = gid;
                return;
            }
            slot = (slot + 1) & mask;
        }
    }

    // GroupBy Phase 2: Parallel Reduction Kernels
    // Each thread handles one row, atomically accumulates to its group.

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
        }
        atomic_fetch_add_explicit(&counts[gid], 1, memory_order_relaxed);
    }

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
        }
        atomic_fetch_add_explicit(&counts[gid], 1, memory_order_relaxed);
    }

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

    static let mergeShaders: String = """

    // Merge Phase 1: Hash Build
    // Builds hash table from right table's factorized key codes.
    // Duplicate keys are chained via chain_next linked list.

    struct MergeHashEntry {
        atomic_int key;
        atomic_int row_index;
    };

    struct MergeBuildParams {
        uint n;
        uint capacity;
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
        if (code < 0) return;

        uint mask = params.capacity - 1;
        uint slot = hash_int32(code) & mask;

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
    }

    // Merge Phase 2: Hash Probe
    // Each left-table row probes the hash table for matches.

    struct MergeProbeParams {
        uint n;
        uint capacity;
        atomic_uint outCount;
        uint maxOutput;
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
        if (code < 0) return;

        uint mask = params.capacity - 1;
        uint slot = hash_int32(code) & mask;

        while (true) {
            int key = atomic_load_explicit(
                &hash_table[slot].key, memory_order_relaxed);
            if (key == EMPTY_SLOT) return;
            if (key == code) {
                int ridx = atomic_load_explicit(
                    &hash_table[slot].row_index, memory_order_relaxed);
                while (ridx >= 0) {
                    uint pos = atomic_fetch_add_explicit(
                        &params.outCount, 1, memory_order_relaxed);
                    if (pos < params.maxOutput) {
                        out_left[pos] = (int)tid;
                        out_right[pos] = ridx;
                    }
                    ridx = chain_next[ridx];
                }
                return;
            }
            slot = (slot + 1) & mask;
        }
    }
    """
}
