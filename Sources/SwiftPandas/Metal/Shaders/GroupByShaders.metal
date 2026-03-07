#include "ShaderCommon.h"

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
