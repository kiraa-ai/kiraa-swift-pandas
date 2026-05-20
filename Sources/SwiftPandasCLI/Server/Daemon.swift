import Foundation
import SwiftPandas
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Long-lived background process that owns the in-memory `DataFrameRegistry`
/// and serves wire requests over a Unix-domain socket.
///
/// PR 2 implements only the **foreground** path: the daemon is started by
/// `swiftpandas server start --foreground`, blocks the calling process, and
/// exits on SIGTERM/SIGINT/SIGHUP or on a wire-level `shutdown` request.
/// PR 3 will add the background-detach path (`spawnBackground`).
public enum Daemon {

    /// Options passed to the daemon by the launcher. Mostly path overrides
    /// (defaults come from ``Paths``).
    public struct Options: Sendable {
        public var socketPath: String
        public var pidFilePath: String
        public var logPath: String?
        public var foreground: Bool

        public init(
            socketPath: String,
            pidFilePath: String,
            logPath: String? = nil,
            foreground: Bool = true
        ) {
            self.socketPath = socketPath
            self.pidFilePath = pidFilePath
            self.logPath = logPath
            self.foreground = foreground
        }
    }

    /// Start the daemon in the current process and block forever. Returns
    /// only by calling `exit(_:)` from a signal handler or a wire-level
    /// `shutdown` command.
    ///
    /// Exit codes:
    ///   - `0` clean shutdown (signal or shutdown command)
    ///   - `5` another live daemon already holds the pid file
    ///   - `6` listener failed to bind, or pid file write failed
    public static func runForeground(_ options: Options) -> Never {
        // If we were re-exec'd by spawnBackground, detach from the parent's
        // terminal session so closing the terminal doesn't SIGHUP us.
        // setsid() may legitimately fail with EPERM if we're already a
        // session leader (e.g. when launchd started us); that's fine.
        if ProcessInfo.processInfo.environment["SWIFTPANDAS_DAEMON"] == "1" {
            _ = setsid()
        }

        let state = DaemonState.shared
        state.socketPath = options.socketPath
        state.pidPath = options.pidFilePath
        state.startedAt = Date()

        // 1. Acquire pid file (with stale retry).
        let pidFile = PIDFile(path: options.pidFilePath)
        do {
            try pidFile.acquire()
        } catch PIDFile.PIDFileError.staleCleaned(let prev) {
            logStderr("\(Style.yellow)swiftpandas:\(Style.reset) cleaned up stale pid file (was pid \(prev))")
            do {
                try pidFile.acquire()
            } catch {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to acquire pid file after stale cleanup: \(error)")
                exit(6)
            }
        } catch PIDFile.PIDFileError.aliveDuplicate(let pid) {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon already running (pid \(pid))")
            exit(5)
        } catch {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to acquire pid file: \(error)")
            exit(6)
        }

        // 2. Best-effort cleanup on every exit path (atexit is signal-safe;
        //    signal handlers may also have fired and called exit already).
        atexit { DaemonState.shared.cleanup() }

        // 3. Signal handlers. SIGTERM/SIGINT/SIGHUP -> clean exit.
        installSignalHandlers()

        // 4. Start the accept loop on a detached Task. The Task survives for
        //    the life of the process because dispatchMain() pins the main
        //    queue and the Task runs on a global executor.
        Task.detached {
            await serverLoop(options, state: state)
        }

        logStderr("\(Style.green)swiftpandas:\(Style.reset) daemon listening on \(options.socketPath) (pid \(ProcessInfo.processInfo.processIdentifier))")

        // 5. Block forever. dispatchMain processes signal sources installed
        //    above and never returns.
        dispatchMain()
    }

    // MARK: - Accept loop

