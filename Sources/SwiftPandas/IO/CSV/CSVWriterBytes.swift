// ===----------------------------------------------------------------------===//
//
// CSVWriterBytes.swift — CSVWriter serialization
//
// The writer works at the UTF-8 byte level throughout:
//
//   * Quoting decisions are a single byte scan per field for the
//     separator, `"`, LF, and CR — RFC 4180 semantics. Scanning bytes
//     (not grapheme clusters) also quotes fields whose special characters
//     hide inside a cluster, e.g. `"\r\n"` or a separator followed by a
//     combining mark, which String-based `contains` misses.
//   * Numeric cells format directly into the output buffer; only
//     fractional doubles allocate (Swift's shortest-representation
//     `String(Double)`).
//   * Column storage is read through borrowed buffer pointers
//     (`withColumnViews`). Per-cell access through `Column`/`NullableArray`
//     would copy refcounted payloads, and under the concurrent row loop
//     those atomic retain/releases on shared objects ping-pong cache lines
//     between cores — measured 38× slower than the borrowed form.
//   * Frames past 2^16 rows format disjoint row chunks concurrently and
//     concatenate in order. Formatting is pure per-row, so chunked output
//     is identical to sequential output by construction.
//
// Separators of any UTF-8 length are supported; the common single-byte
// case (",", "\t", ";") takes the tighter scan.
//
// `CSVWriterTests` pins the output contract: quoting matrix, numeric
// formatting, NA handling, header/index options, chunked-vs-sequential
// equality, and reader round-trips.
//
// ===----------------------------------------------------------------------===//

import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

extension CSVWriter {

    /// Borrowed, ARC-free view of one column's storage. Only valid inside
    /// the `withColumnViews` scope that produced it. A `nil` mask means
    /// every row is valid (the column's `allValid` fast path).
    private enum ColView {
        case doubles(UnsafeBufferPointer<Double>, mask: UnsafeBufferPointer<UInt64>?)
        case int64s(UnsafeBufferPointer<Int64>, mask: UnsafeBufferPointer<UInt64>?)
        case bools(UnsafeBufferPointer<Bool>, mask: UnsafeBufferPointer<UInt64>?)
        case strings(UnsafeBufferPointer<String?>)
    }

    /// Recursively binds each column's contiguous storage, then hands the
    /// complete view table to `body`. Recursion is the only way to nest a
    /// dynamic number of `withUnsafeBufferPointer` scopes; depth equals the
    /// column count.
    private static func withColumnViews<R>(
        _ cols: [Column], _ index: Int, _ views: inout [ColView],
        _ body: (UnsafeBufferPointer<ColView>) -> R
    ) -> R {
        guard index < cols.count else {
            return views.withUnsafeBufferPointer(body)
        }
        switch cols[index] {
        case .double(let arr):
            return arr.data.withUnsafeBufferPointer { data in
                if arr.mask.allValid {
                    views.append(.doubles(data, mask: nil))
                    defer { views.removeLast() }
                    return withColumnViews(cols, index + 1, &views, body)
                }
                return arr.mask.words.withUnsafeBufferPointer { w in
                    views.append(.doubles(data, mask: w))
                    defer { views.removeLast() }
                    return withColumnViews(cols, index + 1, &views, body)
                }
            }
        case .int64(let arr):
            return arr.data.withUnsafeBufferPointer { data in
                if arr.mask.allValid {
                    views.append(.int64s(data, mask: nil))
                    defer { views.removeLast() }
                    return withColumnViews(cols, index + 1, &views, body)
                }
                return arr.mask.words.withUnsafeBufferPointer { w in
                    views.append(.int64s(data, mask: w))
                    defer { views.removeLast() }
                    return withColumnViews(cols, index + 1, &views, body)
                }
            }
        case .bool(let arr):
            return arr.data.withUnsafeBufferPointer { data in
                if arr.mask.allValid {
                    views.append(.bools(data, mask: nil))
                    defer { views.removeLast() }
                    return withColumnViews(cols, index + 1, &views, body)
                }
                return arr.mask.words.withUnsafeBufferPointer { w in
                    views.append(.bools(data, mask: w))
                    defer { views.removeLast() }
                    return withColumnViews(cols, index + 1, &views, body)
                }
            }
        case .string(let arr):
            return arr.storage.withUnsafeBufferPointer { s in
                views.append(.strings(s))
                defer { views.removeLast() }
                return withColumnViews(cols, index + 1, &views, body)
            }
        case .floatVector:
            preconditionFailure("unreachable: rejected before view construction")
        }
    }

    /// LSB-first validity check against the borrowed mask words —
    /// bit-identical to `BitVector`'s subscript.
    @inline(__always)
    private static func isValid(_ mask: UnsafeBufferPointer<UInt64>?, _ i: Int) -> Bool {
        guard let m = mask else { return true }
        return (m[i >> 6] >> UInt64(i & 63)) & 1 == 1
    }

