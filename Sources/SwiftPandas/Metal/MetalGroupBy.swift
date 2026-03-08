// MARK: - MetalGroupBy.swift
// ---------------------------------------------------------------------------
// GPU-Accelerated GroupBy Aggregation for SwiftPandas
// ---------------------------------------------------------------------------
//
// This file implements GPU-accelerated GroupBy aggregation using Metal
// compute shaders. It supports sum, mean, count, min, and max operations
// on numeric columns, grouped by one or more key columns.
//
// Architecture Overview — Two-Phase GPU GroupBy:
//
// The GPU GroupBy uses a two-phase approach to parallelize aggregation:
//
//   Phase 1 — Hash Insert (groupby_hash_insert kernel):
//     Each row's factorized group code is inserted into an open-addressing
//     hash table on the GPU. The hash table maps codes to group IDs (0, 1,
//     2, ...) using atomic compare-and-swap for thread-safe insertion. The
//     output is a `row_to_group[N]` array that maps each row index to its
//     assigned group ID. A global atomic counter (`nextGroupId`) ensures
//     unique group ID assignment.
//
//   Phase 2 — Parallel Reduction (groupby_reduce_* kernels):
//     Each thread processes one row: it reads the row's value, looks up the
//     group ID from `row_to_group`, and atomically accumulates the value
//     into the group's accumulator. Different aggregation operations use
//     different atomic strategies:
//       - sum:   atomic_fetch_add on float accumulators
//       - count: atomic_fetch_add on uint counters
//       - min:   atomic compare-and-swap (CAS) loop to update minimum
//       - max:   atomic compare-and-swap (CAS) loop to update maximum
//       - mean:  computed as sum/count on the CPU after GPU reduction
//
// Factorization:
//
// Before GPU execution, group key columns must be converted to dense
// integer codes (factorization). This maps arbitrary column values
// (strings, doubles, int64s) to contiguous integers starting from 0.
// For multi-column GroupBy, composite keys are formed by joining column
// values with a tab separator and mapping the composite string to codes.
// Null/NA values receive a code of -1 and are excluded from all groups.
//
// Validity Bitmap:
//
// The GPU kernels respect the per-column validity bitmap from
// `NullableArray`. The bitmap is stored as `[UInt64]` words on the CPU
// and is transmitted to the GPU as pairs of `uint32` values (LSB-first
// bit ordering). The `is_valid()` MSL function checks individual bits
// by computing the word index and bit position. Rows with invalid
// (null) values are skipped during reduction.
//
// Float Precision:
//
// GPU reduction uses Float32 (not Float64) because Metal's atomic_float
// only supports 32-bit atomics. This means GPU GroupBy results may have
// lower precision than the CPU path for very large values or sums of
// many values. The Double->Float conversion happens before GPU dispatch,
// and Float->Double conversion happens when reading back results.
//
// Fallback:
//
// The `aggregate` method returns `nil` if any step fails (no Metal
// device, empty data, buffer allocation failure, etc.), allowing the
// caller to transparently fall back to the CPU GroupBy implementation.
// ---------------------------------------------------------------------------

import Metal

/// GPU-accelerated GroupBy aggregation engine.
///
/// Provides a single entry point (`aggregate`) that performs the full GroupBy
/// pipeline: factorize keys, GPU hash insert, GPU reduction, and result
/// assembly. Returns `nil` on failure so callers can fall back to CPU.
internal enum MetalGroupBy {

    /// Supported aggregation operations on GPU.
    ///
    /// Each operation corresponds to a dedicated Metal compute kernel,
    /// except `.mean` which is computed as `.sum` divided by `.count`
    /// on the CPU after GPU reduction completes.
    enum AggOp {
        case sum, mean, count, min, max
    }

