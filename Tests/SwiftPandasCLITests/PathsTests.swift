import XCTest
import Foundation
@testable import SwiftPandasCLI

/// Unit tests for `Paths`. These do not touch the user's real `~/.swiftpandas/`
/// — every test sets `SWIFTPANDAS_RUNTIME_DIR` or `SWIFTPANDAS_SOCK` to a
/// freshly-created temp dir and unsets it in tearDown.
final class PathsTests: XCTestCase {

    private var tmpRoot: URL!
    private let envKeys = ["SWIFTPANDAS_RUNTIME_DIR", "SWIFTPANDAS_SOCK", "SWIFTPANDAS_PIDFILE"]
    private var savedEnv: [String: String?] = [:]

    override func setUpWithError() throws {
        // Use /tmp (not $TMPDIR) because on macOS $TMPDIR resolves to
        // /var/folders/<long-hash>/T/... which alone is ~70 chars — once
        // prefixed to a "/sock" entry it exceeds the 103-byte
        // sockaddr_un.sun_path limit and `Paths.socketPath()` correctly
        // refuses. Tests need a short root.
        tmpRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("sp-paths-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        for key in envKeys {
            savedEnv[key] = ProcessInfo.processInfo.environment[key]
            unsetenv(key)
        }
    }

    override func tearDownWithError() throws {
        for (key, value) in savedEnv {
            if let value = value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
        savedEnv.removeAll()
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    // MARK: - runtimeDir / ensureRuntimeDir

    func test_runtimeDir_default_isUnderHome() {
        let dir = Paths.runtimeDir()
        XCTAssertTrue(dir.path.contains(".swiftpandas"))
        XCTAssertTrue(dir.path.hasPrefix(NSHomeDirectory()) || dir.path.contains("/Users/"),
                      "default runtime dir should be under home, got \(dir.path)")
    }

    func test_runtimeDir_envOverride_isVerbatim() {
        let override = tmpRoot.appendingPathComponent("custom-runtime").path
        setenv("SWIFTPANDAS_RUNTIME_DIR", override, 1)
        XCTAssertEqual(Paths.runtimeDir().path, override)
    }

    func test_ensureRuntimeDir_createsAt0700() throws {
        let override = tmpRoot.appendingPathComponent("created").path
        setenv("SWIFTPANDAS_RUNTIME_DIR", override, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: override))

        let dir = try Paths.ensureRuntimeDir()
        XCTAssertEqual(dir.path, override)
        XCTAssertTrue(FileManager.default.fileExists(atPath: override))

        let attrs = try FileManager.default.attributesOfItem(atPath: override)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o700, String(format: "expected 0700, got %o", perms))
    }

    func test_ensureRuntimeDir_isIdempotent() throws {
        let override = tmpRoot.appendingPathComponent("idem").path
        setenv("SWIFTPANDAS_RUNTIME_DIR", override, 1)
        let a = try Paths.ensureRuntimeDir()
        let b = try Paths.ensureRuntimeDir()
        XCTAssertEqual(a.path, b.path)
    }

    func test_ensureRuntimeDir_tightensLoosePermissions() throws {
        let override = tmpRoot.appendingPathComponent("loose").path
        try FileManager.default.createDirectory(atPath: override, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        setenv("SWIFTPANDAS_RUNTIME_DIR", override, 1)

        _ = try Paths.ensureRuntimeDir()
        let perms = ((try FileManager.default.attributesOfItem(atPath: override)[.posixPermissions]) as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o700, "ensureRuntimeDir should clamp loose perms to 0700")
    }

    // MARK: - socketPath / pidFilePath

    func test_socketPath_default_isUnderRuntimeDir() throws {
        let override = tmpRoot.appendingPathComponent("rt").path
        setenv("SWIFTPANDAS_RUNTIME_DIR", override, 1)
        let p = try Paths.socketPath()
        XCTAssertEqual(p, override + "/sock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: override), "default socketPath should create runtime dir")
    }

    func test_socketPath_envOverride_doesNotCreateParent() throws {
        // Point SWIFTPANDAS_RUNTIME_DIR at a non-existent subdir so we can
        // observe whether `socketPath()` creates it. Using the real
        // `~/.swiftpandas/` would be flaky — it might already exist on the
        // developer's machine from a previous daemon run.
        let runtime = tmpRoot.appendingPathComponent("would-be-runtime").path
        setenv("SWIFTPANDAS_RUNTIME_DIR", runtime, 1)

        let custom = tmpRoot.appendingPathComponent("explicit-sock").path
        setenv("SWIFTPANDAS_SOCK", custom, 1)

        XCTAssertEqual(try Paths.socketPath(), custom)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime),
                       "overridden SWIFTPANDAS_SOCK must not trigger runtime dir creation")
    }

    func test_pidFilePath_envOverride_isVerbatim() throws {
        let custom = tmpRoot.appendingPathComponent("explicit-pid").path
        setenv("SWIFTPANDAS_PIDFILE", custom, 1)
        XCTAssertEqual(try Paths.pidFilePath(), custom)
    }

    // MARK: - validation

    func test_socketPath_rejectsTooLong() throws {
        let huge = "/tmp/" + String(repeating: "x", count: 200)
        setenv("SWIFTPANDAS_SOCK", huge, 1)
        XCTAssertThrowsError(try Paths.socketPath()) { err in
            guard case Paths.PathsError.socketPathTooLong(_, let max) = err else {
                return XCTFail("expected PathsError.socketPathTooLong, got \(err)")
            }
            XCTAssertEqual(max, Paths.maxSocketPathLength)
        }
    }
}