    /// Serializes the frame to UTF-8 bytes. See the file header for the
    /// output contract.
    internal func writeBytes(_ df: DataFrame) -> [UInt8] {
        let sep = Array(separator.utf8)
        let rowCount = df.rowCount
        let names = df.columnNames
        let quoteAll = (quoting == .all)

        @inline(__always)
        func appendSep(_ out: inout [UInt8]) {
            if sep.count == 1 { out.append(sep[0]) } else { out.append(contentsOf: sep) }
        }

        guard rowCount > 0 else {
            // Zero-row frame: header only, no includeIndex prefix.
            guard includeHeader else { return [] }
            var out = [UInt8]()
            for (i, name) in names.enumerated() {
                if i > 0 { appendSep(&out) }
                Self.appendStringField(name, sep: sep, quoteAll: quoteAll, into: &out)
            }
            out.append(0x0A)
            return out
        }

        let cols: [Column] = names.map { df.columns[$0]! }
        for col in cols {
            if case .floatVector(let arr) = col {
                preconditionFailure(
                    "CSV serialization is unsupported for floatVector(\(arr.dims)) columns; "
                    + "drop/select the other columns or use writeSPB")
            }
        }

        let naBytes = Array(naRepresentation.utf8)
        // Constant per writer: whether the NA text itself needs quoting when
        // it lands in a string column (numeric columns emit it unquoted).
        let naNeedsQuote = Self.needsQuote(naBytes, sep: sep)
        let indexLabels: [String] = includeIndex ? df.indexLabels : []

        var head = [UInt8]()
        if includeHeader {
            if includeIndex { appendSep(&head) }
            for (i, name) in names.enumerated() {
                if i > 0 { appendSep(&head) }
                Self.appendStringField(name, sep: sep, quoteAll: quoteAll, into: &head)
            }
            head.append(0x0A)
        }

        // Rough per-row byte estimate for reserveCapacity; growth is cheap
        // relative to formatting, so precision doesn't matter.
        func estimatedBytes(rows: Int) -> Int { rows * (cols.count * 9 + 8) }

        /// Formats rows `range` into `out` from the borrowed views. Pure
        /// per-row: no state crosses row boundaries, which is what makes
        /// chunked output identical to sequential output.
        func formatRows(
            _ views: UnsafeBufferPointer<ColView>, _ range: Range<Int>, into out: inout [UInt8]
        ) {
            for i in range {
                if includeIndex {
                    Self.appendStringField(indexLabels[i], sep: sep,
                                           quoteAll: quoteAll, into: &out)
                    appendSep(&out)
                }
                for (c, view) in views.enumerated() {
                    if c > 0 { appendSep(&out) }
                    switch view {
                    case .doubles(let data, let mask):
                        if Self.isValid(mask, i) {
                            if quoteAll {
                                out.append(0x22)
                                Self.appendDouble(data[i], into: &out)
                                out.append(0x22)
                            } else {
                                Self.appendDouble(data[i], into: &out)
                            }
                        } else {
                            Self.appendNA(naBytes, quoteAll: quoteAll, into: &out)
                        }
                    case .int64s(let data, let mask):
                        if Self.isValid(mask, i) {
                            if quoteAll {
                                out.append(0x22)
                                Self.appendInt64(data[i], into: &out)
                                out.append(0x22)
                            } else {
                                Self.appendInt64(data[i], into: &out)
                            }
                        } else {
                            Self.appendNA(naBytes, quoteAll: quoteAll, into: &out)
                        }
                    case .bools(let data, let mask):
                        if Self.isValid(mask, i) {
                            if quoteAll { out.append(0x22) }
                            out.append(contentsOf: data[i] ? Self.trueBytes : Self.falseBytes)
                            if quoteAll { out.append(0x22) }
                        } else {
                            Self.appendNA(naBytes, quoteAll: quoteAll, into: &out)
                        }
                    case .strings(let storage):
                        if let v = storage[i] {
                            Self.appendStringField(v, sep: sep,
                                                   quoteAll: quoteAll, into: &out)
                        } else if quoteAll || naNeedsQuote {
                            // In a string column, NA text goes through the
                            // same quoting check as real values.
                            Self.appendQuoted(naBytes, into: &out)
                        } else {
                            out.append(contentsOf: naBytes)
                        }
                    }
                }
                out.append(0x0A)
            }
        }

        var out = head
        var viewScratch = [ColView]()
        viewScratch.reserveCapacity(cols.count)
        Self.withColumnViews(cols, 0, &viewScratch) { views in
            let parallelThreshold = 1 << 16
            let cores = ProcessInfo.processInfo.activeProcessorCount
            if rowCount >= parallelThreshold && cores > 1 {
                // Format disjoint row chunks concurrently, then concatenate
                // in order. Each iteration touches only its own slot.
                let chunkCount = min(cores, (rowCount + 32_767) / 32_768)
                let rowsPerChunk = (rowCount + chunkCount - 1) / chunkCount
                var chunks = [[UInt8]](repeating: [], count: chunkCount)
                chunks.withUnsafeMutableBufferPointer { slots in
                    DispatchQueue.concurrentPerform(iterations: chunkCount) { k in
                        let lo = k * rowsPerChunk
                        let hi = Swift.min(lo + rowsPerChunk, rowCount)
                        guard lo < hi else { return }
                        var local = [UInt8]()
                        local.reserveCapacity(estimatedBytes(rows: hi - lo))
                        formatRows(views, lo..<hi, into: &local)
                        slots[k] = local
                    }
                }
                out.reserveCapacity(out.count + chunks.reduce(0) { $0 + $1.count })
                for chunk in chunks { out.append(contentsOf: chunk) }
            } else {
                out.reserveCapacity(out.count + estimatedBytes(rows: rowCount))
                formatRows(views, 0..<rowCount, into: &out)
            }
        }
        return out
    }

