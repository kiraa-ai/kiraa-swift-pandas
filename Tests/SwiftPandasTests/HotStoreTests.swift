import XCTest
import Foundation
@testable import SwiftPandas

// ===----------------------------------------------------------------------===//
// Hermetic tests for the HotStore submodule. No real filesystem is touched:
// all file access goes through FakeProbe, an in-memory FileSystemProbe.
// ===----------------------------------------------------------------------===//

/// In-memory FileSystemProbe: a dictionary of path → (bytes, stamp), with a
/// read counter so tests can assert that hot hits skip "disk".
final class FakeProbe: FileSystemProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: (data: Data, stamp: FileStamp)] = [:]
    private var reads = 0
    private var stamps = 0

    struct MissingFile: Error, Equatable { let path: String }

    /// Creates/overwrites a fake file, bumping its stamp.
    func write(_ url: URL, data: Data, modifiedAt: Date) {
        lock.lock(); defer { lock.unlock() }
        files[url.standardizedFileURL.path] = (data, FileStamp(modifiedAt: modifiedAt, size: data.count))
    }

    func write(_ url: URL, text: String, modifiedAt: Date) {
        write(url, data: Data(text.utf8), modifiedAt: modifiedAt)
    }

    func delete(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        files[url.standardizedFileURL.path] = nil
    }

    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    func stamp(of url: URL) throws -> FileStamp {
        lock.lock(); defer { lock.unlock() }
        stamps += 1
        guard let f = files[url.standardizedFileURL.path] else {
            throw MissingFile(path: url.path)
        }
        return f.stamp
    }

    func read(_ url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        guard let f = files[url.standardizedFileURL.path] else {
            throw MissingFile(path: url.path)
        }
        return f.data
    }
}

/// Thread-safe recorder for onEvict callbacks.
final class EvictLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(FrameKey, EvictionReason)] = []
    func record(_ key: FrameKey, _ reason: EvictionReason) {
        lock.lock(); events.append((key, reason)); lock.unlock()
    }
    var all: [(FrameKey, EvictionReason)] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
    func reasons(for name: String) -> [EvictionReason] {
        all.filter { $0.0.name == name }.map { $0.1 }
    }
}

private func frame(_ n: Int, seed: Double = 1.0) -> DataFrame {
    DataFrame(["v": (0..<n).map { Double($0) * seed }])
}

final class HotStoreLifecycleTests: XCTestCase {

    func test_putGet_roundTripsFrame() async {
        let cache = FrameCache(budgetBytes: 1_000_000)
        let key = FrameKey(name: "a", tags: ["kind": "test"])
        let df = frame(10)
        let outcome = await cache.put(df, key: key, pinned: false)
        XCTAssertEqual(outcome, .stored, "first put under a fresh key must report .stored")
        let got = await cache.get(key)
        XCTAssertEqual(got?.rowCount, 10, "get must return the stored frame")
    }

    func test_keyIdentity_includesTags() async {
        let cache = FrameCache(budgetBytes: 1_000_000)
        await cache.put(frame(5), key: FrameKey(name: "a", tags: ["job": "1"]))
        let other = await cache.get(FrameKey(name: "a", tags: ["job": "2"]))
        XCTAssertNil(other, "same name with different tags is a different entry")
    }

    func test_replace_reportsReplaced() async {
        let cache = FrameCache(budgetBytes: 1_000_000)
        let key = FrameKey(name: "a")
        await cache.put(frame(5), key: key)
        let outcome = await cache.put(frame(6), key: key)
        XCTAssertEqual(outcome, .replaced, "second put under the same key must report .replaced")
        let got = await cache.get(key)
        XCTAssertEqual(got?.rowCount, 6, "replace must serve the new frame")
    }

