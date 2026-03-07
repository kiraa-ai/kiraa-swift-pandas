import Metal

/// GPU-accelerated Merge (hash join) engine.
internal enum MetalMerge {

    /// Perform GPU-accelerated inner join.
    /// Returns nil if GPU execution fails (caller falls back to CPU).
    static func innerJoin(
        left: DataFrame,
        right: DataFrame,
        on key: String
    ) -> DataFrame? {
        guard let ctx = MetalContext.shared else { return nil }
        guard left.rowCount > 0 && right.rowCount > 0 else { return nil }

        // Step 1: Co-factorize left and right key columns to shared code space
        guard let leftCol = left.columns[key],
              let rightCol = right.columns[key]
        else { return nil }

        let (leftCodes, rightCodes) = coFactorize(leftCol: leftCol, rightCol: rightCol)
        guard !leftCodes.isEmpty && !rightCodes.isEmpty else { return nil }

        let leftN = left.rowCount
        let rightN = right.rowCount

        let leftInt32 = leftCodes.map { Int32($0) }
        let rightInt32 = rightCodes.map { Int32($0) }

        // Step 2: GPU hash build from right table
        let htCapacity = nextPowerOfTwo(rightN * 2)

        guard let rightCodesBuffer = ctx.makeBuffer(from: rightInt32) else { return nil }

        // Hash table: pairs of (key, row_index) — each 8 bytes (two Int32)
        let entrySize = MemoryLayout<Int32>.stride * 2  // key + row_index
        guard let hashTableBuffer = ctx.makeBuffer(length: htCapacity * entrySize) else { return nil }
        // Initialize to -1
        memset(hashTableBuffer.contents(), 0xFF, hashTableBuffer.length)

        // Chain next array for duplicate right keys
        guard let chainNextBuffer = ctx.makeBuffer(length: rightN * MemoryLayout<Int32>.stride) else { return nil }
        memset(chainNextBuffer.contents(), 0xFF, chainNextBuffer.length)  // -1 = no next

        // MergeBuildParams: { n, capacity }
        var buildParams: (UInt32, UInt32) = (UInt32(rightN), UInt32(htCapacity))
        guard let buildParamsBuffer = ctx.device.makeBuffer(
            bytes: &buildParams,
            length: MemoryLayout<(UInt32, UInt32)>.stride,
            options: .storageModeShared
        ) else { return nil }

        // Dispatch hash build
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

        // Step 3: GPU hash probe from left table
        guard let leftCodesBuffer = ctx.makeBuffer(from: leftInt32) else { return nil }

        // Allocate output buffers — worst case is leftN * rightN matches
        // Start with a reasonable estimate; if overflow, fall back to CPU
        let maxOutput = min(leftN * rightN, leftN * 10 + rightN * 10 + 100_000)

        guard let outLeftBuffer = ctx.makeBuffer(length: maxOutput * MemoryLayout<Int32>.stride),
              let outRightBuffer = ctx.makeBuffer(length: maxOutput * MemoryLayout<Int32>.stride)
        else { return nil }

        // MergeProbeParams: { n, capacity, outCount (atomic), maxOutput }
        var probeParams: (UInt32, UInt32, UInt32, UInt32) = (
            UInt32(leftN), UInt32(htCapacity), 0, UInt32(maxOutput)
        )
        guard let probeParamsBuffer = ctx.device.makeBuffer(
            bytes: &probeParams,
            length: MemoryLayout<(UInt32, UInt32, UInt32, UInt32)>.stride,
            options: .storageModeShared
        ) else { return nil }

        // Dispatch hash probe
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

        // Read output count
        let outCount = Int(probeParamsBuffer.contents()
            .advanced(by: 8) // skip n + capacity
            .assumingMemoryBound(to: UInt32.self).pointee)

        // Check for overflow
        if outCount > maxOutput {
            // Too many matches; fall back to CPU
            return nil
        }

        guard outCount > 0 else {
            // No matches → empty DataFrame
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

        // Step 4: Read back indices and assemble result
        let outLeftPtr = outLeftBuffer.contents().assumingMemoryBound(to: Int32.self)
        let outRightPtr = outRightBuffer.contents().assumingMemoryBound(to: Int32.self)

        let leftIndices = (0..<outCount).map { Int(outLeftPtr[$0]) }
        let rightIndices = (0..<outCount).map { Int(outRightPtr[$0]) }

        // Build result DataFrame using Column.take
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

    /// Factorize left and right key columns into a shared code space.
    /// Both columns get the same integer code for the same value.
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