    // MARK: - Field emitters

    private static let trueBytes: [UInt8] = Array("True".utf8)
    private static let falseBytes: [UInt8] = Array("False".utf8)

    /// RFC 4180 quoting trigger: separator, `"`, LF, or CR anywhere in the
    /// field. Single-byte separators (the common case) scan in one pass;
    /// longer separators add a byte-subsequence match, which is exact on
    /// UTF-8 because the encoding is self-synchronizing.
    @inline(__always)
    internal static func needsQuote<C: Collection>(
        _ bytes: C, sep: [UInt8]
    ) -> Bool where C.Element == UInt8 {
        if sep.count == 1 {
            let s = sep[0]
            for b in bytes where b == s || b == 0x22 || b == 0x0A || b == 0x0D {
                return true
            }
            return false
        }
        for b in bytes where b == 0x22 || b == 0x0A || b == 0x0D {
            return true
        }
        guard !sep.isEmpty else { return false }
        let arr = Array(bytes)
        guard arr.count >= sep.count else { return false }
        for start in 0...(arr.count - sep.count) {
            if arr[start] == sep[0] {
                var match = true
                for j in 1..<sep.count where arr[start + j] != sep[j] {
                    match = false
                    break
                }
                if match { return true }
            }
        }
        return false
    }

    /// Emits `"` + field with internal quotes doubled + `"`.
    @inline(__always)
    internal static func appendQuoted<C: Collection>(
        _ bytes: C, into out: inout [UInt8]
    ) where C.Element == UInt8 {
        out.append(0x22)
        for b in bytes {
            if b == 0x22 { out.append(0x22) }
            out.append(b)
        }
        out.append(0x22)
    }

    /// Emits one string-typed field (value, header name, or index label)
    /// under this writer's quoting policy.
    ///
    /// `withUTF8` guarantees a contiguous buffer for every string form —
    /// small strings (≤ 15 UTF-8 bytes, the common case in real data) spill
    /// to the stack rather than falling back to a per-byte iterator. The
    /// scratch copy is a struct copy, not a heap allocation.
    @inline(__always)
    internal static func appendStringField(
        _ s: String, sep: [UInt8], quoteAll: Bool, into out: inout [UInt8]
    ) {
        var scratch = s
        scratch.withUTF8 { buf in
            if quoteAll || needsQuote(buf, sep: sep) {
                appendQuoted(buf, into: &out)
            } else {
                out.append(contentsOf: buf)
            }
        }
    }

    /// Emits NA in a numeric/bool column: never quote-checked there, but
    /// QUOTE_ALL wraps it (doubling any quotes in the NA text).
    @inline(__always)
    private static func appendNA(_ naBytes: [UInt8], quoteAll: Bool, into out: inout [UInt8]) {
        if quoteAll {
            appendQuoted(naBytes, into: &out)
        } else {
            out.append(contentsOf: naBytes)
        }
    }

    /// Decimal formatting identical to `String(Int64)` — including
    /// `Int64.min`, which `magnitude` handles without overflow.
    @inline(__always)
    internal static func appendInt64(_ v: Int64, into out: inout [UInt8]) {
        if v == 0 {
            out.append(0x30)
            return
        }
        var magnitude = v.magnitude
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { tmp in
            var idx = 20
            while magnitude > 0 {
                idx -= 1
                tmp[idx] = 0x30 &+ UInt8(magnitude % 10)
                magnitude /= 10
            }
            if v < 0 { out.append(0x2D) }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: tmp[idx...]))
        }
    }

    /// Integral values with magnitude below 1e15 print as `Int64`
    /// (pandas-style `42`, not `42.0`); everything else — fractional, NaN,
    /// ±inf, huge — uses Swift's default shortest-representation
    /// `String(Double)`.
    @inline(__always)
    internal static func appendDouble(_ v: Double, into out: inout [UInt8]) {
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
            appendInt64(Int64(v), into: &out)
        } else {
            out.append(contentsOf: String(v).utf8)
        }
    }
}