    func test_budgetEviction_evictsColdestFirst() async {
        let log = EvictLog()
        let df = frame(100) // ~800+ bytes
        let one = df.estimatedBytes
        // Budget fits exactly two frames.
        let cache = FrameCache(budgetBytes: 2 * one + 16) { log.record($0, $1) }
        await cache.put(df, key: FrameKey(name: "cold"))
        await cache.put(df, key: FrameKey(name: "warm"))
        _ = await cache.get(FrameKey(name: "cold")) // touch: cold becomes warmest
        await cache.put(df, key: FrameKey(name: "new")) // must evict "warm" (coldest)
        let warm = await cache.get(FrameKey(name: "warm"))
        XCTAssertNil(warm, "LRU eviction must remove the least-recently-accessed entry ('warm')")
        let cold = await cache.get(FrameKey(name: "cold"))
        XCTAssertNotNil(cold, "recently touched entry must survive eviction")
        XCTAssertEqual(log.reasons(for: "warm"), [.budget], "eviction hook must fire with .budget for the LRU victim")
    }

    func test_oversizeFrame_isRefusedNeverStored() async {
        let cache = FrameCache(budgetBytes: 64)
        let key = FrameKey(name: "huge")
        let outcome = await cache.put(frame(10_000), key: key)
        XCTAssertEqual(outcome, .refusedOversize, "a frame larger than the whole budget must be refused")
        let got = await cache.get(key)
        XCTAssertNil(got, "a refused frame must not be resident")
        let stats = await cache.stats()
        XCTAssertEqual(stats.entryCount, 0, "refused put must leave the cache empty")
    }

    func test_pinnedEntries_surviveBudgetPressure() async {
        let df = frame(100)
        let one = df.estimatedBytes
        let cache = FrameCache(budgetBytes: 2 * one + 16)
        await cache.put(df, key: FrameKey(name: "pinned"), pinned: true)
        await cache.put(df, key: FrameKey(name: "a"))
        await cache.put(df, key: FrameKey(name: "b")) // over budget: must evict "a", not "pinned"
        let pinned = await cache.get(FrameKey(name: "pinned"))
        XCTAssertNotNil(pinned, "pinned entry must never be evicted")
        let a = await cache.get(FrameKey(name: "a"))
        XCTAssertNil(a, "unpinned entry must be the eviction victim while a pinned one survives")
    }

    func test_unpin_makesEntryEvictableImmediately() async {
        let df = frame(100)
        let one = df.estimatedBytes
        let cache = FrameCache(budgetBytes: one + 8)
        await cache.put(df, key: FrameKey(name: "p1"), pinned: true)
        await cache.put(df, key: FrameKey(name: "p2"), pinned: true) // pinned total exceeds budget by choice
        let both = await cache.stats()
        XCTAssertEqual(both.entryCount, 2, "pinned totals may exceed budget by explicit caller choice")
        await cache.unpin(FrameKey(name: "p1"))
        let after = await cache.stats()
        XCTAssertEqual(after.entryCount, 1, "unpinning while over budget must evict the now-evictable entry immediately")
    }

    func test_setBudget_reEnforcesImmediately() async {
        let df = frame(100)
        let cache = FrameCache(budgetBytes: 10 * df.estimatedBytes)
        for i in 0..<4 {
            await cache.put(df, key: FrameKey(name: "k\(i)"))
        }
        await cache.setBudget(bytes: df.estimatedBytes + 8)
        let stats = await cache.stats()
        XCTAssertEqual(stats.entryCount, 1, "shrinking the budget must evict down to fit right away")
        XCTAssertEqual(stats.budgetBytes, df.estimatedBytes + 8, "stats must reflect the new budget")
    }

    func test_invalidate_removesEntry() async {
        let cache = FrameCache(budgetBytes: 1_000_000)
        let key = FrameKey(name: "a")
        await cache.put(frame(5), key: key)
        await cache.invalidate(key)
        let got = await cache.get(key)
        XCTAssertNil(got, "invalidate must remove the entry")
    }

