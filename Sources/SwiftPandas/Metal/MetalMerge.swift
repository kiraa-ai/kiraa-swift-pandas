// MARK: - MetalMerge.swift
// ---------------------------------------------------------------------------
// GPU-Accelerated Hash Join (Merge) for SwiftPandas
// ---------------------------------------------------------------------------
//
// This file implements GPU-accelerated inner join (merge) between two
// DataFrames using Metal compute shaders. The algorithm is a classic
// hash join with two GPU phases: hash build and hash probe.
//
// Architecture Overview — Two-Phase GPU Hash Join:
//
//   Phase 1 — Hash Build (merge_hash_build kernel):
//     Builds a hash table from the **right** table's key column. Each entry
//     in the hash table stores a (key, row_index) pair. The table uses
//     open-addressing with linear probing: each thread computes a hash slot,
//     then atomically claims it with CAS. If the slot is already occupied by
//     the **same** key (duplicate), the new row is chained via a separate
//     `chain_next` array — effectively a per-slot linked list stored as
//     row indices. This handles many-to-many joins where the right table
//     has duplicate keys.
//
//   Phase 2 — Hash Probe (merge_hash_probe kernel):
//     Each left-table row probes the hash table by hashing its key and
//     walking the open-addressing slots until it finds a match or an empty
//     slot. On match, it follows the `chain_next` linked list to emit a
//     (left_row, right_row) pair for every matching right-table row. Output
//     pairs are written to pre-allocated output buffers using an atomic
//     counter to ensure thread-safe, contiguous output.
//
// Hash Table Design:
//
//   - Open-addressing with linear probing for slot collision resolution.
//   - Capacity is always a power of two (enables fast modulo via bitmask).
//   - Load factor <= 0.5 (capacity = nextPowerOfTwo(rightN * 2)).
//   - Duplicate keys in the right table are handled via chaining: the
//     `chain_next[row_index]` array forms a singly-linked list per slot.
//   - Sentinel value -1 (0xFFFFFFFF) marks empty slots and list terminators.
//
// Co-Factorization:
//
// Before GPU execution, both left and right key columns are factorized
// into a **shared** code space, ensuring that the same value in both
// tables receives the same integer code. This is essential for correct
// hash-based matching on the GPU, where keys are compared as integers.
// Null/NA values receive code -1 and never match.
//
// Output Sizing:
//
// The worst-case output size for an inner join is leftN * rightN (full
// cross product). To avoid excessive memory allocation, the output buffer
// is capped at `min(leftN * rightN, leftN * 10 + rightN * 10 + 100_000)`.
// If the GPU produces more matches than the buffer can hold, the method
// returns `nil` and the caller falls back to the CPU implementation,
// which can handle arbitrary output sizes via dynamic array growth.
//
// Fallback:
//
// The `innerJoin` method returns `nil` if any step fails (no Metal
// device, empty tables, buffer allocation failure, output overflow),
// allowing transparent fallback to the CPU merge implementation.
// ---------------------------------------------------------------------------

import Metal

/// GPU-accelerated Merge (hash join) engine.
///
/// Provides a single entry point (`innerJoin`) that performs a complete
/// GPU hash join: co-factorize keys, GPU hash build, GPU hash probe,
/// and result DataFrame assembly. Returns `nil` on failure for CPU fallback.
internal enum MetalMerge {

