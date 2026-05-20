import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns the daemon's pid file on disk.
///
/// `acquire(pid:)` writes the given pid (default: this process) atomically with
/// mode 0600. It distinguishes three states of an existing pid file:
///
/// 1. **No file** → write and return cleanly.
/// 2. **Stale file** (pid not alive) → unlink it and throw
///    ``PIDFileError/staleCleaned(previousPID:)`` so the caller can log a
///    warning then retry. Calling `acquire` a second time after that error
///    succeeds.
/// 3. **Live duplicate** (pid alive, kill(pid,0)==0 or EPERM) → throw
///    ``PIDFileError/aliveDuplicate(pid:)`` so `server start` can map to
///    exit code 5.
///
/// `release()` unlinks the file; missing-file is tolerated because `atexit`
/// and signal handlers may race.
public struct PIDFile {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public enum PIDFileError: Error, Equatable {
        /// A live process already holds this pid file.
        case aliveDuplicate(pid: Int32)
        /// A stale pid file (process no longer alive) was unlinked. Retry to
        /// complete the acquire.
        case staleCleaned(previousPID: Int32)
        /// Underlying I/O failure with errno-derived message.
        case ioFailure(String)
    }

    /// Try to write `pid` to disk atomically.
    ///
    /// - Throws ``PIDFileError/aliveDuplicate`` if another live process owns
    ///   the file.
    /// - Throws ``PIDFileError/staleCleaned`` after cleaning up a dead-process
    ///   pid file; retry succeeds.
    public func acquire(pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            if let existing = try? readPID() {
                if existing == pid {
                    // We already own it — idempotent.
                    return
                }
                if PIDFile.isAlive(existing) {
                    throw PIDFileError.aliveDuplicate(pid: existing)
                }
                // Stale: clean up but defer re-acquire to the caller.
                unlink(path)
                throw PIDFileError.staleCleaned(previousPID: existing)
            }
            // Existed but unreadable — best-effort cleanup, then write.
            unlink(path)
        }
        try writeAtomic(pid: pid)
    }

    /// Release the file. Tolerates ENOENT (atexit/signal races).
    public func release() {
        unlink(path)
    }

    /// Return the pid currently recorded in the file, or `nil` if the file
    /// is absent or malformed.
    public func readPID() throws -> Int32? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Return `true` if a process with `pid` is currently alive (or exists but
    /// is owned by another user). Returns `false` only when `ESRCH` confirms
    /// no such process.
    public static func isAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        let result = kill(pid, 0)
        if result == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Atomic write

    private func writeAtomic(pid: Int32) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let tempPath = (parent as NSString).appendingPathComponent(".swiftpandas-pid-\(UUID().uuidString)")
        let contents = "\(pid)\n"
        let bytes = Array(contents.utf8)

        let fd = open(tempPath, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else {
            throw PIDFileError.ioFailure("open(\(tempPath)) failed: errno \(errno)")
        }
        let written = bytes.withUnsafeBufferPointer { buf in
            write(fd, buf.baseAddress, bytes.count)
        }
        close(fd)
        if written != bytes.count {
            unlink(tempPath)
            throw PIDFileError.ioFailure("partial write to \(tempPath): wrote \(written) of \(bytes.count)")
        }
        if rename(tempPath, path) != 0 {
            unlink(tempPath)
            throw PIDFileError.ioFailure("rename(\(tempPath), \(path)) failed: errno \(errno)")
        }
    }
}