    func test_removeAll_dropsEverything_keepsCounters() async {
        let cache = FrameCache(budgetBytes: 1_000_000)
        await cache.put(frame(5), key: FrameKey(name: "a"))
        _ = await cache.get(FrameKey(name: "a"))
        await cache.removeAll()
        let stats = await cache.stats()
        XCTAssertEqual(stats.entryCount, 0, "removeAll must drop all entries")
        XCTAssertEqual(stats.bytes, 0, "removeAll must reset byte accounting")
        XCTAssertEqual(stats.hits, 1, "removeAll must preserve hit/miss counters")
    }

    func test_stats_trackHitsMissesBytesHighWater() async {
        let cache = FrameCache(budgetBytes: 1_000_000)
        let df = frame(50)
        await cache.put(df, key: FrameKey(name: "a"))
        _ = await cache.get(FrameKey(name: "a"))   // hit
        _ = await cache.get(FrameKey(name: "nope")) // miss
        let stats = await cache.stats()
        XCTAssertEqual(stats.hits, 1, "one hit expected")
        XCTAssertEqual(stats.misses, 1, "one miss expected")
        XCTAssertEqual(stats.bytes, df.estimatedBytes, "resident bytes must equal the stored frame's estimate")
        XCTAssertGreaterThanOrEqual(stats.highWaterBytes, stats.bytes, "high water can never be below current bytes")
    }

    func test_sharedBudget_framesAndTextCompete() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 4096, probe: probe)
        // Fill most of the shared pool with text.
        let url = URL(fileURLWithPath: "/fake/big.txt")
        probe.write(url, data: Data(repeating: 65, count: 3000), modifiedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.data(at: url)
        let afterText = await store.stats()
        XCTAssertEqual(afterText.bytes, 3000, "text bytes must count against the shared pool")
        // A frame that fits the pool alone but not alongside the text must
        // evict the text (both tiers compete for one budget).
        let df = frame(300) // ~2400 bytes
        await store.frames.put(df, key: FrameKey(name: "f"))
        let after = await store.stats()
        XCTAssertLessThanOrEqual(after.bytes, 4096, "shared pool must stay under budget after cross-tier eviction")
        let textGone = await store.texts.data(FrameKey(name: url.standardizedFileURL.path))
        XCTAssertNil(textGone, "the cold text entry must have been evicted to admit the frame")
    }

    func test_evictionHook_firesWithCorrectReasons() async throws {
        let log = EvictLog()
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe) { log.record($0, $1) }
        let url = URL(fileURLWithPath: "/fake/s.csv")
        probe.write(url, text: "v\n1\n", modifiedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.text(at: url)
        // Rewrite the file → stamp changes → next read must evict as stale.
        probe.write(url, text: "v\n2\n", modifiedAt: Date(timeIntervalSince1970: 2))
        _ = try await store.text(at: url)
        XCTAssertEqual(log.reasons(for: url.standardizedFileURL.path), [.stale],
                       "a stamp mismatch must evict with reason .stale")
        // Explicit invalidation.
        await store.frames.put(frame(3), key: FrameKey(name: "x"))
        await store.frames.invalidate(FrameKey(name: "x"))
        XCTAssertEqual(log.reasons(for: "x"), [.invalidated],
                       "explicit invalidate must report reason .invalidated")
    }
}

final class HotStoreByteIdentityTests: XCTestCase {

    /// Every fixture that has bitten a byte-parity gate before: UTF-8 BOM,
    /// CRLF endings, missing trailing newline, embedded quotes.
    private static let fixtures: [(name: String, bytes: [UInt8])] = [
        ("bom", [0xEF, 0xBB, 0xBF] + Array("a,b\n1,2\n".utf8)),
        ("crlf", Array("a,b\r\n1,2\r\n".utf8)),
        ("no-trailing-newline", Array("a,b\n1,2".utf8)),
        ("quotes", Array("a,b\n\"x,\"\"y\"\",z\",2\n".utf8)),
    ]

