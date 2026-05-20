import XCTest
import Foundation
@testable import SwiftPandasCLI

/// Unit tests for `Transport`. These run a real `NWListener` on a temp
/// Unix-domain socket so they exercise the same Network.framework code path
/// the daemon will use in PR 2.
///
/// Each test isolates itself to a unique socket path under `$TMPDIR` so
/// concurrent test runs don't collide.
final class TransportTests: XCTestCase {

    private var sockPath: String!

    override func setUpWithError() throws {
        // Use /tmp instead of $TMPDIR — the latter is often >> 103 chars on
        // CI/Xcode workers and would blow Paths.maxSocketPathLength.
        sockPath = "/tmp/sp-test-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDownWithError() throws {
        if let p = sockPath { unlink(p) }
    }

    // MARK: - Happy path

    func test_listenAndDial_roundTripOneLine() async throws {
        let listener = try await Transport.listen(socketPath: sockPath) { conn in
            do {
                let line = try await conn.receiveLine()
                try await conn.send(line)        // echo back verbatim
            } catch {
                XCTFail("server handler error: \(error)")
            }
            await conn.close()
        }
        defer { listener.close() }

        let client = try await Transport.dial(socketPath: sockPath, timeout: 2)
        try await client.send(Data("hello\n".utf8))
        let reply = try await client.receiveLine()
        XCTAssertEqual(reply, Data("hello\n".utf8))
        await client.close()
    }

    func test_receiveLine_includesNewlineTerminator() async throws {
        let listener = try await Transport.listen(socketPath: sockPath) { conn in
            try? await conn.send(Data("abc\n".utf8))
            await conn.close()
        }
        defer { listener.close() }

        let client = try await Transport.dial(socketPath: sockPath, timeout: 2)
        defer { Task { await client.close() } }
        let line = try await client.receiveLine()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line, Data("abc\n".utf8))
    }

    func test_multipleFrames_overSingleConnection() async throws {
        let listener = try await Transport.listen(socketPath: sockPath) { conn in
            for _ in 0..<3 {
                guard let line = try? await conn.receiveLine() else { break }
                try? await conn.send(line)
            }
            await conn.close()
        }
        defer { listener.close() }

        let client = try await Transport.dial(socketPath: sockPath, timeout: 2)
        defer { Task { await client.close() } }
        for n in 0..<3 {
            try await client.send(Data("frame\(n)\n".utf8))
            let r = try await client.receiveLine()
            XCTAssertEqual(r, Data("frame\(n)\n".utf8))
        }
    }

    // MARK: - Error paths

    func test_dial_missingSocket_throwsNotRunning() async throws {
        let absent = "/tmp/sp-absent-\(UUID().uuidString.prefix(8)).sock"
        do {
            _ = try await Transport.dial(socketPath: absent, timeout: 1)
            XCTFail("expected .notRunning")
        } catch let e as Transport.TransportError {
            XCTAssertEqual(e, .notRunning, "got \(e)")
        }
    }

    func test_dial_emptyFileAtSocketPath_throwsNotRunning() async throws {
        // A regular file masquerading as a socket should fail to connect.
        // The kernel returns either ECONNREFUSED or ENOTSOCK; both map via
        // our error logic to .notRunning (ECONNREFUSED) or .underlying
        // (ENOTSOCK). We assert the dial fails — exact code is OS-specific.
        try Data().write(to: URL(fileURLWithPath: sockPath))
        do {
            _ = try await Transport.dial(socketPath: sockPath, timeout: 1)
            XCTFail("expected dial to fail against non-socket file")
        } catch is Transport.TransportError {
            // any TransportError is acceptable here — we just need failure
        }
    }

    // MARK: - chmod / cleanup

    func test_listen_chmodsSocketTo0600() async throws {
        let listener = try await Transport.listen(socketPath: sockPath) { _ in }
        defer { listener.close() }

        var st = stat()
        XCTAssertEqual(lstat(sockPath, &st), 0)
        // st_mode & 0777 isolates permission bits.
        let perms = Int(st.st_mode) & 0o777
        XCTAssertEqual(perms, 0o600, String(format: "expected 0600, got %o", perms))
    }

    func test_listener_close_unlinksSocketFile() async throws {
        let listener = try await Transport.listen(socketPath: sockPath) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))
        listener.close()
        // Give the cancel callback a moment to flush; close() unlinks
        // synchronously, so the file should be gone right away.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath))
    }

    func test_listen_reusesAfterStaleSocketFile() async throws {
        // Simulate a previous crashed daemon leaving a socket file behind.
        try Data().write(to: URL(fileURLWithPath: sockPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))

        let listener = try await Transport.listen(socketPath: sockPath) { _ in }
        defer { listener.close() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath))
    }
}