    /// Perform GPU-accelerated GroupBy aggregation on a DataFrame.
    ///
    /// Executes the full two-phase GPU GroupBy pipeline:
    /// 1. Factorize group key columns to integer codes on CPU.
    /// 2. GPU Phase 1: Hash insert to assign group IDs to each row.
    /// 3. GPU Phase 2: Parallel atomic reduction per numeric column.
    /// 4. Assemble result DataFrame with group keys and aggregated values.
    ///
    /// - Parameters:
    ///   - dataFrame: The source DataFrame to aggregate.
    ///   - groupColumns: Column names to group by (supports single or multi-column).
    ///   - op: The aggregation operation to apply to all numeric columns.
    /// - Returns: A new DataFrame with one row per group and aggregated values,
    ///   or `nil` if GPU execution fails (caller should fall back to CPU).
    static func aggregate(
        dataFrame: DataFrame,
        by groupColumns: [String],
        op: AggOp
    ) -> DataFrame? {
        guard let ctx = MetalContext.shared else { return nil }
        let n = dataFrame.rowCount
        guard n > 0 else { return nil }

        // Step 1: Factorize group columns to integer codes on CPU.
        // Each unique group key combination gets a code (0, 1, 2, ...).
        // Null values get code -1 and are excluded from grouping.
        let (codes, groupKeys) = factorizeGroupColumns(dataFrame: dataFrame, by: groupColumns)
        guard !codes.isEmpty else { return nil }
        let numDistinctCodes = groupKeys.count
        guard numDistinctCodes > 0 else { return nil }

        // Step 2: GPU hash insert — maps each row to a group ID.
        // The hash table capacity is the next power of two >= 2x the number
        // of distinct codes, ensuring a load factor <= 0.5 to minimize
        // collisions in the open-addressing scheme.
        let int32Codes = codes.map { Int32($0) }
        let htCapacity = nextPowerOfTwo(numDistinctCodes * 2)

        guard let codesBuffer = ctx.makeBuffer(from: int32Codes) else { return nil }

        guard let htKeysBuffer = ctx.makeBuffer(length: htCapacity * MemoryLayout<Int32>.stride),
              let htGroupIdsBuffer = ctx.makeBuffer(length: htCapacity * MemoryLayout<Int32>.stride),
              let rowToGroupBuffer = ctx.makeBuffer(length: n * MemoryLayout<Int32>.stride)
        else { return nil }

        // Initialize hash table slots to -1 (EMPTY_SLOT sentinel).
        // 0xFF fills each byte, producing -1 for signed two's complement Int32.
        memset(htKeysBuffer.contents(), 0xFF, htKeysBuffer.length)
        memset(htGroupIdsBuffer.contents(), 0xFF, htGroupIdsBuffer.length)

        // GroupByParams struct layout: { n: uint32, capacity: uint32, nextGroupId: atomic_uint }
        var paramsData: (UInt32, UInt32, UInt32) = (UInt32(n), UInt32(htCapacity), 0)
        guard let paramsBuffer = ctx.device.makeBuffer(
            bytes: &paramsData,
            length: MemoryLayout<(UInt32, UInt32, UInt32)>.stride,
            options: .storageModeShared
        ) else { return nil }

        // Dispatch Phase 1: one thread per row inserts its code into the hash table
        // and writes the assigned group ID to row_to_group[tid].
        ctx.dispatch(
            pipeline: ctx.groupByHashInsertPipeline,
            buffers: [
                (codesBuffer, 0),
                (htKeysBuffer, 1),
                (htGroupIdsBuffer, 2),
                (rowToGroupBuffer, 3),
                (paramsBuffer, 4),
            ],
            threadCount: n
        )

        // Read the actual number of groups assigned by the GPU.
        // This is stored at byte offset 8 in the params buffer (after n and capacity).
        let actualNumGroups = Int(paramsBuffer.contents()
            .advanced(by: 8) // skip n (4 bytes) + capacity (4 bytes)
            .assumingMemoryBound(to: UInt32.self).pointee)
        guard actualNumGroups > 0 else { return nil }

        // Step 3: Build the reverse mapping from factorized code to GPU group ID.
        // This is needed to map group keys back to the correct output row.
        let rowToGroupPtr = rowToGroupBuffer.contents().assumingMemoryBound(to: Int32.self)
        var codeToGroupId = [Int: Int]() // factorized code -> GPU group ID
        for i in 0..<n {
            let gid = Int(rowToGroupPtr[i])
            if gid >= 0 && codeToGroupId[codes[i]] == nil {
                codeToGroupId[codes[i]] = gid
            }
        }

        // Step 4: Per-column GPU reduction for all numeric columns
        let numericCols = dataFrame.columnNames.filter {
            !groupColumns.contains($0) && dataFrame.columns[$0]!.isNumeric
        }

        var resultColumns = [(String, Column)]()

        // Build the inverse mapping: GPU group ID -> factorized code
        var groupIdToCode = [Int: Int]()
        for (code, gid) in codeToGroupId {
            groupIdToCode[gid] = code
        }

        // Sort by group ID for stable, deterministic output order
        let sortedGroupIds = (0..<actualNumGroups).sorted()

        // Build firstRowForGroup in a single O(n) pass to find a representative
        // row for each group (used to extract group key values for non-string columns).
        var firstRowForGroup = [Int](repeating: -1, count: actualNumGroups)
        for i in 0..<n {
            let gid = Int(rowToGroupPtr[i])
            if gid >= 0 && gid < actualNumGroups && firstRowForGroup[gid] < 0 {
                firstRowForGroup[gid] = i
            }
        }

        // Add group key columns to the result.
        // For single string key columns, use the factorized key strings directly.
        // For other types and multi-column keys, use Column.take with representative row indices.
        if groupColumns.count == 1 {
            let col = dataFrame.columns[groupColumns[0]]!
            switch col {
            case .string:
                let keyStrings: [String] = sortedGroupIds.map { gid in
                    guard let code = groupIdToCode[gid], code >= 0, code < groupKeys.count else { return "NA" }
                    return groupKeys[code]
                }
                resultColumns.append((groupColumns[0], Column.fromStrings(keyStrings)))
            default:
                let firstIndices = sortedGroupIds.map { firstRowForGroup[$0] }
                resultColumns.append((groupColumns[0], col.take(indices: firstIndices)))
            }
        } else {
            let firstIndices = sortedGroupIds.map { firstRowForGroup[$0] }
            for groupCol in groupColumns {
                resultColumns.append((groupCol, dataFrame.columns[groupCol]!.take(indices: firstIndices)))
            }
        }

        // Dispatch GPU reduction for each numeric column
        for colName in numericCols {
            guard let colData = dataFrame.columns[colName]!.asDouble() else { continue }

            guard let result = reduceColumn(
                ctx: ctx,
                colData: colData,
                rowToGroupBuffer: rowToGroupBuffer,
                numGroups: actualNumGroups,
                n: n,
                op: op
            ) else { continue }

            // Reorder results to match the sorted group ID order
            let ordered = sortedGroupIds.map { result[$0] }
            resultColumns.append((colName, .fromDoubles(ordered)))
        }

        // Build the result DataFrame with an appropriate index
        let index: [String]
        if groupColumns.count == 1 {
            if case .string = dataFrame.columns[groupColumns[0]]! {
                let keyStrings: [String] = sortedGroupIds.map { gid in
                    guard let code = groupIdToCode[gid], code >= 0, code < groupKeys.count else { return "NA" }
                    return groupKeys[code]
                }
                index = keyStrings
            } else {
                index = sortedGroupIds.map { "\($0)" }
            }
        } else {
            index = (0..<actualNumGroups).map { "\($0)" }
        }

        return DataFrame(columns: resultColumns, index: index)
    }

