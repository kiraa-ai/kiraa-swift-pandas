import XCTest
@testable import SwiftPandasCLI

/// Round-trip tests for the daemon wire protocol. These pin down the JSON
/// shape so future client/server implementations (Phase 2) cannot drift
/// without updating the tests.
final class ProtocolTests: XCTestCase {

    private func roundTripRequest(_ req: WireRequest) throws -> WireRequest {
        let frame = try WireFrame.encode(req)
        return try WireFrame.decode(WireRequest.self, from: frame)
    }

    private func roundTripResponse(_ resp: WireResponse) throws -> WireResponse {
        let frame = try WireFrame.encode(resp)
        return try WireFrame.decode(WireResponse.self, from: frame)
    }

    // MARK: - Framing

    func test_encodedFrame_endsWithNewline() throws {
        let req = WireRequest(cmd: .list)
        let frame = try WireFrame.encode(req)
        XCTAssertEqual(frame.last, 0x0A, "every wire frame must end with '\\n'")
    }

    func test_encodedFrame_decodableWithoutNewline() throws {
        let req = WireRequest(cmd: .list)
        var frame = try WireFrame.encode(req)
        frame.removeLast() // strip newline; decoder must still cope
        let back = try WireFrame.decode(WireRequest.self, from: frame)
        XCTAssertEqual(back.cmd, .list)
    }

    // MARK: - Request schemas

    func test_loadRequest_usesNameKey() throws {
        let req = WireRequest(cmd: .load, path: "/tmp/x.csv", name: "df1", sep: ",")
        let frame = try WireFrame.encode(req)
        let json = String(data: frame, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"name\":\"df1\""), "target binding must serialize under the wire key 'name', got: \(json)")
        XCTAssertTrue(json.contains("\"path\":\"/tmp/x.csv\""))
    }

    func test_pipeRequest_roundTrip() throws {
        let req = WireRequest(
            cmd: .pipe,
            name: "dst",
            from: "src",
            chain: "filter(x > 1) | head(5)"
        )
        let back = try roundTripRequest(req)
        XCTAssertEqual(back.cmd, .pipe)
        XCTAssertEqual(back.from, "src")
        XCTAssertEqual(back.name, "dst")
        XCTAssertEqual(back.chain, "filter(x > 1) | head(5)")
    }

    func test_allCommands_decodeRoundTrip() throws {
        for cmd in WireCommand.allCases {
            let req = WireRequest(cmd: cmd)
            let back = try roundTripRequest(req)
            XCTAssertEqual(back.cmd, cmd, "command \(cmd) must survive round trip")
        }
    }

    // MARK: - Response payloads

    func test_loadResponse_roundTrip() throws {
        let resp = WireResponse.success(
            id: "abc",
            data: .load(name: "df1", rows: 100, cols: 4, bytes: 8192)
        )
        let back = try roundTripResponse(resp)
        XCTAssertTrue(back.ok)
        XCTAssertEqual(back.id, "abc")
        guard case .load(let name, let rows, let cols, let bytes) = back.data else {
            return XCTFail("expected .load payload")
        }
        XCTAssertEqual(name, "df1")
        XCTAssertEqual(rows, 100)
        XCTAssertEqual(cols, 4)
        XCTAssertEqual(bytes, 8192)
    }

    func test_pipeResponse_carriesStages() throws {
        let resp = WireResponse.success(
            id: "x",
            data: .pipe(name: "out", rows: 50, cols: 3, bytes: 1024, stages: 4)
        )
        let back = try roundTripResponse(resp)
        guard case .pipe(_, _, _, _, let stages) = back.data else {
            return XCTFail("expected .pipe payload")
        }
        XCTAssertEqual(stages, 4)
    }

    func test_listResponse_preservesItems() throws {
        let entry = DataFrameRegistry.Entry(name: "a", rows: 10, cols: 2, bytes: 200, createdAt: Date())
        let resp = WireResponse.success(id: "x", data: .list(items: [entry]))
        let back = try roundTripResponse(resp)
        guard case .list(let items) = back.data else {
            return XCTFail("expected .list payload")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "a")
        XCTAssertEqual(items[0].rows, 10)
        XCTAssertEqual(items[0].bytes, 200)
    }

    func test_statusResponse_usesSnakeCaseKeys() throws {
        let resp = WireResponse.success(
            id: "s",
            data: .status(pid: 4711, uptimeSeconds: 12.5, dataframeCount: 3, totalBytes: 99, socket: "/tmp/s.sock")
        )
        let frame = try WireFrame.encode(resp)
        let json = String(data: frame, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"uptime_s\":12.5"), "json: \(json)")
        XCTAssertTrue(json.contains("\"df_count\":3"))
        XCTAssertTrue(json.contains("\"total_bytes\":99"))
    }

    // MARK: - Error payloads

    func test_failureResponse_hasStableCode() throws {
        let resp = WireResponse.failure(
            id: "e",
            WireError(code: WireErrorCode.noSuchDataFrame, message: "no dataframe bound to name 'ghost'")
        )
        let back = try roundTripResponse(resp)
        XCTAssertFalse(back.ok)
        XCTAssertEqual(back.error?.code, "no_such_df")
        XCTAssertTrue(back.error?.message.contains("ghost") ?? false)
    }

    func test_cliErrorMapping_unknownColumn() {
        let mapped = WireError.from(CLIError.unknownColumn("zzz"))
        XCTAssertEqual(mapped.code, WireErrorCode.unknownColumn)
        XCTAssertTrue(mapped.message.contains("zzz"))
    }

    func test_cliErrorMapping_fileNotFound() {
        let mapped = WireError.from(CLIError.fileNotFound("/missing"))
        XCTAssertEqual(mapped.code, WireErrorCode.io)
    }

    func test_protocolVersion_isOne() {
        XCTAssertEqual(WireProtocol.version, 1)
        let req = WireRequest(cmd: .list)
        XCTAssertEqual(req.v, 1)
    }
}