    private static func serverLoop(_ options: Options, state: DaemonState) async {
        let registry = DataFrameRegistry()
        state.registry = registry

        do {
            let listener = try await Transport.listen(socketPath: options.socketPath) { conn in
                await handleConnection(conn, registry: registry, socketPath: options.socketPath)
            }
            state.listener = listener
        } catch {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) listener failed: \(error)")
            exit(6)
        }
    }

    /// Single-shot connection handler: read one frame, dispatch, write reply,
    /// close. For shutdown commands, exits the process after the reply is
    /// flushed.
    private static func handleConnection(
        _ conn: Transport.Connection,
        registry: DataFrameRegistry,
        socketPath: String
    ) async {
        defer {
            Task { await conn.close() }
        }

        let frame: Data
        do {
            frame = try await conn.receiveLine()
        } catch {
            // Client disconnected before sending a frame. Common, not worth logging.
            return
        }

        let req: WireRequest
        do {
            req = try WireFrame.decode(WireRequest.self, from: frame)
        } catch {
            let resp = WireResponse.failure(
                id: "?",
                WireError(code: WireErrorCode.proto, message: "malformed request: \(error)")
            )
            _ = try? await conn.send(WireFrame.encode(resp))
            return
        }

        let resp = await Handlers.dispatch(req, registry: registry, socketPath: socketPath)
        do {
            try await conn.send(WireFrame.encode(resp))
        } catch {
            // Best-effort: client may have disconnected after sending request.
            return
        }

        // Honor a successful shutdown reply by terminating after a brief
        // flush window. Close the listener FIRST so any follow-up client
        // (e.g. a quick `status` right after `stop`) gets `.notRunning`
        // instead of racing onto an about-to-die daemon. Then explicitly
        // unlink the runtime files — atexit also unlinks them, but in
        // practice Swift's concurrency teardown can race past atexit.
        if req.cmd == .shutdown, resp.ok {
            DaemonState.shared.listener?.close()
            try? await Task.sleep(nanoseconds: 100_000_000) // 100 ms flush window
            DaemonState.shared.cleanup()
            exit(0)
        }
    }

    // MARK: - Background spawn

    /// Errors surfaced to `Server.Start.run()` for accurate exit codes.
    public enum SpawnError: Error, Equatable {
        case aliveDuplicate(pid: Int32)
        case readyTimeout
        case childExitedDuringStartup
        case spawn(String)
    }

    /// Re-exec the current binary with `--foreground` and wait until the
    /// daemon is accept-ready, then return so the launcher can exit cleanly.
    /// The child is given a new session via ``runForeground``'s `setsid()` so
    /// closing the terminal won't SIGHUP it.
    public static func spawnBackground(_ options: Options) throws {
        // Pre-check: refuse if a live daemon already owns the pid file.
        if FileManager.default.fileExists(atPath: options.pidFilePath) {
            let pf = PIDFile(path: options.pidFilePath)
            // `try?` on a `throws -> Int32?` flattens to `Int32?`, so a single
            // `if let` unwraps the live-pid value.
            if let pid = try? pf.readPID(), PIDFile.isAlive(pid) {
                throw SpawnError.aliveDuplicate(pid: pid)
            }
            // Stale — runForeground will clean it up after exec.
        }

        // Resolve our own binary path (CommandLine.arguments[0] is what the
        // shell exec'd us as; resolve symlinks for a stable re-exec path).
        let selfPath = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .path

        let child = Process()
        child.executableURL = URL(fileURLWithPath: selfPath)
        var args = [
            "server", "start", "--foreground",
            "--socket", options.socketPath,
            "--pidfile", options.pidFilePath,
        ]
        if let log = options.logPath {
            args.append(contentsOf: ["--log", log])
        }
        child.arguments = args

        // Detach stdio. Use /dev/null for stdin always; redirect stdout/stderr
        // to the log file if provided, else /dev/null.
        let nullURL = URL(fileURLWithPath: "/dev/null")
        child.standardInput = try FileHandle(forReadingFrom: nullURL)
        if let logPath = options.logPath {
            // Create or append; mode 0600 so log secrets aren't world-readable.
            let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            guard fd >= 0 else {
                throw SpawnError.spawn("could not open log file '\(logPath)': errno \(errno)")
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            child.standardOutput = handle
            child.standardError = handle
        } else {
            child.standardOutput = try FileHandle(forWritingTo: nullURL)
            child.standardError = try FileHandle(forWritingTo: nullURL)
        }

        // Marker so the child knows to call setsid() at the top of runForeground.
        var env = ProcessInfo.processInfo.environment
        env["SWIFTPANDAS_DAEMON"] = "1"
        child.environment = env

        do {
            try child.run()
        } catch {
            throw SpawnError.spawn("\(error)")
        }

        // Poll for readiness: pid file exists AND status round trip succeeds.
        // 2 s budget covers Network.framework setup latency on cold caches.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if !child.isRunning {
                throw SpawnError.childExitedDuringStartup
            }
            if FileManager.default.fileExists(atPath: options.pidFilePath),
               FileManager.default.fileExists(atPath: options.socketPath),
               let resp = try? Client.sendRequest(
                   .init(cmd: .status),
                   socketPath: options.socketPath,
                   timeout: 0.3
               ),
               resp.ok {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SpawnError.readyTimeout
    }

    // MARK: - Signal handlers

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        for sig in signals {
            // Ignore default disposition so DispatchSource sees it.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                logStderr("\(Style.yellow)swiftpandas:\(Style.reset) received signal \(sig), shutting down")
                DaemonState.shared.listener?.close()
                DaemonState.shared.cleanup()
                exit(0)
            }
            source.resume()
            DaemonState.shared.signalSources.append(source)
        }
    }
}

// MARK: - Shared state

/// Singleton holding daemon-wide state visible to `atexit` (which is
/// signal-safe but cannot touch Swift actors) and the signal handlers.
///
/// `@unchecked Sendable` is safe because: (1) the only mutation happens
/// before the accept loop spawns its first connection, and (2) cleanup
/// reads only via raw `unlink` which doesn't observe partial writes.
final class DaemonState: @unchecked Sendable {
    static let shared = DaemonState()

    var socketPath: String = ""
    var pidPath: String = ""
    var startedAt: Date = Date()
    var listener: Transport.Listener?
    var registry: DataFrameRegistry?
    var signalSources: [DispatchSourceSignal] = []

    /// Called from `atexit`. Must use only async-signal-safe primitives.
    func cleanup() {
        if !socketPath.isEmpty { unlink(socketPath) }
        if !pidPath.isEmpty    { unlink(pidPath) }
    }
}
