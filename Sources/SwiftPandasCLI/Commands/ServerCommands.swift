import ArgumentParser
import Foundation

/// Parent command for the resident-memory daemon.
///
///   swiftpandas server start [--foreground]
///   swiftpandas server stop
///   swiftpandas server status
///
/// `start` (default) spawns a detached background daemon and returns once
/// it's accept-ready. `start --foreground` blocks the current process
/// running the daemon directly (useful under `brew services` or for
/// debugging). `stop` sends a wire-level `shutdown`. `status` reports the
/// daemon's pid, uptime, dataframe count, and total bytes.
struct Server: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Manage the resident-memory dataframe daemon.",
        subcommands: [Start.self, Stop.self, Status.self],
        defaultSubcommand: nil
    )

    // MARK: - start

    struct Start: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start the resident dataframe daemon."
        )

        @Flag(name: .long, help: "Run in the foreground (do not detach). Useful for brew services and debugging.")
        var foreground: Bool = false

        @Option(name: .long, help: "Unix-domain socket path. Defaults to ~/.swiftpandas/sock.")
        var socket: String?

        @Option(name: .long, help: "Pid file path. Defaults to ~/.swiftpandas/pid.")
        var pidfile: String?

        @Option(name: .long, help: "Log file path (background mode). Defaults to /dev/null.")
        var log: String?

        func run() throws {
            let socketPath: String
            let pidFilePath: String
            do {
                socketPath = try (socket ?? Paths.socketPath())
                pidFilePath = try (pidfile ?? Paths.pidFilePath())
            } catch {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to resolve paths: \(error)")
                throw ExitCode(ServerExit.spawnFailed.rawValue)
            }

            let options = Daemon.Options(
                socketPath: socketPath,
                pidFilePath: pidFilePath,
                logPath: log,
                foreground: foreground
            )

            if foreground {
                // Hands control to the daemon's accept loop forever. Never
                // returns — exits via signal or wire-level shutdown.
                Daemon.runForeground(options)
            }

            // Background mode: re-exec self with --foreground, wait until ready, exit 0.
            do {
                try Daemon.spawnBackground(options)
                logStderr("\(Style.green)swiftpandas:\(Style.reset) daemon started (socket \(socketPath))")
                logStderr("            Run \(Style.bold)swiftpandas server status\(Style.reset) to see resident dataframes,")
                logStderr("            or \(Style.bold)swiftpandas server stop\(Style.reset) to shut it down.")
            } catch Daemon.SpawnError.aliveDuplicate(let pid) {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon already running (pid \(pid))")
                throw ExitCode(ServerExit.alreadyRunning.rawValue)
            } catch Daemon.SpawnError.readyTimeout {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon did not become ready within 2 s")
                if let log = log {
                    logStderr("            Check \(log) for clues.")
                }
                throw ExitCode(ServerExit.spawnFailed.rawValue)
            } catch Daemon.SpawnError.childExitedDuringStartup {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon exited during startup")
                if let log = log {
                    logStderr("            Check \(log) for clues.")
                }
                throw ExitCode(ServerExit.spawnFailed.rawValue)
            } catch Daemon.SpawnError.spawn(let msg) {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to spawn daemon: \(msg)")
                throw ExitCode(ServerExit.spawnFailed.rawValue)
            } catch {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to start daemon: \(error)")
                throw ExitCode(ServerExit.spawnFailed.rawValue)
            }
        }
    }

    // MARK: - stop

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop the running daemon, if any."
        )

        @Option(name: .long, help: "Unix-domain socket path. Defaults to ~/.swiftpandas/sock.")
        var socket: String?

        @Option(name: .long, help: "Seconds to wait for the daemon to acknowledge shutdown.")
        var timeout: Double = 5.0

        func run() throws {
            let socketPath: String
            do {
                socketPath = try (socket ?? Paths.socketPath())
            } catch {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to resolve socket path: \(error)")
                throw ExitCode(ServerExit.transportError.rawValue)
            }

            do {
                let resp = try Client.sendRequest(
                    .init(cmd: .shutdown),
                    socketPath: socketPath,
                    timeout: timeout
                )
                if resp.ok, case .shutdown(let pid) = resp.data {
                    logStderr("\(Style.green)swiftpandas:\(Style.reset) daemon stopped (pid \(pid))")
                    return
                }
                if let err = resp.error {
                    logStderr("\(Style.red)swiftpandas:\(Style.reset) \(err.message)")
                }
                throw ExitCode(ServerExit.serverError.rawValue)
            } catch Client.ClientError.notRunning {
                logStderr("\(Style.yellow)swiftpandas:\(Style.reset) no server running")
                throw ExitCode(ServerExit.notRunning.rawValue)
            } catch Client.ClientError.timeout {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon did not respond within \(timeout)s")
                throw ExitCode(ServerExit.transportError.rawValue)
            } catch is Client.ClientError {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) transport error talking to daemon")
                throw ExitCode(ServerExit.transportError.rawValue)
            }
        }
    }

    // MARK: - status

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Print daemon process and dataframe statistics."
        )

        @Option(name: .long, help: "Unix-domain socket path. Defaults to ~/.swiftpandas/sock.")
        var socket: String?

        @Option(name: .long, help: "Seconds to wait for a reply.")
        var timeout: Double = 5.0

        func run() throws {
            let socketPath: String
            do {
                socketPath = try (socket ?? Paths.socketPath())
            } catch {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to resolve socket path: \(error)")
                throw ExitCode(ServerExit.transportError.rawValue)
            }

            do {
                let resp = try Client.sendRequest(
                    .init(cmd: .status),
                    socketPath: socketPath,
                    timeout: timeout
                )
                guard resp.ok, case .status(let pid, let uptime, let dfCount, let totalBytes, let sock) = resp.data else {
                    if let err = resp.error {
                        logStderr("\(Style.red)swiftpandas:\(Style.reset) \(err.message)")
                    }
                    throw ExitCode(ServerExit.serverError.rawValue)
                }
                print("")
                print("  \(Style.bold)swiftpandas server\(Style.reset)")
                print("    \(Style.cyan)pid\(Style.reset)        \(Style.dim)│\(Style.reset) \(pid)")
                print("    \(Style.cyan)uptime\(Style.reset)     \(Style.dim)│\(Style.reset) \(formatTime(uptime))")
                print("    \(Style.cyan)socket\(Style.reset)     \(Style.dim)│\(Style.reset) \(sock)")
                print("    \(Style.cyan)dataframes\(Style.reset) \(Style.dim)│\(Style.reset) \(dfCount)")
                print("    \(Style.cyan)memory\(Style.reset)     \(Style.dim)│\(Style.reset) \(formatBytes(totalBytes))")
                print("")
            } catch Client.ClientError.notRunning {
                logStderr("\(Style.yellow)swiftpandas:\(Style.reset) no server running")
                throw ExitCode(ServerExit.notRunning.rawValue)
            } catch Client.ClientError.timeout {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon did not respond within \(timeout)s")
                throw ExitCode(ServerExit.transportError.rawValue)
            } catch is Client.ClientError {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) transport error talking to daemon")
                throw ExitCode(ServerExit.transportError.rawValue)
            }
        }
    }
}

/// Stable exit codes for the server subcommand family. These match the
/// contract laid out in [docs/SERVER.md](../../../docs/SERVER.md) so that
/// scripts can branch on them deterministically.
enum ServerExit: Int32 {
    case ok = 0
    case notRunning = 2          // socket missing / ECONNREFUSED
    case serverError = 3         // ok:false from daemon
    case transportError = 4      // timeout / bad reply
    case alreadyRunning = 5      // server start with live pid
    case spawnFailed = 6         // server start could not spawn daemon
}
