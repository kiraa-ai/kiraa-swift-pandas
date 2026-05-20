import XCTest
import Foundation

/// Black-box tests of the `swiftpandas` binary's subcommand surface.
///
/// Phase 1 ships the CLI layout but not the IPC layer, so the DataFrame-aware
/// subcommands (`load`, `pipe`, `save`, `list`, `drop`, `show`, `server *`)
/// must exit with code 2 ("no server running") and a clear stderr message.
/// The one-shot legacy invocation (`swiftpandas -i ... -c ...`) must continue
/// to succeed via the `Run` default subcommand. Phase 2 will flip these to
/// real round-trip tests against a running daemon.
final class CLISubcommandTests: XCTestCase {

    // MARK: - Helpers

    /// Locate the `swiftpandas` binary built alongside this test bundle.
    private var binary: URL {
        let testBundleURL = Bundle.module.bundleURL
        // .build/.../debug/SwiftPandasCLITests.xctest/Contents/Resources → walk to debug/
        var dir = testBundleURL
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("swiftpandas")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("Could not locate built `swiftpandas` binary near \(testBundleURL.path)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private func fixturePath(_ name: String) -> String {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!.path
    }

    /// Invoke the CLI and capture (stdout, stderr, exitCode).
    private func runCLI(_ args: [String]) -> (stdout: String, stderr: String, exit: Int32) {
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do { try proc.run() } catch {
            XCTFail("Failed to launch \(binary.path): \(error)")
            return ("", "", -1)
        }
        proc.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, proc.terminationStatus)
    }

    // MARK: - Legacy one-shot mode must still work

    func test_oneShot_legacyFlags_succeed() {
        let (stdout, _, exit) = runCLI([
            "-i", fixturePath("sales.csv"),
            "-c", "filter(revenue > 10000) | head(2)"
        ])
        XCTAssertEqual(exit, 0, "legacy one-shot CLI invocation must continue to succeed")
        XCTAssertTrue(stdout.contains("revenue"), "stdout should contain CSV header. got:\n\(stdout)")
    }

    func test_oneShot_runSubcommand_works() {
        let (stdout, _, exit) = runCLI([
            "run",
            "-i", fixturePath("sales.csv"),
            "-c", "head(1)"
        ])
        XCTAssertEqual(exit, 0)
        XCTAssertFalse(stdout.isEmpty)
    }

    // MARK: - Phase 1 stub contract: server-aware subcommands exit 2

    func test_list_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["list"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_load_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["load", "/tmp/whatever.csv", "--name", "df1"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_pipe_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["pipe", "--from", "a", "--name", "b", "-c", "head(1)"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_save_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["save", "ghost", "/tmp/out.csv"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_drop_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["drop", "ghost"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_show_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["show", "ghost"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_serverStop_withoutServer_exitsTwo() {
        let (_, stderr, exit) = runCLI(["server", "stop"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_serverStop_withoutDaemon_exitsTwo() {
        let (_, stderr, exit) = runCLI(["server", "stop"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    func test_serverStatus_withoutDaemon_exitsTwo() {
        let (_, stderr, exit) = runCLI(["server", "status"])
        XCTAssertEqual(exit, 2)
        XCTAssertTrue(stderr.contains("no server running"), "stderr: \(stderr)")
    }

    // MARK: - Help surface advertises both modes

    func test_rootHelp_advertisesAllSubcommands() {
        let (stdout, _, exit) = runCLI(["--help"])
        XCTAssertEqual(exit, 0)
        for expected in ["run", "server", "load", "pipe", "save", "list", "drop", "show"] {
            XCTAssertTrue(stdout.contains(expected), "root --help should list subcommand '\(expected)'. got:\n\(stdout)")
        }
    }
}
