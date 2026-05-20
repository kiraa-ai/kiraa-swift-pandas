import XCTest
import Foundation
@testable import SwiftPandasCLI

/// Unit tests for `PIDFile`. Each test runs in an isolated temp directory so
/// failures don't leak between runs.
final class PIDFileTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftpandas-pid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func pidFile(_ name: String = "pid") -> PIDFile {
        PIDFile(path: tmp.appendingPathComponent(name).path)
    }

    // MARK: - acquire / release

    func test_acquireOnEmptyDir_writesPID() throws {
        let pf = pidFile()
        try pf.acquire(pid: 4711)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pf.path))
        XCTAssertEqual(try pf.readPID(), 4711)
    }

    func test_acquire_isAtomic_doesNotLeaveTempFile() throws {
        let pf = pidFile()
        try pf.acquire(pid: 4711)
        let contents = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        let strays = contents.filter { $0.hasPrefix(".swiftpandas-pid-") }
        XCTAssertTrue(strays.isEmpty, "temp files leaked: \(strays)")
    }

    func test_acquireSamePIDTwice_isIdempotent() throws {
        let pf = pidFile()
        let myPid = ProcessInfo.processInfo.processIdentifier
        try pf.acquire(pid: myPid)
        XCTAssertNoThrow(try pf.acquire(pid: myPid), "re-acquire by same pid must not throw")
    }

    func test_acquireLiveDuplicate_throwsAliveDuplicate() throws {
        let pf = pidFile()
        // Write the current process's pid as if another daemon owned it.
        let myPid = ProcessInfo.processInfo.processIdentifier
        try pf.acquire(pid: myPid)

        // Now try to acquire as a different (fictitious) pid — should refuse.
        let otherPid: Int32 = myPid + 1
        XCTAssertThrowsError(try pf.acquire(pid: otherPid)) { err in
            guard case PIDFile.PIDFileError.aliveDuplicate(let pid) = err else {
                return XCTFail("expected .aliveDuplicate, got \(err)")
            }
            XCTAssertEqual(pid, myPid)
        }
    }

    func test_acquireStalePID_cleansAndThrowsStaleCleaned() throws {
        let pf = pidFile()
        // Pre-write a pid that almost certainly isn't alive.
        let stalePid: Int32 = 99_999_999
        try "\(stalePid)\n".write(toFile: pf.path, atomically: true, encoding: .utf8)
        XCTAssertFalse(PIDFile.isAlive(stalePid))

        XCTAssertThrowsError(try pf.acquire(pid: 4711)) { err in
            guard case PIDFile.PIDFileError.staleCleaned(let prev) = err else {
                return XCTFail("expected .staleCleaned, got \(err)")
            }
            XCTAssertEqual(prev, stalePid)
        }
        // After the stale cleanup, file is gone. Caller can retry.
        XCTAssertFalse(FileManager.default.fileExists(atPath: pf.path))
        try pf.acquire(pid: 4711)
        XCTAssertEqual(try pf.readPID(), 4711)
    }

    func test_release_tolatesMissingFile() {
        let pf = pidFile("never-written")
        pf.release()      // must not throw / crash
        pf.release()      // repeated release is safe
    }

    func test_release_unlinks() throws {
        let pf = pidFile()
        try pf.acquire(pid: 4711)
        pf.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pf.path))
    }

    // MARK: - isAlive

    func test_isAlive_currentProcess_returnsTrue() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(PIDFile.isAlive(me))
    }

    func test_isAlive_invalidPID_returnsFalse() {
        XCTAssertFalse(PIDFile.isAlive(0))
        XCTAssertFalse(PIDFile.isAlive(-1))
        XCTAssertFalse(PIDFile.isAlive(99_999_999))
    }

    func test_readPID_missingFile_returnsNil() throws {
        let pf = pidFile("absent")
        XCTAssertNil(try pf.readPID())
    }

    // MARK: - permissions

    func test_acquire_writesMode0600() throws {
        let pf = pidFile()
        try pf.acquire(pid: 4711)
        let perms = ((try FileManager.default.attributesOfItem(atPath: pf.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms, 0o600, String(format: "expected 0600, got %o", perms))
    }
}
