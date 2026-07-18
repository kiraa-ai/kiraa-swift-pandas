import XCTest
import SwiftPandas
@testable import SwiftPandasCLI

/// Tests for the `kind` taxonomy tag added to the resident-memory registry
/// + wire protocol. The tag drives the GUI's transaction-vs-metadata
/// grouping but is also exposed via `swiftpandas list` and the wire `list`
/// reply for any tool that wants to filter.
final class KindTaxonomyTests: XCTestCase {

    private func sample(_ n: Int = 4) -> DataFrame {
        DataFrame(["x": Array(repeating: 1.0, count: n),
                   "y": Array(repeating: 2.0, count: n)])
    }

    // MARK: - Registry semantics

    func test_defaultKind_isTransaction() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("df", sample())
        let entries = await registry.list()
        XCTAssertEqual(entries.first?.kind, "transaction",
                       "Default kind must be 'transaction' for backwards compatibility.")
    }

    func test_explicitKind_isPreserved() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("regions", sample(), kind: "metadata")
        let kind = await registry.kind("regions")
        XCTAssertEqual(kind, "metadata")
    }

    func test_rebindWithoutKind_preservesExistingKind() async {
        // The "pipe inherits source kind" contract relies on this: an
        // unannotated re-bind must not reset a previously-set kind to the
        // default. Otherwise a `pipe` of a metadata DF would silently land
        // back under "transaction".
        let registry = DataFrameRegistry()
        _ = await registry.bind("regions", sample(2), kind: "metadata")
        _ = await registry.bind("regions", sample(7))   // re-bind, no kind
        let kind = await registry.kind("regions")
        XCTAssertEqual(kind, "metadata")
        let entries = await registry.list()
        XCTAssertEqual(entries.first(where: { $0.name == "regions" })?.rows, 7,
                       "Re-bind must still update the underlying DataFrame.")
    }

    func test_rebindWithExplicitKind_overrides() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("staged", sample(), kind: "metadata")
        _ = await registry.bind("staged", sample(), kind: "transaction")
        let kind = await registry.kind("staged")
        XCTAssertEqual(kind, "transaction")
    }

    func test_listEntries_includeKind() async {
        let registry = DataFrameRegistry()
        _ = await registry.bind("sales",   sample(), kind: "transaction")
        _ = await registry.bind("regions", sample(), kind: "metadata")
        let entries = await registry.list()
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.kind) })
        XCTAssertEqual(byName["sales"], "transaction")
        XCTAssertEqual(byName["regions"], "metadata")
    }

    // MARK: - Wire protocol round trip

    func test_loadRequest_serialisesKind() throws {
        let req = WireRequest(cmd: .load, path: "/tmp/x.csv", name: "regions", kind: "metadata")
        let frame = try WireFrame.encode(req)
        let json = String(data: frame, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"kind\":\"metadata\""),
                      "kind field must appear in the wire JSON. Got: \(json)")
    }

    func test_loadRequest_roundTrip_preservesKind() throws {
        let req = WireRequest(cmd: .load, path: "/tmp/x.csv", name: "df", kind: "metadata")
        let frame = try WireFrame.encode(req)
        let back = try WireFrame.decode(WireRequest.self, from: frame)
        XCTAssertEqual(back.kind, "metadata")
    }

    func test_listResponse_carriesKind() throws {
        let now = Date()
        let resp = WireResponse.success(id: "x", data: .list(items: [
            .init(name: "sales",   rows: 100, cols: 4, bytes: 8192, createdAt: now, kind: "transaction"),
            .init(name: "regions", rows: 5,   cols: 2, bytes: 256,  createdAt: now, kind: "metadata"),
        ]))
        let back = try WireFrame.decode(WireResponse.self, from: try WireFrame.encode(resp))
        guard case .list(let items) = back.data else { return XCTFail("expected .list") }
        let kinds = items.map(\.kind)
        XCTAssertEqual(Set(kinds), ["transaction", "metadata"])
    }

    // MARK: - Handlers

    func test_handleLoad_appliesKindFromRequest() async throws {
        let registry = DataFrameRegistry()
        let csv = "x,y\n1,2\n3,4\n"
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kind-test-\(UUID().uuidString).csv")
        try csv.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resp = await Handlers.handleLoad(
            .init(cmd: .load, path: tmp.path, name: "regions", kind: "metadata"),
            registry: registry
        )
        XCTAssertTrue(resp.ok)
        let kind = await registry.kind("regions")
        XCTAssertEqual(kind, "metadata")
    }

    func test_handlePipe_inheritsSourceKind() async throws {
        let registry = DataFrameRegistry()
        let csv = "x,y\n1,2\n3,4\n"
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kind-test-\(UUID().uuidString).csv")
        try csv.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = await Handlers.handleLoad(
            .init(cmd: .load, path: tmp.path, name: "sales", kind: "transaction"),
            registry: registry
        )

        // Pipe result without an explicit kind should inherit "transaction".
        let resp = await Handlers.handlePipe(
            .init(cmd: .pipe, name: "filtered", from: "sales", chain: "head(1)"),
            registry: registry
        )
        XCTAssertTrue(resp.ok)
        let kind = await registry.kind("filtered")
        XCTAssertEqual(kind, "transaction",
                       "pipe result must inherit the source's kind when not explicitly overridden")
    }

    func test_handlePipe_overridesKindWhenExplicit() async throws {
        let registry = DataFrameRegistry()
        let csv = "x,y\n1,2\n"
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kind-test-\(UUID().uuidString).csv")
        try csv.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = await Handlers.handleLoad(
            .init(cmd: .load, path: tmp.path, name: "raw", kind: "transaction"),
            registry: registry
        )
        let resp = await Handlers.handlePipe(
            .init(cmd: .pipe, name: "summary", from: "raw", chain: "head(1)", kind: "metadata"),
            registry: registry
        )
        XCTAssertTrue(resp.ok)
        let kind = await registry.kind("summary")
        XCTAssertEqual(kind, "metadata")
    }
}
