import XCTest
import SwiftPandas
@testable import SwiftPandasCLI

/// Unit tests for `DataFrameRegistry` — the actor that owns the resident
/// "memory area" where DataFrames live for the lifetime of the daemon.
///
/// Phase 1 runs these as pure Swift actor tests (no IPC). Phase 2 will reuse
/// the same registry behind a Unix-domain socket and add socket-level tests.
final class RegistryTests: XCTestCase {

    private func sample(_ n: Int = 4) -> DataFrame {
        DataFrame(["x": Array(repeating: 1.0, count: n),
                   "y": Array(repeating: 2.0, count: n)])
    }

    func test_bindAndLookup_roundTrip() async {
        let registry = DataFrameRegistry()
        let overwrote = await registry.bind("df1", sample(3))
        XCTAssertFalse(overwrote, "first bind of a fresh name must not be marked as overwrite")

        let got = await registry.lookup("df1")
        XCTAssertNotNil(got)
        XCTAssertEqual(got?.rowCount, 3)
        XCTAssertEqual(got?.columnCount, 2)
    }

    func test_rebindOverwrites_andReportsTrue() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("d", sample(2))
        let overwrote = await registry.bind("d", sample(10))
        XCTAssertTrue(overwrote, "second bind under same name must report overwrite")

        let got = await registry.lookup("d")
        XCTAssertEqual(got?.rowCount, 10, "lookup must return the latest binding")
    }

    func test_lookupMissing_returnsNil() async {
        let registry = DataFrameRegistry()
        let got = await registry.lookup("ghost")
        XCTAssertNil(got)
    }

    func test_drop_returnsFreedBytes_andRemovesEntry() async {
        let registry = DataFrameRegistry()
        let df = sample(8)
        _ = await registry.bind("d", df)
        let expected = df.estimatedBytes

        let freed = await registry.drop("d")
        XCTAssertNotNil(freed)
        XCTAssertEqual(freed, expected)

        let missing = await registry.lookup("d")
        XCTAssertNil(missing, "dropped entry must no longer be looked-up-able")
    }

    func test_dropMissing_returnsNil() async {
        let registry = DataFrameRegistry()
        let freed = await registry.drop("never-bound")
        XCTAssertNil(freed)
    }

    func test_listIsSortedByCreatedAt() async throws {
        let registry = DataFrameRegistry()
        _ = await registry.bind("first", sample(2))
        try await Task.sleep(nanoseconds: 5_000_000) // 5ms — enough to differ
        _ = await registry.bind("second", sample(2))
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = await registry.bind("third", sample(2))

        let items = await registry.list()
        XCTAssertEqual(items.map(\.name), ["first", "second", "third"])
    }

    func test_listEntries_carryShapeAndBytes() async {
        let registry = DataFrameRegistry()
        let df = sample(7)
        _ = await registry.bind("a", df)

        let items = await registry.list()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "a")
        XCTAssertEqual(items[0].rows, 7)
        XCTAssertEqual(items[0].cols, 2)
        XCTAssertEqual(items[0].bytes, df.estimatedBytes)
    }

    func test_totalBytes_matchesSumOfEntries() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("a", sample(3))
        _ = await registry.bind("b", sample(7))

        let total = await registry.totalBytes()
        let items = await registry.list()
        XCTAssertEqual(total, items.reduce(0) { $0 + $1.bytes })
    }

    func test_clear_freesEverything() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("a", sample(5))
        _ = await registry.bind("b", sample(5))

        let totalBefore = await registry.totalBytes()
        let freed = await registry.clear()
        XCTAssertEqual(freed, totalBefore)

        let countAfter = await registry.count()
        XCTAssertEqual(countAfter, 0)
        let a = await registry.lookup("a")
        let b = await registry.lookup("b")
        XCTAssertNil(a)
        XCTAssertNil(b)
    }

    func test_concurrentBinds_allLand() async {
        let registry = DataFrameRegistry()
        let n = 32

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    _ = await registry.bind("df\(i)", self.sample(2))
                }
            }
        }

        let count = await registry.count()
        XCTAssertEqual(count, n, "concurrent binds must all be visible under the actor")
    }
}