    /// Perform GPU-accelerated inner join between two DataFrames.
    ///
    /// Joins `left` and `right` on a single key column using a GPU hash join.
    /// The right table is used to build the hash table (build side), and the
    /// left table probes it (probe side). This choice is arbitrary for inner
    /// joins but conventionally uses the smaller table as the build side;
    /// callers should swap arguments if needed for optimal performance.
    ///
    /// - Parameters:
    ///   - left: The left (probe-side) DataFrame.
    ///   - right: The right (build-side) DataFrame.
    ///   - key: The column name to join on (must exist in both DataFrames).
    /// - Returns: A new DataFrame containing all matching row pairs, or `nil`
    ///   if GPU execution fails (caller should fall back to CPU).
    ///   Right-table columns that conflict with left-table names get a
    ///   `_right` suffix. The join key column appears only once (from left).
    static func innerJoin(
        left: DataFrame,
        right: DataFrame,
        on key: String
    ) -> DataFrame? {
        guard let ctx = MetalContext.shared else { return nil }
        guard left.rowCount > 0 && right.rowCount > 0 else { return nil }

        // Step 1: Co-factorize left and right key columns into a shared integer code space.
        // Both columns must map identical values to the same code for GPU matching to work.
        guard let leftCol = left.columns[key],
              let rightCol = right.columns[key]
        else { return nil }

        let (leftCodes, rightCodes) = coFactorize(leftCol: leftCol, rightCol: rightCol)
        guard !leftCodes.isEmpty && !rightCodes.isEmpty else { return nil }

        let leftN = left.rowCount
        let rightN = right.rowCount

        let leftInt32 = leftCodes.map { Int32($0) }
        let rightInt32 = rightCodes.map { Int32($0) }

        // Step 2: GPU hash build from right table.
        // Hash table capacity is next power of two >= 2x right table size
        // for a load factor <= 0.5, minimizing probe chain lengths.
        let htCapacity = nextPowerOfTwo(rightN * 2)

        guard let rightCodesBuffer = ctx.makeBuffer(from: rightInt32) else { return nil }

        // Hash table entries: pairs of (key: Int32, row_index: Int32) = 8 bytes each.
        // Both fields are atomic on the GPU side (MergeHashEntry struct).
        let entrySize = MemoryLayout<Int32>.stride * 2  // key + row_index
        guard let hashTableBuffer = ctx.makeBuffer(length: htCapacity * entrySize) else { return nil }
        // Initialize all slots to -1 (EMPTY_SLOT sentinel)
        memset(hashTableBuffer.contents(), 0xFF, hashTableBuffer.length)

        // Chain array for handling duplicate right-table keys.
        // chain_next[row_i] points to the previous row with the same key,
        // forming a singly-linked list per hash slot. -1 = end of chain.
        guard let chainNextBuffer = ctx.makeBuffer(length: rightN * MemoryLayout<Int32>.stride) else { return nil }
        memset(chainNextBuffer.contents(), 0xFF, chainNextBuffer.length)  // -1 = no next

        // MergeBuildParams struct layout: { n: uint32, capacity: uint32 }
        var buildParams: (UInt32, UInt32) = (UInt32(rightN), UInt32(htCapacity))
        guard let buildParamsBuffer = ctx.device.makeBuffer(
            bytes: &buildParams,
            length: MemoryLayout<(UInt32, UInt32)>.stride,
            options: .storageModeShared
        ) else { return nil }

        // Dispatch Phase 1: one thread per right-table row inserts into the hash table.
        ctx.dispatch(
            pipeline: ctx.mergeHashBuildPipeline,
            buffers: [
                (rightCodesBuffer, 0),
                (hashTableBuffer, 1),
                (chainNextBuffer, 2),
                (buildParamsBuffer, 3),
            ],
            threadCount: rightN
        )

        // Step 3: GPU hash probe from left table.
        guard let leftCodesBuffer = ctx.makeBuffer(from: leftInt32) else { return nil }

        // Allocate output buffers for matched (left_row, right_row) index pairs.
        // The cap is a heuristic to avoid allocating the full cross-product size.
        // If the actual match count exceeds this, we return nil for CPU fallback.
        let maxOutput = min(leftN * rightN, leftN * 10 + rightN * 10 + 100_000)

        guard let outLeftBuffer = ctx.makeBuffer(length: maxOutput * MemoryLayout<Int32>.stride),
              let outRightBuffer = ctx.makeBuffer(length: maxOutput * MemoryLayout<Int32>.stride)
        else { return nil }

        // MergeProbeParams struct layout: { n: uint32, capacity: uint32, outCount: atomic_uint, maxOutput: uint32 }
        var probeParams: (UInt32, UInt32, UInt32, UInt32) = (
            UInt32(leftN), UInt32(htCapacity), 0, UInt32(maxOutput)
        )
        guard let probeParamsBuffer = ctx.device.makeBuffer(
            bytes: &probeParams,
            length: MemoryLayout<(UInt32, UInt32, UInt32, UInt32)>.stride,
            options: .storageModeShared
        ) else { return nil }

        // Dispatch Phase 2: one thread per left-table row probes the hash table
        // and emits all matching (left, right) index pairs.
        ctx.dispatch(
            pipeline: ctx.mergeHashProbePipeline,
            buffers: [
                (leftCodesBuffer, 0),
                (hashTableBuffer, 1),
                (chainNextBuffer, 2),
                (outLeftBuffer, 3),
                (outRightBuffer, 4),
                (probeParamsBuffer, 5),
            ],
            threadCount: leftN
        )

        // Read the number of output pairs produced by the GPU.
        // Located at byte offset 8 in probeParams (after n and capacity fields).
        let outCount = Int(probeParamsBuffer.contents()
            .advanced(by: 8) // skip n + capacity
            .assumingMemoryBound(to: UInt32.self).pointee)

        // Check for output buffer overflow — fall back to CPU if exceeded
        if outCount > maxOutput {
            return nil
        }

        guard outCount > 0 else {
            // No matches — return an empty DataFrame with the correct schema
            var resultCols = [(String, Column)]()
            for name in left.columnNames {
                let col = left.columns[name]!
                resultCols.append((name, col.take(indices: [])))
            }
            for name in right.columnNames where name != key {
                let suffix = left.columnNames.contains(name) ? "_right" : ""
                resultCols.append((name + suffix, right.columns[name]!.take(indices: [])))
            }
            return DataFrame(columns: resultCols)
        }

        // Step 4: Read back matched index pairs and assemble the result DataFrame.
        // Each output pair (leftIdx, rightIdx) selects one row from each input table.
        let outLeftPtr = outLeftBuffer.contents().assumingMemoryBound(to: Int32.self)
        let outRightPtr = outRightBuffer.contents().assumingMemoryBound(to: Int32.self)

        let leftIndices = (0..<outCount).map { Int(outLeftPtr[$0]) }
        let rightIndices = (0..<outCount).map { Int(outRightPtr[$0]) }

        // Build result DataFrame using Column.take to gather rows by index.
        // Left-table columns come first, then right-table columns (excluding the join key).
        // Conflicting column names from the right table get a "_right" suffix.
        var resultCols = [(String, Column)]()
        for name in left.columnNames {
            resultCols.append((name, left.columns[name]!.take(indices: leftIndices)))
        }
        for name in right.columnNames where name != key {
            let suffix = left.columnNames.contains(name) ? "_right" : ""
            resultCols.append((name + suffix, right.columns[name]!.take(indices: rightIndices)))
        }

        return DataFrame(columns: resultCols)
    }