    // MARK: - Column Reduction

    /// Perform GPU-accelerated reduction on a single numeric column.
    ///
    /// Converts the column's Double values to Float32 (required for Metal
    /// atomic_float), packs the validity bitmap as UInt32 pairs, initializes
    /// group accumulators, and dispatches the appropriate reduction kernel.
    ///
    /// - Parameters:
    ///   - ctx: The Metal context providing device, pipelines, and dispatch.
    ///   - colData: The column's nullable double data to reduce.
    ///   - rowToGroupBuffer: GPU buffer mapping each row to its group ID (from Phase 1).
    ///   - numGroups: Total number of distinct groups.
    ///   - n: Number of rows in the column.
    ///   - op: The aggregation operation to perform.
    /// - Returns: An array of `numGroups` Double values with the reduction result
    ///   for each group, or `nil` on GPU failure. Groups with no valid rows
    ///   contain `Double.nan`.
    private static func reduceColumn(
        ctx: MetalContext,
        colData: NullableArray<Double>,
        rowToGroupBuffer: MTLBuffer,
        numGroups: Int,
        n: Int,
        op: AggOp
    ) -> [Double]? {
        // Convert Double -> Float for GPU atomics (Metal only supports atomic_float, not atomic_double)
        var floatValues = [Float](repeating: 0, count: n)
        colData.data.withUnsafeBufferPointer { buf in
            for i in 0..<n { floatValues[i] = Float(buf[i]) }
        }

        // Pack validity bitmap as [UInt32] pairs.
        // The CPU-side BitVector stores UInt64 words; the GPU expects pairs of uint32
        // (low 32 bits first, then high 32 bits) to match the LSB-first bit ordering
        // used by the is_valid() MSL function.
        let validityWords: [UInt32] = colData.mask.words.flatMap { word -> [UInt32] in
            [UInt32(word & 0xFFFFFFFF), UInt32((word >> 32) & 0xFFFFFFFF)]
        }

        guard let valuesBuffer = ctx.makeBuffer(from: floatValues),
              let validityBuffer = ctx.makeBuffer(from: validityWords)
        else { return nil }

        // Initialize accumulators with identity values for each operation:
        // sum/mean/count start at 0; min starts at +infinity; max starts at -infinity.
        let accumInit: Float = {
            switch op {
            case .sum, .mean, .count: return 0.0
            case .min: return Float.greatestFiniteMagnitude
            case .max: return -Float.greatestFiniteMagnitude
            }
        }()

        let accum = [Float](repeating: accumInit, count: numGroups)
        let counts = [UInt32](repeating: 0, count: numGroups)

        guard let accumBuffer = ctx.makeBuffer(from: accum),
              let countsBuffer = ctx.makeBuffer(from: counts)
        else { return nil }

        var nVal = UInt32(n)
        guard let nBuffer = ctx.device.makeBuffer(
            bytes: &nVal, length: MemoryLayout<UInt32>.stride, options: .storageModeShared
        ) else { return nil }

        // Select the appropriate pipeline and buffer layout for the operation.
        // The count kernel has a simpler signature (no values buffer needed).
        let pipeline: MTLComputePipelineState
        let buffers: [(MTLBuffer, Int)]

        if op == .count {
            pipeline = ctx.groupByReduceCountPipeline
            buffers = [
                (validityBuffer, 0),
                (rowToGroupBuffer, 1),
                (countsBuffer, 2),
                (nBuffer, 3),
            ]
        } else {
            switch op {
            case .sum, .mean: pipeline = ctx.groupByReduceSumPipeline
            case .min: pipeline = ctx.groupByReduceMinPipeline
            case .max: pipeline = ctx.groupByReduceMaxPipeline
            case .count: fatalError()
            }
            buffers = [
                (valuesBuffer, 0),
                (validityBuffer, 1),
                (rowToGroupBuffer, 2),
                (accumBuffer, 3),
                (countsBuffer, 4),
                (nBuffer, 5),
            ]
        }

        ctx.dispatch(pipeline: pipeline, buffers: buffers, threadCount: n)

        // Read back GPU results from shared memory buffers
        let accumPtr = accumBuffer.contents().assumingMemoryBound(to: Float.self)
        let countsPtr = countsBuffer.contents().assumingMemoryBound(to: UInt32.self)

        // Convert Float32 accumulator results back to Double.
        // Groups with zero valid rows produce NaN.
        var result = [Double](repeating: .nan, count: numGroups)
        for g in 0..<numGroups {
            let c = countsPtr[g]
            if c == 0 { continue }
            switch op {
            case .sum: result[g] = Double(accumPtr[g])
            case .mean: result[g] = Double(accumPtr[g]) / Double(c)
            case .count: result[g] = Double(c)
            case .min, .max: result[g] = Double(accumPtr[g])
            }
        }

        return result
    }

