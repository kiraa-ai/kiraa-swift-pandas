import XCTest
@testable import SwiftPandas

/// A4 acceptance: SPB round-trip losslessness (all 5 dtypes x null patterns),
/// double-write byte-identity, and loud rejection of corrupt/truncated/
/// future-version files.
final class SPBTests: XCTestCase {

    private func allDtypesFrame() throws -> DataFrame {
        DataFrame(columns: [
            ("d", .fromOptionalDoubles([1.5, nil, -3.25, 0])),
            ("s", .fromOptionalStrings(["hello", nil, "", "utf8 ✓ 日本語"])),
            ("b", .fromOptionalBools([true, false, nil, true])),
            ("i", .fromOptionalInts([Int.max, nil, -7, 0])),
            ("v", try .fromOptionalVectors([[1, 2, 3], nil, [0, 0, 0], [-1.5, 2.5, 3.5]], dims: 3)),
        ])
    }

    // MARK: - Round trip

    func test_roundTrip_allDtypes_withNulls() throws {
        let df = try allDtypesFrame()
        let restored = try DataFrame.readSPB(from: df.toSPBData())

        XCTAssertEqual(restored.columnNames, df.columnNames)
        XCTAssertEqual(restored.rowCount, df.rowCount)
        for name in df.columnNames {
            XCTAssertEqual(restored.columns[name]!, df.columns[name]!, "column '\(name)'")
        }
    }

    func test_roundTrip_emptyStringVsNullString() throws {
        let df = DataFrame(columns: [("s", .fromOptionalStrings(["", nil]))])
        let restored = try DataFrame.readSPB(from: df.toSPBData())
        guard case .string(let a) = restored.columns["s"]! else {
            return XCTFail("expected string column")
        }
        XCTAssertEqual(a[0], "")   // valid empty string survives
        XCTAssertNil(a[1])          // null stays null — the bitmap disambiguates
    }

    func test_roundTrip_emptyFrameAndZeroRows() throws {
        let empty = DataFrame()
        XCTAssertEqual(try DataFrame.readSPB(from: empty.toSPBData()).rowCount, 0)

        let zeroRows = DataFrame(columns: [("d", .fromDoubles([]))])
        let restored = try DataFrame.readSPB(from: zeroRows.toSPBData())
        XCTAssertEqual(restored.columnNames, ["d"])
        XCTAssertEqual(restored.rowCount, 0)
    }

    func test_roundTrip_fileURL() throws {
        let df = try allDtypesFrame()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spb_test_\(UUID().uuidString).spb")
        defer { try? FileManager.default.removeItem(at: url) }
        try df.writeSPB(to: url)
        let restored = try DataFrame.readSPB(from: url)
        XCTAssertEqual(restored.columns["v"]!, df.columns["v"]!)
    }

    // MARK: - Byte determinism

    func test_doubleWrite_isByteIdentical() throws {
        let df = try allDtypesFrame()
        XCTAssertEqual(df.toSPBData(), df.toSPBData())
        // Equal-but-independently-built frames also produce identical bytes.
        let rebuilt = try allDtypesFrame()
        XCTAssertEqual(df.toSPBData(), rebuilt.toSPBData())
    }

    func test_roundTrip_isByteStable() throws {
        // write -> read -> write produces the same bytes (canonical form).
        let df = try allDtypesFrame()
        let first = df.toSPBData()
        let second = try DataFrame.readSPB(from: first).toSPBData()
        XCTAssertEqual(first, second)
    }

    // MARK: - Corruption / version rejection

    private func expectCorrupt(_ data: Data, _ label: String) {
        XCTAssertThrowsError(try DataFrame.readSPB(from: data), label) { error in
            guard case VectorError.corrupt(let reason) = error else {
                return XCTFail("\(label): expected .corrupt, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func test_badMagic_throws() throws {
        var data = try allDtypesFrame().toSPBData()
        data[0] = 0x58
        expectCorrupt(data, "bad magic")
    }

    func test_futureVersion_throwsVersionUnsupported() throws {
        var data = try allDtypesFrame().toSPBData()
        data[4] = 2  // formatVersion LE low byte
        XCTAssertThrowsError(try DataFrame.readSPB(from: data)) { error in
            guard case VectorError.versionUnsupported(let found, let supported) = error else {
                return XCTFail("expected versionUnsupported, got \(error)")
            }
            XCTAssertEqual(found, 2)
            XCTAssertEqual(supported, 1)
        }
    }

    func test_truncatedFile_throwsWithReason() throws {
        let data = try allDtypesFrame().toSPBData()
        expectCorrupt(data.prefix(data.count / 2), "truncated payload")
        expectCorrupt(data.prefix(10), "truncated header")
        expectCorrupt(Data(), "empty file")
    }

    func test_trailingGarbage_throws() throws {
        var data = try allDtypesFrame().toSPBData()
        data.append(contentsOf: [0xDE, 0xAD])
        expectCorrupt(data, "trailing bytes")
    }

    func test_unknownDtypeTag_throws() throws {
        let df = DataFrame(columns: [("d", .fromDoubles([1]))])
        var data = df.toSPBData()
        // Header is 20 bytes; name is len(4)+1; tag follows.
        let tagOffset = 20 + 4 + 1
        data[tagOffset] = 99
        expectCorrupt(data, "unknown dtype tag")
    }

    func test_oversizedStringLength_throws() throws {
        let df = DataFrame(columns: [("s", .fromStrings(["ab"]))])
        var data = df.toSPBData()
        // Last 6 bytes are the cell: UInt32 len ("ab" = 2) + 2 bytes UTF-8.
        data[data.count - 6] = 0xFF  // now claims a huge length
        expectCorrupt(data, "oversized string length")
    }

    func test_nonZeroNullSlot_throws() throws {
        let df = DataFrame(columns: [("d", .fromOptionalDoubles([nil, 2.0]))])
        var data = df.toSPBData()
        // Payload starts after header(20) + name(4+1) + tag(1) + bitmap(1).
        let payloadOffset = 20 + 5 + 1 + 1
        data[payloadOffset] = 1  // dirty the null slot
        expectCorrupt(data, "non-zero null payload slot")
    }

    func test_nonZeroBitmapTailBit_throws() throws {
        let df = DataFrame(columns: [("d", .fromDoubles([1.0]))])
        var data = df.toSPBData()
        let bitmapOffset = 20 + 5 + 1
        data[bitmapOffset] = 0xFF  // rows=1 but 8 bits set
        expectCorrupt(data, "bitmap tail bits")
    }

    func test_vectorDimsZero_throws() throws {
        let df = DataFrame(columns: [("v", try .fromVectors([[1]], dims: 1))])
        var data = df.toSPBData()
        let dimsOffset = 20 + 5 + 1  // dims UInt32 follows the tag
        data[dimsOffset] = 0
        expectCorrupt(data, "dims = 0")
    }
}
