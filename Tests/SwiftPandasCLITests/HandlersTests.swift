import XCTest
import SwiftPandas
@testable import SwiftPandasCLI

/// End-to-end tests for the daemon command handlers running against an
/// in-process `DataFrameRegistry`. This is the same logic Phase 2 will host
/// behind a Unix-domain socket; testing it here lets us pin down semantics
/// without needing the IPC layer.
final class HandlersTests: XCTestCase {

    // MARK: - Fixtures

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    }

    private func tempCSV(_ name: String = "tmp.csv") -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftpandas-handlers-\(UUID().uuidString)-\(name)").path
    }

    private func unwrapData(_ resp: WireResponse, file: StaticString = #filePath, line: UInt = #line) -> WireData {
        if !resp.ok {
            XCTFail("expected ok response, got error \(resp.error?.code ?? "?"): \(resp.error?.message ?? "?")", file: file, line: line)
        }
        return resp.data!
    }

    // MARK: - load

    func test_load_bindsDataFrame() async {
        let registry = DataFrameRegistry()
        let req = WireRequest(cmd: .load, path: fixtureURL("sales.csv").path, name: "sales")
        let resp = await Handlers.handleLoad(req, registry: registry)
        guard case .load(let name, let rows, let cols, let bytes) = unwrapData(resp) else {
            return XCTFail("expected .load payload")
        }
        XCTAssertEqual(name, "sales")
        XCTAssertGreaterThan(rows, 0)
        XCTAssertGreaterThan(cols, 0)
        XCTAssertGreaterThan(bytes, 0)
        let bound = await registry.lookup("sales")
        XCTAssertNotNil(bound)
    }

    func test_load_missingFile_returnsIOError() async {
        let registry = DataFrameRegistry()
        let req = WireRequest(cmd: .load, path: "/no/such/file.csv", name: "x")
        let resp = await Handlers.handleLoad(req, registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.io)
    }

    func test_load_missingBinding_returnsValidationError() async {
        let registry = DataFrameRegistry()
        let req = WireRequest(cmd: .load, path: fixtureURL("sales.csv").path)
        let resp = await Handlers.handleLoad(req, registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.nameRequired)
    }

    func test_load_rebind_surfacesWarning() async {
        let registry = DataFrameRegistry()
        let r1 = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        XCTAssertTrue(r1.ok)
        XCTAssertNil(r1.warning, "first bind must not carry an overwrite warning")
        let r2 = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        XCTAssertTrue(r2.ok)
        XCTAssertNotNil(r2.warning)
        XCTAssertTrue(r2.warning?.contains("overwrote") ?? false)
    }

    // MARK: - pipe

    func test_pipe_appliesChain() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)

        let req = WireRequest(cmd: .pipe, name: "big", from: "s", chain: "filter(revenue > 10000) | head(3)")
        let resp = await Handlers.handlePipe(req, registry: registry)
        guard case .pipe(let name, let rows, _, _, let stages) = unwrapData(resp) else {
            return XCTFail("expected .pipe payload")
        }
        XCTAssertEqual(name, "big")
        XCTAssertEqual(stages, 2)
        XCTAssertLessThanOrEqual(rows, 3)
        let bound = await registry.lookup("big")
        XCTAssertNotNil(bound)
    }

    func test_pipe_unknownSource_returnsNoSuchDF() async {
        let registry = DataFrameRegistry()
        let req = WireRequest(cmd: .pipe, name: "out", from: "ghost", chain: "head(1)")
        let resp = await Handlers.handlePipe(req, registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.noSuchDataFrame)
    }

    func test_pipe_parseError_mapsToWireCode() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let req = WireRequest(cmd: .pipe, name: "x", from: "s", chain: "notarealop(1)")
        let resp = await Handlers.handlePipe(req, registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.unknownOperation)
    }

    func test_pipe_unknownColumn_mapsToWireCode() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let req = WireRequest(cmd: .pipe, name: "x", from: "s", chain: "filter(zzz > 1)")
        let resp = await Handlers.handlePipe(req, registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.unknownColumn)
    }

    // MARK: - save

    func test_save_writesCSV() async throws {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)

        let outPath = tempCSV("out.csv")
        defer { try? FileManager.default.removeItem(atPath: outPath) }

        let resp = await Handlers.handleSave(.init(cmd: .save, path: outPath, name: "s"), registry: registry)
        guard case .save(let path, let rows, _) = unwrapData(resp) else {
            return XCTFail("expected .save payload")
        }
        XCTAssertEqual(path, outPath)
        XCTAssertGreaterThan(rows, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outPath))
    }

    func test_save_unknownName_returnsNoSuchDF() async {
        let registry = DataFrameRegistry()
        let resp = await Handlers.handleSave(.init(cmd: .save, path: tempCSV(), name: "ghost"), registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.noSuchDataFrame)
    }

    // MARK: - list / drop / show

    func test_list_reportsAllBindings() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s1"), registry: registry)
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s2"), registry: registry)

        let resp = await Handlers.handleList(.init(cmd: .list), registry: registry)
        guard case .list(let items) = unwrapData(resp) else {
            return XCTFail("expected .list payload")
        }
        XCTAssertEqual(Set(items.map(\.name)), ["s1", "s2"])
    }

    func test_drop_freesAndReportsBytes() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let before = await registry.totalBytes()
        XCTAssertGreaterThan(before, 0)

        let resp = await Handlers.handleDrop(.init(cmd: .drop, name: "s"), registry: registry)
        guard case .drop(let name, let freed) = unwrapData(resp) else {
            return XCTFail("expected .drop payload")
        }
        XCTAssertEqual(name, "s")
        XCTAssertEqual(freed, before)
        let after = await registry.totalBytes()
        XCTAssertEqual(after, 0)
    }

    func test_drop_unknown_returnsNoSuchDF() async {
        let registry = DataFrameRegistry()
        let resp = await Handlers.handleDrop(.init(cmd: .drop, name: "ghost"), registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.noSuchDataFrame)
    }

    func test_show_returnsCSVPreview() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let resp = await Handlers.handleShow(.init(cmd: .show, name: "s", head: 2), registry: registry)
        guard case .show(_, let rows, _, let csv, let truncated) = unwrapData(resp) else {
            return XCTFail("expected .show payload")
        }
        XCTAssertEqual(rows, 2)
        XCTAssertFalse(truncated)
        // 2 preview rows + 1 header line at minimum
        XCTAssertGreaterThanOrEqual(csv.split(separator: "\n").count, 3)
    }

    // MARK: - info

    func test_info_reportsPerColumnMetadata() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let resp = await Handlers.handleInfo(.init(cmd: .info, name: "s"), registry: registry)
        guard case .info(let n, let rows, let cols, let bytes, let columns) = unwrapData(resp) else {
            return XCTFail("expected .info payload")
        }
        XCTAssertEqual(n, "s")
        XCTAssertGreaterThan(rows, 0)
        XCTAssertEqual(cols, columns.count)
        XCTAssertGreaterThan(bytes, 0)
        // Sales fixture has known columns.
        let names = Set(columns.map(\.name))
        XCTAssertTrue(names.contains("revenue"))
        XCTAssertTrue(names.contains("region"))
        // dtypes are populated for every column.
        for c in columns {
            XCTAssertFalse(c.dtype.isEmpty, "column \(c.name) missing dtype")
            XCTAssertGreaterThanOrEqual(c.nonNull, 0)
            XCTAssertGreaterThan(c.bytes, 0)
        }
    }

    func test_info_unknownName_returnsNoSuchDF() async {
        let registry = DataFrameRegistry()
        let resp = await Handlers.handleInfo(.init(cmd: .info, name: "ghost"), registry: registry)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.noSuchDataFrame)
    }

    // MARK: - status / shutdown

    func test_status_reportsRegistryStats() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let resp = await Handlers.handleStatus(.init(cmd: .status), registry: registry, socketPath: "/tmp/x.sock", pid: 7777)
        guard case .status(let pid, _, let dfCount, let totalBytes, let socket) = unwrapData(resp) else {
            return XCTFail("expected .status payload")
        }
        XCTAssertEqual(pid, 7777)
        XCTAssertEqual(dfCount, 1)
        XCTAssertGreaterThan(totalBytes, 0)
        XCTAssertEqual(socket, "/tmp/x.sock")
    }

    func test_shutdown_clearsRegistry() async {
        let registry = DataFrameRegistry()
        _ = await Handlers.handleLoad(.init(cmd: .load, path: fixtureURL("sales.csv").path, name: "s"), registry: registry)
        let before = await registry.count()
        XCTAssertEqual(before, 1)

        let resp = await Handlers.handleShutdown(.init(cmd: .shutdown), registry: registry, pid: 1234)
        guard case .shutdown(let pid) = unwrapData(resp) else {
            return XCTFail("expected .shutdown payload")
        }
        XCTAssertEqual(pid, 1234)
        let after = await registry.count()
        XCTAssertEqual(after, 0)
    }

    // MARK: - dispatch

    func test_dispatch_routesToCorrectHandler() async {
        let registry = DataFrameRegistry()
        let resp = await Handlers.dispatch(.init(cmd: .list), registry: registry)
        guard case .list = unwrapData(resp) else {
            return XCTFail("dispatch must route 'list' to handleList")
        }
    }
}
