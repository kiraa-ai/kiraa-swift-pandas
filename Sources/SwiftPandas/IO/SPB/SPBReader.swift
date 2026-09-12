// ===----------------------------------------------------------------------===//
//
// SPBReader.swift
// SwiftPandas
//
// SPB bytes -> DataFrame. Every read goes through the bounds-checked
// SPBCursor; every failure throws before a DataFrame is constructed, so there
// are no partial loads. The reader also enforces the writer's canonical form
// (null payload slots must be zero, bitmap tail bits must be zero, string
// null cells must have length 0), so a successful read implies the file is
// exactly what a fresh write would produce.
//
// ===----------------------------------------------------------------------===//

import Foundation

extension DataFrame {
    /// Read a DataFrame from SPB bytes.
    ///
    /// - Throws: ``VectorError/corrupt(reason:)`` for any validation failure
    ///   (with a human-readable reason);
    ///   ``VectorError/versionUnsupported(found:supported:)`` for files newer
    ///   than format version 1. No partial loads.
    public static func readSPB(from data: Data) throws -> DataFrame {
        // Parse in place over the buffer (the memory map for file loads): no
        // whole-file copy, and the mapping stays valid for the closure's life.
        try data.withUnsafeBytes { rawBuffer in
            try parseSPB(rawBuffer)
        }
    }

    private static func parseSPB(_ buffer: UnsafeRawBufferPointer) throws -> DataFrame {
        var cursor = SPBCursor(buffer)

        let magic = try cursor.readBytes(4, what: "magic")
        guard magic.elementsEqual(SPBFormat.magic) else {
            throw VectorError.corrupt(reason: "bad magic (expected \"SPB1\")")
        }
        let version = try cursor.readU32("formatVersion")
        guard version <= SPBFormat.version else {
            throw VectorError.versionUnsupported(found: version, supported: SPBFormat.version)
        }
        guard version == SPBFormat.version else {
            throw VectorError.corrupt(reason: "invalid formatVersion \(version)")
        }
        let columnCount = Int(try cursor.readU32("columnCount"))
        let rowCount64 = try cursor.readU64("rowCount")
        guard rowCount64 <= UInt64(Int.max) else {
            throw VectorError.corrupt(reason: "rowCount \(rowCount64) exceeds Int.max")
        }
        let rows = Int(rowCount64)

        var resultColumns = [(String, Column)]()
        resultColumns.reserveCapacity(columnCount)
        var seenNames = Set<String>()

        for columnIndex in 0..<columnCount {
            let nameLength = Int(try cursor.readU32("column \(columnIndex) name length"))
            let name = try cursor.readString(byteLength: nameLength, what: "column \(columnIndex) name")
            guard seenNames.insert(name).inserted else {
                throw VectorError.corrupt(reason: "duplicate column name '\(name)'")
            }
            let tagByte = try cursor.readU8("column '\(name)' dtype tag")
            guard let tag = SPBFormat.DTypeTag(rawValue: tagByte) else {
                throw VectorError.corrupt(reason: "unknown dtype tag \(tagByte) for column '\(name)'")
            }

            var dims = 0
            if tag == .floatVector {
                dims = Int(try cursor.readU32("column '\(name)' dims"))
                guard dims >= 1 else {
                    throw VectorError.corrupt(reason: "column '\(name)' has dims \(dims) (must be >= 1)")
                }
            }

            let validity = try readBitmap(&cursor, rows: rows, column: name)
            let column: Column
            switch tag {
            case .double:
                let values: [Double] = try readFixedWidth(
                    &cursor, rows: rows, column: name, as: Double.self)
                try requireZeroNullSlots(values, validity, column: name) { $0 == 0 }
                column = .double(NullableArray(
                    data: NativeArray(values), mask: validity))
            case .int64:
                let values: [Int64] = try readFixedWidth(
                    &cursor, rows: rows, column: name, as: Int64.self)
                try requireZeroNullSlots(values, validity, column: name) { $0 == 0 }
                column = .int64(NullableArray(data: NativeArray(values), mask: validity))
            case .bool:
                let bytes = try cursor.readBytes(rows, what: "column '\(name)' bool payload")
                var values = ContiguousArray<Bool>(repeating: false, count: rows)
                for (i, byte) in bytes.enumerated() {
                    switch byte {
                    case 0: break
                    case 1:
                        guard validity[i] else {
                            throw VectorError.corrupt(
                                reason: "column '\(name)' row \(i): null bool cell with non-zero payload")
                        }
                        values[i] = true
                    default:
                        throw VectorError.corrupt(
                            reason: "column '\(name)' row \(i): invalid bool byte \(byte)")
                    }
                }
                column = .bool(NullableArray(data: NativeArray(values), mask: validity))
            case .string:
                var values = [String?](repeating: nil, count: rows)
                for i in 0..<rows {
                    let length = Int(try cursor.readU32("column '\(name)' row \(i) string length"))
                    if validity[i] {
                        values[i] = try cursor.readString(
                            byteLength: length, what: "column '\(name)' row \(i) string")
                    } else {
                        guard length == 0 else {
                            throw VectorError.corrupt(
                                reason: "column '\(name)' row \(i): null string cell with length \(length)")
                        }
                    }
                }
                column = .string(StringArray(values))
            case .floatVector:
                let planeCount: Int
                let (rowsTimesDims, overflow1) = rows.multipliedReportingOverflow(by: dims)
                guard !overflow1 else {
                    throw VectorError.corrupt(reason: "column '\(name)': rows*dims overflows")
                }
                planeCount = rowsTimesDims
                let plane: [Float] = try readFixedWidthCount(
                    &cursor, count: planeCount, column: name, as: Float.self)
                // Canonical form: null rows must be zero-filled.
                for row in 0..<rows where !validity[row] {
                    for k in 0..<dims where plane[row * dims + k] != 0 {
                        throw VectorError.corrupt(
                            reason: "column '\(name)' row \(row): null vector row has non-zero plane data")
                    }
                }
                column = .floatVector(VectorArray(
                    plane: NativeArray(ContiguousArray(plane)), validity: validity, dims: dims))
            }
            resultColumns.append((name, column))
        }

        guard cursor.remaining == 0 else {
            throw VectorError.corrupt(
                reason: "\(cursor.remaining) trailing bytes after last column")
        }
        return DataFrame(columns: resultColumns)
    }