    // MARK: - Co-Factorization

    /// Factorize left and right key columns into a shared integer code space.
    ///
    /// Both columns are mapped using the **same** dictionary, so identical values
    /// in left and right receive the same integer code. This is essential for
    /// GPU hash join correctness — keys are compared as integers on the GPU.
    ///
    /// Supports `.string`, `.double`, and `.int64` column types. Returns empty
    /// arrays for unsupported or mismatched types.
    ///
    /// Null values in either column receive code -1 and will never match
    /// during the GPU probe phase (the kernel skips negative codes).
    ///
    /// - Parameters:
    ///   - leftCol: The left DataFrame's key column.
    ///   - rightCol: The right DataFrame's key column.
    /// - Returns: A tuple of (leftCodes, rightCodes) where each array has
    ///   the same length as the corresponding input column. Codes are
    ///   contiguous integers starting from 0; -1 indicates null.
    private static func coFactorize(
        leftCol: Column,
        rightCol: Column
    ) -> (leftCodes: [Int], rightCodes: [Int]) {
        switch (leftCol, rightCol) {
        case (.string(let lArr), .string(let rArr)):
            var mapping = [String: Int]()
            var leftCodes = [Int]()
            var rightCodes = [Int]()
            leftCodes.reserveCapacity(lArr.count)
            rightCodes.reserveCapacity(rArr.count)

            // Factorize left column first, building the shared mapping
            for i in 0..<lArr.count {
                if let s = lArr[i] {
                    if let code = mapping[s] {
                        leftCodes.append(code)
                    } else {
                        let code = mapping.count
                        mapping[s] = code
                        leftCodes.append(code)
                    }
                } else {
                    leftCodes.append(-1)
                }
            }
            // Factorize right column using the same mapping (extending it for new values)
            for i in 0..<rArr.count {
                if let s = rArr[i] {
                    if let code = mapping[s] {
                        rightCodes.append(code)
                    } else {
                        let code = mapping.count
                        mapping[s] = code
                        rightCodes.append(code)
                    }
                } else {
                    rightCodes.append(-1)
                }
            }
            return (leftCodes, rightCodes)

        case (.double(let lArr), .double(let rArr)):
            var mapping = [Double: Int]()
            var leftCodes = [Int]()
            var rightCodes = [Int]()
            leftCodes.reserveCapacity(lArr.count)
            rightCodes.reserveCapacity(rArr.count)

            for i in 0..<lArr.count {
                if let v = lArr[i] {
                    if let code = mapping[v] {
                        leftCodes.append(code)
                    } else {
                        let code = mapping.count
                        mapping[v] = code
                        leftCodes.append(code)
                    }
                } else {
                    leftCodes.append(-1)
                }
            }
            for i in 0..<rArr.count {
                if let v = rArr[i] {
                    if let code = mapping[v] {
                        rightCodes.append(code)
                    } else {
                        let code = mapping.count
                        mapping[v] = code
                        rightCodes.append(code)
                    }
                } else {
                    rightCodes.append(-1)
                }
            }
            return (leftCodes, rightCodes)

        case (.int64(let lArr), .int64(let rArr)):
            var mapping = [Int64: Int]()
            var leftCodes = [Int]()
            var rightCodes = [Int]()
            leftCodes.reserveCapacity(lArr.count)
            rightCodes.reserveCapacity(rArr.count)

            for i in 0..<lArr.count {
                if let v = lArr[i] {
                    if let code = mapping[v] {
                        leftCodes.append(code)
                    } else {
                        let code = mapping.count
                        mapping[v] = code
                        leftCodes.append(code)
                    }
                } else {
                    leftCodes.append(-1)
                }
            }
            for i in 0..<rArr.count {
                if let v = rArr[i] {
                    if let code = mapping[v] {
                        rightCodes.append(code)
                    } else {
                        let code = mapping.count
                        mapping[v] = code
                        rightCodes.append(code)
                    }
                } else {
                    rightCodes.append(-1)
                }
            }
            return (leftCodes, rightCodes)

        default:
            return ([], [])
        }
    }

    // MARK: - Utility

    /// Round up to the next power of two.
    ///
    /// Used to size hash tables so that capacity is always a power of two,
    /// enabling fast modulo via bitwise AND (`slot & (capacity - 1)`).
    ///
    /// - Parameter n: The minimum desired capacity.
    /// - Returns: The smallest power of two >= `n` (minimum 1).
    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var v = max(n, 1)
        v -= 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v += 1
        return v
    }
}