    func test_textAndData_byteIdentical_coldAndWarm() async throws {
        for (name, bytes) in Self.fixtures {
            let probe = FakeProbe()
            let store = HotStore(budgetBytes: 1_000_000, probe: probe)
            let url = URL(fileURLWithPath: "/fake/\(name).csv")
            let original = Data(bytes)
            probe.write(url, data: original, modifiedAt: Date(timeIntervalSince1970: 1))

            let cold = try await store.data(at: url)
            XCTAssertEqual(cold, original, "[\(name)] cold read must return the file's exact bytes")
            let warm = try await store.data(at: url)
            XCTAssertEqual(warm, original, "[\(name)] warm read must return byte-identical content")
            XCTAssertEqual(probe.readCount, 1, "[\(name)] the warm read must not touch disk")

            let coldText = try await store.text(at: url)
            let expected = String(decoding: original, as: UTF8.self)
            XCTAssertEqual(coldText, expected, "[\(name)] text must decode the exact stored bytes (BOM/CRLF preserved)")
            let warmText = try await store.text(at: url)
            XCTAssertEqual(warmText, coldText, "[\(name)] cold and warm text must be identical")
        }
    }

    func test_stampChange_alwaysEvictsAndRereads() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/f.txt")
        probe.write(url, text: "old-content", modifiedAt: Date(timeIntervalSince1970: 1))
        _ = try await store.text(at: url)
        probe.write(url, text: "new-content", modifiedAt: Date(timeIntervalSince1970: 2))
        let after = try await store.text(at: url)
        XCTAssertEqual(after, "new-content", "a stale entry must never be served: stamp mismatch → evict → re-read")
    }

    func test_sameStampSameSize_servesHot() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/f.txt")
        probe.write(url, text: "content", modifiedAt: Date(timeIntervalSince1970: 5))
        _ = try await store.text(at: url)
        _ = try await store.text(at: url)
        _ = try await store.text(at: url)
        XCTAssertEqual(probe.readCount, 1, "unchanged stamp must serve from memory (exactly one disk read)")
    }

    func test_missPathErrors_areTheDiskErrors() async {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/missing.txt")
        do {
            _ = try await store.text(at: url)
            XCTFail("reading a missing file must throw")
        } catch let e as FakeProbe.MissingFile {
            XCTAssertEqual(e.path, url.path, "the thrown error must be the disk read's own error, not a cache error")
        } catch {
            XCTFail("expected the probe's MissingFile error, got \(error)")
        }
    }

    func test_publishText_hitWithoutDiskRead() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/out.csv")
        let body = "a,b\n1,2\n"
        probe.write(url, text: body, modifiedAt: Date(timeIntervalSince1970: 3)) // "the write"
        await store.publishText(body, for: url)
        let got = try await store.text(at: url)
        XCTAssertEqual(got, body, "published text must be served verbatim")
        XCTAssertEqual(probe.readCount, 0, "a write-time publish must make the consumer's read a pure memory hit")
    }

    func test_publishText_unreadableStamp_droppedSilentlyButCounted() async {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/never-written.csv")
        await store.publishText("data", for: url) // no fake file → stamp unreadable
        let stats = await store.stats()
        XCTAssertEqual(stats.droppedPublishes, 1, "an unstampable publish must be counted, not thrown")
        XCTAssertEqual(stats.entryCount, 0, "a dropped publish must not store anything")
    }

    func test_frameHotCheck_skipsReaderOnHit() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/df.csv")
        probe.write(url, text: "v\n1\n2\n", modifiedAt: Date(timeIntervalSince1970: 1))
        let key = FrameKey(name: "df", tags: ["kind": "test"])

        let counter = Counter()
        let reader: @Sendable (URL) throws -> DataFrame = { _ in
            counter.increment()
            return frame(2)
        }
        _ = try await store.frame(at: url, key: key, reader: reader)
        let hot = try await store.frame(at: url, key: key, reader: reader)
        XCTAssertEqual(counter.value, 1, "the hot path must skip both the disk read and the parse")
        XCTAssertEqual(hot.rowCount, 2, "the hot frame must be the parsed frame")

        probe.write(url, text: "v\n9\n", modifiedAt: Date(timeIntervalSince1970: 2))
        _ = try await store.frame(at: url, key: key, reader: reader)
        XCTAssertEqual(counter.value, 2, "a stamp change must re-run the reader")
    }
}

