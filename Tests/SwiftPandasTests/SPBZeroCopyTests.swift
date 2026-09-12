import XCTest
@testable import SwiftPandas

/// B4 acceptance: the zero-copy reader (parsing directly over the buffer with
/// `loadUnaligned`) must round-trip byte-identically and stay loud — every
/// truncation and byte-flip either reads back an equal frame or throws a typed
/// error, never crashes and never returns a partial frame.
final class SPBZeroCopyTests: XCTestCase {

    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private func mixedFrame() throws -> DataFrame {
        DataFrame(columns: [
            ("d", .fromOptionalDoubles([1.5, nil, -3.25, 0, 42.0])),
            // "\u{FC}\u{2260}\u{1F642}" covers 2-, 3-, and 4-byte UTF-8 sequences.
            ("s", .fromOptionalStrings(["odd", nil, "", "\u{FC}\u{2260}\u{1F642}", "x"])),
            ("b", .fromOptionalBools([true, false, nil, true, false])),
            ("i", .fromOptionalInts([Int.max, nil, -7, 0, 123])),
            ("v", try .fromOptionalVectors([[1, 2, 3], nil, [0, 0, 0], [-1.5, 2.5, 3.5], [9, 8, 7]], dims: 3)),
        ])
    }

    // MARK: - Unaligned payloads (proves loadUnaligned / copyMemory correctness)

    func test_unalignedNumericPayloads_roundTrip() throws {
        // Strings of deliberately odd byte lengths push every following column's
        // numeric payload to an odd file offset, so any residual assumption of
        // natural alignment (a plain `load`) would trap here.
        for prefixLen in 1...9 {
            let tag = String(repeating: "z", count: prefixLen)
            let df = DataFrame(columns: [
                ("name", .fromStrings([tag, tag + "!", "third"])),
                ("d", .fromDoubles([1.25, -2.5, 3.75])),
                ("i", .fromInts([1, -2, 3])),
                ("v", try .fromVectors([[1, 2], [3, 4], [5, 6]], dims: 2)),
            ])
            let restored = try DataFrame.readSPB(from: df.toSPBData())
            for col in df.columnNames {
                XCTAssertEqual(restored.columns[col]!, df.columns[col]!,
                    "prefixLen=\(prefixLen) column '\(col)'")
            }
        }
    }

    // MARK: - Exhaustive truncation fuzz

    func test_everyTruncation_throwsCorrupt_neverCrashes() throws {
        let data = try mixedFrame().toSPBData()
        // Every proper prefix is incomplete -> must throw .corrupt (or, for a
        // prefix that stops right at the version field, .versionUnsupported is
        // impossible here since bytes are canonical). Never a crash.
        for cut in 0..<data.count {
            let truncated = data.prefix(cut)
            XCTAssertThrowsError(try DataFrame.readSPB(from: truncated), "cut=\(cut)") { error in
                guard error is VectorError else {
                    return XCTFail("cut=\(cut): expected VectorError, got \(error)")
                }
            }
        }
        // The full file reads back equal.
        XCTAssertNoThrow(try DataFrame.readSPB(from: data))
    }

    // MARK: - Byte-flip fuzz

    func test_randomByteFlips_neverCrash_andEitherEqualOrThrow() throws {
        let original = try mixedFrame()
        let clean = original.toSPBData()
        var rng = LCG(state: 0xF00D)

        for _ in 0..<4000 {
            var data = clean
            let index = Int(rng.next() % UInt64(data.count))
            let flip = UInt8(rng.next() & 0xFF)
            data[data.startIndex + index] = flip

            do {
                let restored = try DataFrame.readSPB(from: data)
                // A read that succeeds must still be a canonical, self-consistent
                // frame: re-serializing it reproduces the exact bytes it parsed.
                XCTAssertEqual(restored.toSPBData(), data,
                    "accepted a non-canonical mutation at index=\(index)")
            } catch let error as VectorError {
                _ = error  // loud, typed rejection — the expected common case.
            } catch {
                XCTFail("unexpected non-VectorError at index=\(index): \(error)")
            }
        }
    }

    // MARK: - File-path (memory-mapped) parity

    func test_fileAndDataReaders_agree() throws {
        let df = try mixedFrame()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spb_zerocopy_\(UUID().uuidString).spb")
        defer { try? FileManager.default.removeItem(at: url) }
        try df.writeSPB(to: url)

        let fromFile = try DataFrame.readSPB(from: url)     // mmap path
        let fromData = try DataFrame.readSPB(from: df.toSPBData())
        for col in df.columnNames {
            XCTAssertEqual(fromFile.columns[col]!, fromData.columns[col]!, "column '\(col)'")
        }
        XCTAssertEqual(fromFile.toSPBData(), df.toSPBData())
    }
}
