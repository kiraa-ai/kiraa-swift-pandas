import XCTest
import Foundation
@testable import SwiftPandasCLI

/// PR 3 integration tests — exercises the **background** spawn path: a
/// `swiftpandas server start` (without `--foreground`) re-execs itself,
/// detaches, returns exit 0, and the daemon process keeps running.
///
/// Each test runs `swiftpandas server start --socket … --pidfile …` as a
/// subprocess, waits for it to exit (it should within a couple seconds), then
/// verifies the orphaned daemon is alive, replies to wire requests, and
/// shuts down on `swiftpandas server stop`.
final class BackgroundDaemonTests: XCTestCase {

    private var tmpDir: URL!
    private var sockPath: String!
    private var pidPath: String!
    private var logPath: String!

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
        tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sp-bg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        sockPath = tmpDir.appendingPathComponent("sock").path
        pidPath  = tmpDir.appendingPathComponent("pid").path
        logPath  = tmpDir.appendingPathComponent("log").path
    }

    override func tearDownWithError() throws {
        // Always best-effort stop in case a test left a daemon running.
        if FileManager.default.fileExists(atPath: sockPath) {
            _ = try? Client.sendRequest(.init(cmd: .shutdown), socketPath: sockPath, timeout: 2)
        }
        // Give the daemon a moment to unlink files.
        Thread.sleep(forTimeInterval: 0.2)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func runCLI(_ args: [String], timeout: TimeInterval = 10) -> (stdout: String, stderr: String, exit: Int32) {
        let p = Process()
        p.executableURL = binary
        p.arguments = args
        let outPipe = Foundation.Pipe()
        let errPipe = Foundation.Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            XCTFail("failed to launch: \(error)")
            return ("", "", -1)
        }
        // Bounded wait; the background spawn path returns within ~100 ms.
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            XCTFail("CLI invocation exceeded \(timeout)s for args: \(args)")
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, p.terminationStatus)
    }

    /// Wait until both the socket and pid file are unlinked, up to 2 s.
    /// The shutdown handler unlinks the socket immediately and the pid
    /// file ~100 ms later, so a single-file wait misses the second one.
    private func waitForCleanup(timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: sockPath),
               !FileManager.default.fileExists(atPath: pidPath) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func startBackgroundDaemon() throws {
        let (_, stderr, exit) = runCLI([
            "server", "start",
            "--socket", sockPath,
            "--pidfile", pidPath,
            "--log", logPath,
        ])
        XCTAssertEqual(exit, 0, "server start failed; stderr:\n\(stderr)")
        XCTAssertTrue(stderr.contains("daemon started"), "stderr: \(stderr)")
    }

    // MARK: - Background spawn

    func test_serverStart_default_isBackgroundAndReturns() throws {
        try startBackgroundDaemon()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidPath))

        let pf = PIDFile(path: pidPath)
        let daemonPID = try pf.readPID()
        XCTAssertNotNil(daemonPID)
        XCTAssertTrue(PIDFile.isAlive(daemonPID!), "spawned daemon must outlive the launcher")
    }

    func test_serverStart_alreadyRunning_exitsFive() throws {
        try startBackgroundDaemon()
        let (_, stderr, exit) = runCLI([
            "server", "start",
            "--socket", sockPath,
            "--pidfile", pidPath,
        ])
        XCTAssertEqual(exit, 5)
        XCTAssertTrue(stderr.contains("already running"), "stderr: \(stderr)")
    }

    func test_serverStart_stalePidFile_isCleanedUp() throws {
        // Pre-write a fake pid that's definitely not alive.
        try "99999999\n".write(toFile: pidPath, atomically: true, encoding: .utf8)
        try startBackgroundDaemon()
        // The daemon should have replaced the stale pid with its own.
        let pf = PIDFile(path: pidPath)
        XCTAssertNotEqual(try pf.readPID(), 99_999_999)
    }

    // MARK: - server stop

    func test_serverStop_running_succeeds() throws {
        try startBackgroundDaemon()
        let (_, stderr, exit) = runCLI([
            "server", "stop",
            "--socket", sockPath,
        ])
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(stderr.contains("daemon stopped"), "stderr: \(stderr)")

        waitForCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath))
    }

    func test_serverStop_noDaemon_exitsTwo() {
        let (_, stderr, exit) = runCLI([
            "server", "stop",
            "--socket", sockPath,
        ])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"))
    }

    // MARK: - server status

    func test_serverStatus_running_prettyPrints() throws {
        try startBackgroundDaemon()
        let (stdout, _, exit) = runCLI([
            "server", "status",
            "--socket", sockPath,
        ])
        XCTAssertEqual(exit, 0)
        for needle in ["pid", "uptime", "socket", "dataframes", "memory"] {
            XCTAssertTrue(stdout.contains(needle), "expected '\(needle)' in stdout:\n\(stdout)")
        }
    }

    func test_serverStatus_noDaemon_exitsTwo() {
        let (_, stderr, exit) = runCLI([
            "server", "status",
            "--socket", sockPath,
        ])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"))
    }

    // MARK: - Lifecycle round trip

    func test_startStop_roundTrip_leavesNoFilesBehind() throws {
        try startBackgroundDaemon()
        let (_, _, exit) = runCLI(["server", "stop", "--socket", sockPath])
        XCTAssertEqual(exit, 0)

        waitForCleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidPath))
    }
}