final class HotStoreViewTests: XCTestCase {

    func test_view_cachesUnderDerivedKey_computesOnce() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let parent = FrameKey(name: "supp", tags: ["kind": "supplementary"])
        await store.publishFrame(frame(10), key: parent, stampedTo: nil)

        let v1 = try await store.view(name: "big", over: parent) { $0.filter(col("v") > 4.0) }
        XCTAssertEqual(v1.rowCount, 5, "the view must be the collected plan result")
        let derived = await store.get(FrameKey(name: "supp#big", tags: ["kind": "supplementary"]))
        XCTAssertNotNil(derived, "the view must be cached under parent.name + \"#\" + name with the parent's tags")
        let v2 = try await store.view(name: "big", over: parent) { _ in
            XCTFail("a cached view must not re-run its plan")
            return DataFrame().lazy()
        }
        XCTAssertEqual(v2.rowCount, 5, "the cached view must be served")
    }

    func test_view_missingParent_throws() async {
        let store = HotStore(budgetBytes: 1_000_000, probe: FakeProbe())
        do {
            _ = try await store.view(name: "x", over: FrameKey(name: "absent")) { $0 }
            XCTFail("view over a non-resident parent must throw")
        } catch let e as HotStoreError {
            XCTAssertEqual(e, .missingParent(FrameKey(name: "absent")),
                           "the error must identify the missing parent key")
        } catch {
            XCTFail("expected HotStoreError.missingParent, got \(error)")
        }
    }

    func test_view_invalidatedWithParent_invalidate() async throws {
        let store = HotStore(budgetBytes: 1_000_000, probe: FakeProbe())
        let parent = FrameKey(name: "p")
        await store.publishFrame(frame(4), key: parent, stampedTo: nil)
        _ = try await store.view(name: "v", over: parent) { $0 }
        await store.invalidate(parent)
        let derived = await store.get(FrameKey(name: "p#v"))
        XCTAssertNil(derived, "invalidating the parent must cascade to its views")
    }

    func test_view_invalidatedWhenParentGoesStale() async throws {
        let probe = FakeProbe()
        let store = HotStore(budgetBytes: 1_000_000, probe: probe)
        let url = URL(fileURLWithPath: "/fake/supp.csv")
        probe.write(url, text: "v\n1\n", modifiedAt: Date(timeIntervalSince1970: 1))
        let parent = FrameKey(name: "supp")
        await store.publishFrame(frame(4), key: parent, stampedTo: url)
        _ = try await store.view(name: "v", over: parent) { $0 }

        // File changes on disk → parent is stale → the view must not survive.
        probe.write(url, text: "v\n2\n", modifiedAt: Date(timeIntervalSince1970: 2))
        do {
            _ = try await store.view(name: "v", over: parent) { $0 }
            XCTFail("a view over a stale parent must not be served")
        } catch HotStoreError.missingParent {
            // expected: parent evicted as stale; caller re-loads
        }
        let derived = await store.get(FrameKey(name: "supp#v"))
        XCTAssertNil(derived, "the derived view must be gone after its parent went stale")
        let parentGone = await store.get(parent)
        XCTAssertNil(parentGone, "the stale parent itself must have been evicted")
    }

    func test_view_invalidatedWhenParentReplaced() async throws {
        let store = HotStore(budgetBytes: 1_000_000, probe: FakeProbe())
        let parent = FrameKey(name: "p")
        await store.publishFrame(frame(4), key: parent, stampedTo: nil)
        _ = try await store.view(name: "v", over: parent) { $0 }
        await store.publishFrame(frame(8), key: parent, stampedTo: nil) // replace
        let derived = await store.get(FrameKey(name: "p#v"))
        XCTAssertNil(derived, "replacing the parent must invalidate views computed from the old content")
    }
}

/// Minimal thread-safe counter for @Sendable closures in tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
