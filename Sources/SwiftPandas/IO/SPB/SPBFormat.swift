// ===----------------------------------------------------------------------===//
//
// SPBFormat.swift
// SwiftPandas
//
// The "SPB" (SwiftPandas Binary) format: shared layout constants and the
// bounds-checked read cursor. SPB is the durable, byte-deterministic format
// for frames (including vector columns, which CSV/JSON cannot carry).
//
// ## Layout (version 1, little-endian throughout)
//
//   offset  size        field
//   0       4           magic "SPB1"
//   4       4           UInt32 formatVersion = 1
//   8       4           UInt32 columnCount
//   12      8           UInt64 rowCount
//   ...     per column, in frame (columnNames) order:
//           4 + n         name: UInt32 byteLen + UTF-8
//           1             dtype tag (0=double, 1=string, 2=bool, 3=int64,
//                         4=floatVector)
//           4             UInt32 dims (floatVector only; absent otherwise)
//           ceil(rows/8)  validity bitmap (LSB-first within each byte,
//                         trailing bits of the final byte zero)
//           payload       double/int64: 8B native LE each (null cells zero);
//                         bool: 1B 0/1 (null cells 0);
//                         string: per-cell UInt32 byteLen + UTF-8 (null
//                         cells: len 0; the bitmap disambiguates null from
//                         empty);
//                         floatVector: rows*dims*4B Float32 LE plane (null
//                         rows zero-filled)
//
// ## Determinism (normative)
//
// Two writes of equal frames produce byte-identical files: fixed layout, no
// timestamps, column iteration driven by the ordered `columnNames` array
// (never the backing dictionary), and every null payload slot written as
// zero. The reader enforces the same canonical form (non-zero null slots are
// rejected as corrupt), so round-trips cannot silently produce files that
// differ from a fresh write.
//
// `formatVersion` exists so future sections (e.g. an ANN index sidecar) can
// be appended under version 2 while v1 readers keep failing loudly
// (`versionUnsupported`) rather than misparsing.
//
// ===----------------------------------------------------------------------===//

import Foundation

internal enum SPBFormat {
    static let magic: [UInt8] = [0x53, 0x50, 0x42, 0x31]  // "SPB1"
    static let version: UInt32 = 1

    enum DTypeTag: UInt8 {
        case double = 0
        case string = 1
        case bool = 2
        case int64 = 3
        case floatVector = 4
    }

    /// Number of bitmap bytes for a row count.
    static func bitmapByteCount(rows: Int) -> Int {
        (rows + 7) / 8
    }
}

/// Bounds-checked sequential reader over raw SPB bytes.
///
/// Every primitive read validates the remaining byte count and throws
/// ``VectorError/corrupt(reason:)`` on overrun, so the reader body is
/// straight-line layout code with no inline bounds arithmetic — truncated or
/// corrupt files cannot be mishandled at call sites, and no partial
/// ``DataFrame`` is ever constructed.
internal struct SPBCursor {
    private let bytes: [UInt8]
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var remaining: Int { bytes.count - offset }

    private mutating func require(_ count: Int, what: String) throws {
        guard count >= 0, remaining >= count else {
            throw VectorError.corrupt(
                reason: "truncated file: needed \(count) bytes for \(what) at offset \(offset), "
                    + "have \(remaining)")
        }
    }

    mutating func readBytes(_ count: Int, what: String) throws -> ArraySlice<UInt8> {
        try require(count, what: what)
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func readU8(_ what: String) throws -> UInt8 {
        try require(1, what: what)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readU32(_ what: String) throws -> UInt32 {
        try require(4, what: what)
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(bytes[offset + i]) << (8 * i) }
        offset += 4
        return value
    }

    mutating func readU64(_ what: String) throws -> UInt64 {
        try require(8, what: what)
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8
        return value
    }

    mutating func readString(byteLength: Int, what: String) throws -> String {
        let slice = try readBytes(byteLength, what: what)
        guard let string = String(bytes: slice, encoding: .utf8) else {
            throw VectorError.corrupt(reason: "invalid UTF-8 in \(what)")
        }
        return string
    }
}

/// Little-endian append helpers for the writer.
internal extension Data {
    mutating func appendU32(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendU64(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
