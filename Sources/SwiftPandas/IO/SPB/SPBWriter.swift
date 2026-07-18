// ===----------------------------------------------------------------------===//
//
// SPBWriter.swift
// SwiftPandas
//
// DataFrame -> SPB bytes. See SPBFormat.swift for the layout and the
// determinism contract. Column iteration is driven by `columnNames` — the
// ordered array, never the backing dictionary — which is the single
// map-iteration-order hazard this format must avoid.
//
// Fixed-width payloads use raw buffer copies (SwiftPandas supports
// little-endian hosts only; Apple Silicon, x86-64, and ARM Linux all
// qualify), with null slots pre-zeroed so equal frames always produce
// byte-identical files.
//
// ===----------------------------------------------------------------------===//

import Foundation

extension DataFrame {
    /// Serialize this frame to SPB bytes.
    public func toSPBData() -> Data {
        var out = Data()
        out.reserveCapacity(64 + estimatedBytes + estimatedBytes / 8)

        out.append(contentsOf: SPBFormat.magic)
        out.appendU32(SPBFormat.version)
        out.appendU32(UInt32(columnNames.count))
        out.appendU64(UInt64(rowCount))

        for name in columnNames {
            let col = columns[name]!
            let nameBytes = [UInt8](name.utf8)
            out.appendU32(UInt32(nameBytes.count))
            out.append(contentsOf: nameBytes)

            switch col {
            case .double(let a):
                out.append(SPBFormat.DTypeTag.double.rawValue)
                appendBitmap(&out, a.mask)
                if a.mask.allValid {
                    a.data.withUnsafeBufferPointer { out.append(contentsOf: Data(buffer: $0)) }
                } else {
                    // Null slots write as zero for byte-determinism.
                    var zeroed = ContiguousArray<Double>(repeating: 0, count: a.count)
                    a.data.withUnsafeBufferPointer { src in
                        for i in 0..<a.count where a.mask[i] { zeroed[i] = src[i] }
                    }
                    zeroed.withUnsafeBufferPointer { out.append(contentsOf: Data(buffer: $0)) }
                }

            case .int64(let a):
                out.append(SPBFormat.DTypeTag.int64.rawValue)
                appendBitmap(&out, a.mask)
                if a.mask.allValid {
                    a.data.withUnsafeBufferPointer { out.append(contentsOf: Data(buffer: $0)) }
                } else {
                    var zeroed = ContiguousArray<Int64>(repeating: 0, count: a.count)
                    a.data.withUnsafeBufferPointer { src in
                        for i in 0..<a.count where a.mask[i] { zeroed[i] = src[i] }
                    }
                    zeroed.withUnsafeBufferPointer { out.append(contentsOf: Data(buffer: $0)) }
                }

            case .bool(let a):
                out.append(SPBFormat.DTypeTag.bool.rawValue)
                appendBitmap(&out, a.mask)
                for i in 0..<a.count {
                    out.append(a.mask[i] && a.data[i] ? 1 : 0)
                }

            case .string(let a):
                out.append(SPBFormat.DTypeTag.string.rawValue)
                // StringArray has no bitmap; derive one from the optionals.
                appendBitmap(&out, BitVector(a.storage.map { $0 != nil }))
                for i in 0..<a.count {
                    if let value = a.storage[i] {
                        let bytes = [UInt8](value.utf8)
                        out.appendU32(UInt32(bytes.count))
                        out.append(contentsOf: bytes)
                    } else {
                        out.appendU32(0)
                    }
                }

            case .floatVector(let a):
                out.append(SPBFormat.DTypeTag.floatVector.rawValue)
                out.appendU32(UInt32(a.dims))
                appendBitmap(&out, a.validity)
                // Null rows are zero-filled by VectorArray's construction
                // invariant, so the plane streams verbatim.
                a.plane.withUnsafeBufferPointer { out.append(contentsOf: Data(buffer: $0)) }
            }
        }
        return out
    }

    /// Write this frame to an SPB file. Byte-deterministic: two writes of
    /// equal frames produce byte-identical files.
    public func writeSPB(to url: URL) throws {
        try toSPBData().write(to: url, options: .atomic)
    }

    /// Emit `ceil(rows/8)` bitmap bytes, LSB-first within each byte,
    /// trailing bits zero (guaranteed by BitVector's tail-bit invariant).
    private func appendBitmap(_ out: inout Data, _ bits: BitVector) {
        let byteCount = SPBFormat.bitmapByteCount(rows: bits.bitCount)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for k in 0..<byteCount {
            bytes[k] = UInt8(truncatingIfNeeded: bits.words[k / 8] >> ((k % 8) * 8))
        }
        out.append(contentsOf: bytes)
    }
}
