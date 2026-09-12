// ===----------------------------------------------------------------------===//
//
// CSVWriterBytes.swift — byte-level fast path for CSVWriter
//
// The legacy writer (CSVReader.swift, `writeLegacy`) makes its per-cell
// "needs quoting?" decision with `String.contains`, which on a
// 6.7M-row × 43-column frame is ~287M Unicode-aware searches on one core —
// a sampled production build spent 100% of its stacks there.
//
// This path replaces the decision with a single UTF-8 byte scan for the
// separator, `"`, LF, and CR, formats numeric cells straight into a byte
// buffer (no intermediate String except for fractional doubles, which need
// Swift's shortest-representation algorithm), and formats row chunks
// concurrently for large frames.
//
// **Why the borrowed-view layer exists:** per-cell access through
// `Column`/`NullableArray` copies refcounted payloads (the CoW buffer
// class, the mask's word array), and each copy is an atomic retain/release
// on an object *shared by every worker thread*. Under the concurrent chunk
// loop those atomics ping-pong cache lines between cores and made the
// parallel path slower than the serial one. `withColumnViews` binds every
// column's contiguous storage exactly once (recursively, since the column
// count is dynamic), and the row loops then run on trivially-copyable
// `UnsafeBufferPointer`s — zero ARC traffic per cell.
//
// **Byte-identity contract:** for every frame and option set, output here
// is byte-identical to `writeLegacy` — with one deliberate exception:
// special bytes hiding inside a grapheme cluster (`"\r\n"`, or a
// separator/quote followed by a combining mark), which legacy fails to
// quote because `String.contains` is grapheme-based, producing malformed
// CSV. The byte scan quotes them correctly. `CSVWriterGoldenTests` pins
// both the parity corpus and this divergence.
//
// The fast path activates when the configured separator is a single UTF-8
// byte (",", "\t", ";", …). Multi-byte separators keep the legacy path.
//
// ===----------------------------------------------------------------------===//

import Foundation
#if canImport(Dispatch)
import Dispatch
#endif

extension CSVWriter {

    /// The separator as a single UTF-8 byte, or `nil` if the configured
    /// separator is empty or multi-byte (which routes to the legacy writer).
    /// A one-byte UTF-8 scalar is necessarily ASCII, so scanning raw bytes
    /// for it can never produce a false hit inside a multi-byte sequence.
    internal var fastSeparatorByte: UInt8? {
        let utf8 = separator.utf8
        guard utf8.count == 1 else { return nil }
        return utf8.first
    }

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
    /// byte-identity contract with ``writeLegacy(_:)``.
    internal func writeBytes(_ df: DataFrame, sepByte: UInt8) -> [UInt8] {
        let rowCount = df.rowCount
        let names = df.columnNames
        let quoteAll = (quoting == .all)

        guard rowCount > 0 else {
            // Legacy zero-row path: header only, no includeIndex prefix.
            guard includeHeader else { return [] }
            var out = [UInt8]()
            for (i, name) in names.enumerated() {
                if i > 0 { out.append(sepByte) }
                Self.appendStringField(name, sepByte: sepByte, quoteAll: quoteAll, into: &out)
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
        // it lands in a string column (legacy checks it there per cell).
        let naNeedsQuote = Self.needsQuote(naBytes, sepByte: sepByte)
        let indexLabels: [String] = includeIndex ? df.indexLabels : []

        var head = [UInt8]()
        if includeHeader {
            if includeIndex { head.append(sepByte) }
            for (i, name) in names.enumerated() {
                if i > 0 { head.append(sepByte) }
                Self.appendStringField(name, sepByte: sepByte, quoteAll: quoteAll, into: &head)
            }
            head.append(0x0A)
        }

        // Rough per-row byte estimate for reserveCapacity; growth is cheap
        // relative to formatting, so precision doesn't matter.
        func estimatedBytes(rows: Int) -> Int { rows * (cols.count * 9 + 8) }

        /// Formats rows `range` into `out` from the borrowed views. Pure
        /// per-row: no state crosses row boundaries, which is what makes
        /// chunked output byte-identical to sequential output.
        func formatRows(
            _ views: UnsafeBufferPointer<ColView>, _ range: Range<Int>, into out: inout [UInt8]
        ) {
            for i in range {
                if includeIndex {
                    Self.appendStringField(indexLabels[i], sepByte: sepByte,
                                           quoteAll: quoteAll, into: &out)
                    out.append(sepByte)
                }
                for (c, view) in views.enumerated() {
                    if c > 0 { out.append(sepByte) }
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
                            Self.appendStringField(v, sepByte: sepByte,
                                                   quoteAll: quoteAll, into: &out)
                        } else if quoteAll || naNeedsQuote {
                            // In a string column, legacy runs NA text through
                            // the same quoting check as real values.
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
    /// field. Byte-scan equivalent of the legacy `String.contains` checks.
    @inline(__always)
    internal static func needsQuote<C: Collection>(
        _ bytes: C, sepByte: UInt8
    ) -> Bool where C.Element == UInt8 {
        for b in bytes where b == sepByte || b == 0x22 || b == 0x0A || b == 0x0D {
            return true
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
    /// under this writer's quoting policy — the byte-level `escape()`.
    ///
    /// `withUTF8` guarantees a contiguous buffer for every string form —
    /// small strings (≤ 15 UTF-8 bytes, the common case in real data) spill
    /// to the stack rather than falling back to a per-byte iterator. The
    /// scratch copy is a struct copy, not a heap allocation.
    @inline(__always)
    internal static func appendStringField(
        _ s: String, sepByte: UInt8, quoteAll: Bool, into out: inout [UInt8]
    ) {
        var scratch = s
        scratch.withUTF8 { buf in
            if quoteAll || needsQuote(buf, sepByte: sepByte) {
                appendQuoted(buf, into: &out)
            } else {
                out.append(contentsOf: buf)
            }
        }
    }

    /// Emits NA in a numeric/bool column: legacy never quote-checks these,
    /// but QUOTE_ALL wraps them (doubling any quotes in the NA text).
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

    /// Mirrors the legacy `formatDouble` byte-for-byte: integral values with
    /// magnitude below 1e15 print as `Int64` (pandas-style `42`, not `42.0`);
    /// everything else — fractional, NaN, ±inf, huge — uses Swift's default
    /// shortest-representation `String(Double)`.
    @inline(__always)
    internal static func appendDouble(_ v: Double, into out: inout [UInt8]) {
        if v.truncatingRemainder(dividingBy: 1) == 0 && abs(v) < 1e15 {
            appendInt64(Int64(v), into: &out)
        } else {
            out.append(contentsOf: String(v).utf8)
        }
    }
}
