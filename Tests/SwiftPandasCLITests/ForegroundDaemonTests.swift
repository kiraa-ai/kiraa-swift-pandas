import XCTest
import Foundation
@testable import SwiftPandasCLI

/// PR 2 integration tests — spawn the actual `swiftpandas` binary as a
/// foreground daemon and exercise it via the `Client` API.
///
/// These tests prove that the round trip from CLI → daemon process → handler
/// → wire reply → client decode works against the binary that PR 5 will
/// release. PR 4 will replace each client subcommand stub with the same
/// `Client.sendRequest` we use directly here.
final class ForegroundDaemonTests: XCTestCase {

    private var tmpDir: URL!
    private var sockPath: String!
    private var pidPath: String!
    private var daemonProcess: Process?

    // MARK: - Helpers

    /// Locate the `swiftpandas` binary built by SwiftPM next to this test
    /// bundle. Walks up from the bundle URL until it finds an executable.
    private var binary: URL {
        var dir = Bundle.module.bundleURL
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("swiftpandas")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("Could not locate `swiftpandas` binary near \(Bundle.module.bundleURL.path)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    override func setUpWithError() throws {
        // /tmp (not $TMPDIR) keeps the socket path under macOS's 103-byte limit.
        tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sp-daemon-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        sockPath = tmpDir.appendingPathComponent("sock").path
        pidPath  = tmpDir.appendingPathComponent("pid").path
    }

    override func tearDownWithError() throws {
        if let p = daemonProcess, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        daemonProcess = nil
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Spawn `swiftpandas server start --foreground` against this test's
    /// isolated socket + pidfile. Polls for the socket file to appear, then
    /// for a `status` round trip to succeed. Throws on timeout.
    @discardableResult
    private func startDaemon(timeout: TimeInterval = 5) throws -> Process {
        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "server", "start", "--foreground",
            "--socket", sockPath,
            "--pidfile", pidPath,
        ]
        let outPipe = Foundation.Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        try p.run()
        daemonProcess = p

        // Phase 1: wait for socket file. NWListener writes the socket
        // before announcing readiness.
        let phase1Deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: sockPath) && Date() < phase1Deadline {
            if !p.isRunning {
                let captured = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                XCTFail("daemon exited before socket appeared. stderr:\n\(captured)")
                throw NSError(domain: "ForegroundDaemonTests", code: 1)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath),
                      "socket file did not appear within \(timeout)s")

        // Phase 2: wait for a successful status round trip — confirms the
        // listener is accept-ready, not just bound.
        let phase2Deadline = Date().addingTimeInterval(timeout)
        while Date() < phase2Deadline {
            if let resp = try? Client.sendRequest(.init(cmd: .status), socketPath: sockPath, timeout: 1),
               resp.ok {
                return p
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("daemon did not respond to status within \(timeout)s")
        return p
    }

    private func send(_ cmd: WireCommand, head: Int? = nil, name: String? = nil) throws -> WireResponse {
        let req = WireRequest(cmd: cmd, name: name, head: head)
        return try Client.sendRequest(req, socketPath: sockPath, timeout: 5)
    }

    // MARK: - Round trip

    func test_daemon_acceptsListRequest() throws {
        _ = try startDaemon()
        let resp = try send(.list)
        XCTAssertTrue(resp.ok, "expected ok, got \(String(describing: resp.error))")
        guard case .list(let items) = resp.data else {
            return XCTFail("expected .list payload, got \(String(describing: resp.data))")
        }
        XCTAssertTrue(items.isEmpty, "fresh daemon should have no dataframes")
    }

    func test_daemon_acceptsStatusRequest() throws {
        _ = try startDaemon()
        let resp = try send(.status)
        XCTAssertTrue(resp.ok)
        guard case .status(let pid, _, let dfCount, _, let socket) = resp.data else {
            return XCTFail("expected .status payload")
        }
        XCTAssertEqual(socket, sockPath)
        XCTAssertEqual(dfCount, 0)
        XCTAssertGreaterThan(pid, 0)
    }

    func test_daemon_pidFile_matchesDaemonProcess() throws {
        let p = try startDaemon()
        let pf = PIDFile(path: pidPath)
        let writtenPID = try pf.readPID()
        XCTAssertEqual(writtenPID, p.processIdentifier)
    }

    // MARK: - Lifecycle

    func test_daemon_shutdownCommand_exitsProcess() throws {
        let p = try startDaemon()
        let resp = try send(.shutdown)
        XCTAssertTrue(resp.ok)

        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(p.isRunning, "daemon should exit within 3s of shutdown command")
    }

    func test_daemon_shutdownCommand_cleansUpFiles() throws {
        let p = try startDaemon()
        _ = try send(.shutdown)
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath))
    }

    func test_daemon_sigterm_cleansUpFiles() throws {
        let p = try startDaemon()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))
        p.terminate()
        p.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath),
                       "socket file should be unlinked after SIGTERM")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath),
                       "pid file should be unlinked after SIGTERM")
    }

    // MARK: - Error paths

    func test_client_withoutDaemon_throwsNotRunning() {
        XCTAssertThrowsError(
            try Client.sendRequest(.init(cmd: .list), socketPath: sockPath, timeout: 1)
        ) { err in
            XCTAssertEqual(err as? Client.ClientError, .notRunning)
        }
    }

    func test_daemon_unknownDataframe_returnsNoSuchDF() throws {
        _ = try startDaemon()
        let req = WireRequest(cmd: .pipe, name: "x", from: "ghost", chain: "head(1)")
        let resp = try Client.sendRequest(req, socketPath: sockPath, timeout: 5)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error?.code, WireErrorCode.noSuchDataFrame)
    }
}
