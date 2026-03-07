#include "ShaderCommon.h"

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