    /// Read a DataFrame from an SPB file.
    public static func readSPB(from url: URL) throws -> DataFrame {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try readSPB(from: data)
    }

    // MARK: - Helpers

    private static func readBitmap(
        _ cursor: inout SPBCursor, rows: Int, column: String
    ) throws -> BitVector {
        let byteCount = SPBFormat.bitmapByteCount(rows: rows)
        let bytes = try cursor.readBytes(byteCount, what: "column '\(column)' validity bitmap")
        var bools = [Bool](repeating: false, count: rows)
        for (k, byte) in bytes.enumerated() {
            let base = k * 8
            for bit in 0..<8 {
                let index = base + bit
                let isSet = (byte >> bit) & 1 == 1
                if index < rows {
                    bools[index] = isSet
                } else if isSet {
                    throw VectorError.corrupt(
                        reason: "column '\(column)': non-zero bitmap tail bit \(index)")
                }
            }
        }
        return BitVector(bools)
    }

    private static func readFixedWidth<T>(
        _ cursor: inout SPBCursor, rows: Int, column: String, as type: T.Type
    ) throws -> [T] {
        try readFixedWidthCount(&cursor, count: rows, column: column, as: type)
    }

    private static func readFixedWidthCount<T>(
        _ cursor: inout SPBCursor, count: Int, column: String, as type: T.Type
    ) throws -> [T] {
        let stride = MemoryLayout<T>.stride
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow else {
            throw VectorError.corrupt(reason: "column '\(column)': payload size overflows")
        }
        let raw = try cursor.readBytes(byteCount, what: "column '\(column)' payload")
        // Little-endian hosts only (see SPBWriter header). copyMemory rather
        // than bindMemory: the payload offset is unaligned whenever it
        // follows variable-length string cells.
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            UnsafeMutableRawBufferPointer(buffer).copyMemory(from: raw)
            initialized = count
        }
    }

    private static func requireZeroNullSlots<T>(
        _ values: [T], _ validity: BitVector, column: String, isZero: (T) -> Bool
    ) throws {
        guard !validity.allValid else { return }
        for i in 0..<values.count where !validity[i] && !isZero(values[i]) {
            throw VectorError.corrupt(
                reason: "column '\(column)' row \(i): null cell has non-zero payload")
        }
    }
}
