import Foundation

/// Filesystem locations used by the resident-memory daemon.
///
/// Default layout:
///
///     ~/.swiftpandas/        runtime dir, mode 0700
///     ├── sock               Unix-domain socket, mode 0600
///     ├── pid                pid file, mode 0600
///     └── log                background-mode log
///
/// Each of those paths can be overridden via env so tests (and `brew services`)
/// can isolate the daemon to a private directory:
///
///   - `SWIFTPANDAS_RUNTIME_DIR`  overrides the parent directory.
///   - `SWIFTPANDAS_SOCK`         overrides the socket path directly.
///   - `SWIFTPANDAS_PIDFILE`      overrides the pid-file path directly.
///
/// `socketPath()` and `pidFilePath()` call ``ensureRuntimeDir()`` only when no
/// direct override is set — overridden paths are returned verbatim so the
/// caller (or test) controls the parent dir lifecycle.
public enum Paths {
    public enum PathsError: Error, Equatable {
        /// macOS `sockaddr_un.sun_path` is 104 bytes including the NUL
        /// terminator, so the socket path may be at most 103 bytes.
        case socketPathTooLong(path: String, maxLength: Int)
    }

    /// Maximum UTF-8 byte length of a usable Unix-domain socket path on macOS.
    public static let maxSocketPathLength = 103

    /// Returns the resolved runtime directory **without** creating it.
    public static func runtimeDir() -> URL {
        if let override = env("SWIFTPANDAS_RUNTIME_DIR") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swiftpandas", isDirectory: true)
    }

    /// Returns the runtime directory, creating it (mode 0700) if missing.
    ///
    /// Idempotent — if the directory exists with looser permissions, this
    /// tightens them to 0700.
    @discardableResult
    public static func ensureRuntimeDir() throws -> URL {
        let dir = runtimeDir()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Returns the Unix-domain socket path, validating it fits in `sockaddr_un`.
    ///
    /// If `SWIFTPANDAS_SOCK` is set, that path is returned verbatim and the
    /// runtime dir is **not** created — the caller is responsible for its
    /// parent dir.
    public static func socketPath() throws -> String {
        if let override = env("SWIFTPANDAS_SOCK") {
            try validateSocketLength(override)
            return override
        }
        let dir = try ensureRuntimeDir()
        let path = dir.appendingPathComponent("sock").path
        try validateSocketLength(path)
        return path
    }

    /// Returns the pid-file path. If `SWIFTPANDAS_PIDFILE` is set, that path
    /// is returned verbatim without creating the default runtime dir.
    public static func pidFilePath() throws -> String {
        if let override = env("SWIFTPANDAS_PIDFILE") {
            return override
        }
        let dir = try ensureRuntimeDir()
        return dir.appendingPathComponent("pid").path
    }

    /// Default log path used when the daemon detaches in background mode and
    /// the user did not pass `--log`.
    public static func defaultLogPath() throws -> String {
        let dir = try ensureRuntimeDir()
        return dir.appendingPathComponent("log").path
    }

    // MARK: - Helpers

    private static func env(_ name: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[name], !v.isEmpty else {
            return nil
        }
        return v
    }

    private static func validateSocketLength(_ path: String) throws {
        if path.utf8.count > maxSocketPathLength {
            throw PathsError.socketPathTooLong(path: path, maxLength: maxSocketPathLength)
        }
    }
}