    // MARK: - Factorization

    /// Factorize group columns into dense integer codes.
    ///
    /// Converts arbitrary column values to contiguous integer codes starting
    /// from 0, which can be used as keys in the GPU hash table. Null/NA
    /// values are assigned code -1 and excluded from grouping.
    ///
    /// For single-column GroupBy, delegates to the column type's native
    /// `factorize()` method. For multi-column GroupBy, builds composite
    /// keys by joining formatted column values with a tab separator.
    ///
    /// - Parameters:
    ///   - dataFrame: The source DataFrame containing the key columns.
    ///   - groupColumns: Names of the columns to group by.
    /// - Returns: A tuple of (per-row integer codes, ordered unique key strings).
    ///   The key strings are used for building the result DataFrame's index.
    private static func factorizeGroupColumns(
        dataFrame: DataFrame,
        by groupColumns: [String]
    ) -> (codes: [Int], groupKeys: [String]) {
        if groupColumns.count == 1 {
            // Single-column factorization: use the column's native factorize method
            let col = dataFrame.columns[groupColumns[0]]!
            switch col {
            case .string(let a):
                let (codes, uniques) = a.factorize()
                let keys = (0..<uniques.count).map { uniques[$0] ?? "NA" }
                return (codes, keys)
            case .double(let a):
                let (codes, uniques) = a.factorize()
                let keys = (0..<uniques.count).map { idx -> String in
                    let v = uniques[idx]
                    // Format integers without decimal point for cleaner display
                    if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
                        return String(format: "%.0f", v)
                    }
                    return String(v)
                }
                return (codes, keys)
            case .int64(let a):
                let (codes, uniques) = a.factorize()
                let keys = (0..<uniques.count).map { "\(uniques[$0])" }
                return (codes, keys)
            default:
                return ([], [])
            }
        } else {
            // Multi-column factorization: build composite keys by joining
            // formatted values from each group column with tab separators.
            // Rows with any NA value in the group columns are excluded (code -1).
            var compositeMap = [String: Int]()
            var codes = [Int]()
            var keys = [String]()
            codes.reserveCapacity(dataFrame.rowCount)

            for i in 0..<dataFrame.rowCount {
                var hasNA = false
                let keyParts = groupColumns.map { name -> String in
                    let val = dataFrame.columns[name]!.formattedValue(at: i)
                    if val == "NA" { hasNA = true }
                    return val
                }
                if hasNA {
                    codes.append(-1)
                    continue
                }
                let compositeKey = keyParts.joined(separator: "\t")
                if let existing = compositeMap[compositeKey] {
                    codes.append(existing)
                } else {
                    let code = keys.count
                    compositeMap[compositeKey] = code
                    keys.append(compositeKey)
                    codes.append(code)
                }
            }
            return (codes, keys)
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
