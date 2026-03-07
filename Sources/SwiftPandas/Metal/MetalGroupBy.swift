import Metal

/// GPU-accelerated GroupBy aggregation engine.
internal enum MetalGroupBy {

    /// Supported aggregation operations on GPU.
    enum AggOp {
        case sum, mean, count, min, max
    }

    /// Perform GPU-accelerated GroupBy aggregation.
    /// Returns nil if GPU execution fails (caller falls back to CPU).
    static func aggregate(
        dataFrame: DataFrame,
        by groupColumns: [String],
        op: AggOp
    ) -> DataFrame? {
        guard let ctx = MetalContext.shared else { return nil }
        let n = dataFrame.rowCount
        guard n > 0 else { return nil }

        // Step 1: Factorize group columns to integer codes
        let (codes, groupKeys) = factorizeGroupColumns(dataFrame: dataFrame, by: groupColumns)
        guard !codes.isEmpty else { return nil }
        let numDistinctCodes = groupKeys.count
        guard numDistinctCodes > 0 else { return nil }

        // Step 2: GPU hash insert → row_to_group mapping
        let int32Codes = codes.map { Int32($0) }
        let htCapacity = nextPowerOfTwo(numDistinctCodes * 2)

        guard let codesBuffer = ctx.makeBuffer(from: int32Codes) else { return nil }

        guard let htKeysBuffer = ctx.makeBuffer(length: htCapacity * MemoryLayout<Int32>.stride),
              let htGroupIdsBuffer = ctx.makeBuffer(length: htCapacity * MemoryLayout<Int32>.stride),
              let rowToGroupBuffer = ctx.makeBuffer(length: n * MemoryLayout<Int32>.stride)
        else { return nil }

        // Initialize hash table slots to -1 (EMPTY_SLOT)
        memset(htKeysBuffer.contents(), 0xFF, htKeysBuffer.length)
        memset(htGroupIdsBuffer.contents(), 0xFF, htGroupIdsBuffer.length)

        // GroupByParams: { n, capacity, nextGroupId }
        var paramsData: (UInt32, UInt32, UInt32) = (UInt32(n), UInt32(htCapacity), 0)
        guard let paramsBuffer = ctx.device.makeBuffer(
            bytes: &paramsData,
            length: MemoryLayout<(UInt32, UInt32, UInt32)>.stride,
            options: .storageModeShared
        ) else { return nil }

        // Dispatch hash insert kernel
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

        // Read actual group count
        let actualNumGroups = Int(paramsBuffer.contents()
            .advanced(by: 8) // skip n (4 bytes) + capacity (4 bytes)
            .assumingMemoryBound(to: UInt32.self).pointee)
        guard actualNumGroups > 0 else { return nil }

        // Step 3: Build group-key-to-groupId mapping
        // Read row_to_group to find which factorized code maps to which GPU group ID
        let rowToGroupPtr = rowToGroupBuffer.contents().assumingMemoryBound(to: Int32.self)
        var codeToGroupId = [Int: Int]() // factorize code → GPU group ID
        for i in 0..<n {
            let gid = Int(rowToGroupPtr[i])
            if gid >= 0 && codeToGroupId[codes[i]] == nil {
                codeToGroupId[codes[i]] = gid
            }
        }

        // Step 4: Per-column GPU reduction
        let numericCols = dataFrame.columnNames.filter {
            !groupColumns.contains($0) && dataFrame.columns[$0]!.isNumeric
        }

        var resultColumns = [(String, Column)]()

        // Build group key columns for result
        // We need to map GPU group IDs (0..<actualNumGroups) back to original keys
        var groupIdToCode = [Int: Int]()
        for (code, gid) in codeToGroupId {
            groupIdToCode[gid] = code
        }

        // Sort by group ID for stable output order
        let sortedGroupIds = (0..<actualNumGroups).sorted()

        // Add group key columns
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
                // For numeric group columns, take the first row of each group
                let firstIndices = sortedGroupIds.compactMap { gid -> Int? in
                    for i in 0..<n {
                        if Int(rowToGroupPtr[i]) == gid { return i }
                    }
                    return nil
                }
                resultColumns.append((groupColumns[0], col.take(indices: firstIndices)))
            }
        } else {
            // Multi-column: take first row of each group
            let firstIndices = sortedGroupIds.compactMap { gid -> Int? in
                for i in 0..<n {
                    if Int(rowToGroupPtr[i]) == gid { return i }
                }
                return nil
            }
            for groupCol in groupColumns {
                resultColumns.append((groupCol, dataFrame.columns[groupCol]!.take(indices: firstIndices)))
            }
        }

        // Reduce each numeric column
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

            // Reorder by sorted group IDs
            let ordered = sortedGroupIds.map { result[$0] }
            resultColumns.append((colName, .fromDoubles(ordered)))
        }

        // Build result DataFrame
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

    private static func reduceColumn(
        ctx: MetalContext,
        colData: NullableArray<Double>,
        rowToGroupBuffer: MTLBuffer,
        numGroups: Int,
        n: Int,
        op: AggOp
    ) -> [Double]? {
        // Convert Double → Float for GPU atomics
        var floatValues = [Float](repeating: 0, count: n)
        colData.data.withUnsafeBufferPointer { buf in
            for i in 0..<n { floatValues[i] = Float(buf[i]) }
        }

        // Pack validity bitmap as [UInt32] pairs (from [UInt64] words)
        let validityWords: [UInt32] = colData.mask.words.flatMap { word -> [UInt32] in
            [UInt32(word & 0xFFFFFFFF), UInt32((word >> 32) & 0xFFFFFFFF)]
        }

        guard let valuesBuffer = ctx.makeBuffer(from: floatValues),
              let validityBuffer = ctx.makeBuffer(from: validityWords)
        else { return nil }

        // Initialize accumulators
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

        // Select pipeline and dispatch
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

        // Read results
        let accumPtr = accumBuffer.contents().assumingMemoryBound(to: Float.self)
        let countsPtr = countsBuffer.contents().assumingMemoryBound(to: UInt32.self)

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

    /// Factorize group columns into integer codes.
    /// Returns (codes per row, ordered unique key strings for index).
    private static func factorizeGroupColumns(
        dataFrame: DataFrame,
        by groupColumns: [String]
    ) -> (codes: [Int], groupKeys: [String]) {
        if groupColumns.count == 1 {
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
            // Multi-column: build composite codes
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
