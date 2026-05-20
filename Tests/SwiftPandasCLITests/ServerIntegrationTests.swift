import XCTest
import Foundation
@testable import SwiftPandasCLI

/// PR 4 integration tests — drives the entire `swiftpandas server` surface
/// via the actual CLI binary against a real background daemon.
///
/// Each test starts a fresh daemon with isolated `--socket` / `--pidfile`
/// paths and stops it in tearDown so tests don't collide.
final class ServerIntegrationTests: XCTestCase {

    private var tmpDir: URL!
    private var sockPath: String!
    private var pidPath: String!

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

    private var salesFixturePath: String {
        Bundle.module.url(forResource: "sales", withExtension: "csv", subdirectory: "Fixtures")!.path
    }

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sp-it-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        sockPath = tmpDir.appendingPathComponent("sock").path
        pidPath  = tmpDir.appendingPathComponent("pid").path
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: sockPath) {
            _ = try? Client.sendRequest(.init(cmd: .shutdown), socketPath: sockPath, timeout: 2)
        }
        Thread.sleep(forTimeInterval: 0.2)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Helpers

    @discardableResult
    private func cli(_ args: [String], timeout: TimeInterval = 15) -> (stdout: String, stderr: String, exit: Int32) {
        let p = Process()
        p.executableURL = binary
        // Always inject --socket / --pidfile so tests are isolated from any
        // real `~/.swiftpandas/`. `String!` properties need explicit unwrap
        // to make the array element type `String` (not `String?`).
        var full: [String] = args
        full.append("--socket"); full.append(sockPath!)
        if args.first == "server" {
            full.append("--pidfile"); full.append(pidPath!)
        }
        p.arguments = full
        let outPipe = Foundation.Pipe()
        let errPipe = Foundation.Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            XCTFail("launch failed: \(error)")
            return ("", "", -1)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning {
            p.terminate()
            p.waitUntilExit()
            XCTFail("CLI invocation timed out: \(args)")
        }
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, p.terminationStatus)
    }

    private func startDaemon() throws {
        let (_, stderr, exit) = cli(["server", "start"])
        XCTAssertEqual(exit, 0, "server start failed: \(stderr)")
    }

    // MARK: - Full round trip

    func test_load_pipe_save_drop_roundTrip() throws {
        try startDaemon()

        let (loadOut, _, loadExit) = cli(["load", salesFixturePath, "--name", "sales"])
        XCTAssertEqual(loadExit, 0)
        XCTAssertTrue(loadOut.contains("sales"))

        let (listOut, _, _) = cli(["list"])
        XCTAssertTrue(listOut.contains("sales"), "list output: \(listOut)")

        let (pipeOut, _, pipeExit) = cli([
            "pipe", "--from", "sales", "--name", "big",
            "-c", "filter(revenue > 10000)",
        ])
        XCTAssertEqual(pipeExit, 0)
        XCTAssertTrue(pipeOut.contains("big"), "pipe output: \(pipeOut)")

        let outPath = tmpDir.appendingPathComponent("out.csv").path
        let (_, _, saveExit) = cli(["save", "big", outPath])
        XCTAssertEqual(saveExit, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outPath))

        // Saved file should parse and have a header + at least one data row.
        let savedCSV = try String(contentsOfFile: outPath, encoding: .utf8)
        XCTAssertTrue(savedCSV.hasPrefix("region,quarter"), "saved CSV: \(savedCSV.prefix(100))")
        XCTAssertGreaterThan(savedCSV.split(separator: "\n").count, 1)

        let (_, _, dropExit) = cli(["drop", "sales"])
        XCTAssertEqual(dropExit, 0)
        let (listOut2, _, _) = cli(["list"])
        XCTAssertFalse(listOut2.contains("sales"))
        XCTAssertTrue(listOut2.contains("big"))
    }

    // MARK: - Error paths

    func test_pipe_unknownDataframe_exitsThree() throws {
        try startDaemon()
        let (_, stderr, exit) = cli([
            "pipe", "--from", "ghost", "--name", "x",
            "-c", "head(1)",
        ])
        XCTAssertEqual(exit, 3)
        XCTAssertTrue(stderr.contains("no dataframe bound") || stderr.contains("ghost"),
                      "stderr: \(stderr)")
    }

    func test_save_unknownDataframe_exitsThree() throws {
        try startDaemon()
        let outPath = tmpDir.appendingPathComponent("nowhere.csv").path
        let (_, _, exit) = cli(["save", "ghost", outPath])
        XCTAssertEqual(exit, 3)
    }

    func test_drop_unknownDataframe_exitsThree() throws {
        try startDaemon()
        let (_, _, exit) = cli(["drop", "ghost"])
        XCTAssertEqual(exit, 3)
    }

    func test_load_missingFile_exitsThree() throws {
        try startDaemon()
        let (_, stderr, exit) = cli(["load", "/no/such/file.csv", "--name", "x"])
        XCTAssertEqual(exit, 3)
        XCTAssertTrue(stderr.contains("not found") || stderr.contains("io") || stderr.contains("File"),
                      "stderr: \(stderr)")
    }

    // MARK: - List

    func test_list_emptyDaemon_printsNoDataframesMessage() throws {
        try startDaemon()
        let (stdout, _, exit) = cli(["list"])
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(stdout.contains("no resident dataframes"), "stdout: \(stdout)")
    }

    // MARK: - Rebind warning

    func test_load_rebind_surfacesWarning() throws {
        try startDaemon()
        _ = cli(["load", salesFixturePath, "--name", "s"])
        let (_, stderr, exit) = cli(["load", salesFixturePath, "--name", "s"])
        XCTAssertEqual(exit, 0)
        XCTAssertTrue(stderr.contains("overwrote") || stderr.contains("warning"),
                      "expected overwrite warning in stderr: \(stderr)")
    }

    // MARK: - Show

    func test_show_returnsCSVPreview() throws {
        try startDaemon()
        _ = cli(["load", salesFixturePath, "--name", "s"])
        let (stdout, _, exit) = cli(["show", "s", "--head", "3"])
        XCTAssertEqual(exit, 0)
        let lines = stdout.split(separator: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 4) // header + 3 rows
    }

    // MARK: - Concurrent loads

    func test_concurrentLoads_allLand() throws {
        try startDaemon()
        // Stagger 6 concurrent loads under distinct names.
        let group = DispatchGroup()
        var exits = [Int32](repeating: -1, count: 6)
        let lock = NSLock()
        for i in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                let (_, _, exit) = self.cli(["load", self.salesFixturePath, "--name", "df\(i)"])
                lock.lock(); exits[i] = exit; lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 15), .success)
        XCTAssertTrue(exits.allSatisfy { $0 == 0 }, "exits: \(exits)")

        let (listOut, _, _) = cli(["list"])
        for i in 0..<6 {
            XCTAssertTrue(listOut.contains("df\(i)"), "list missing df\(i):\n\(listOut)")
        }
    }
}
