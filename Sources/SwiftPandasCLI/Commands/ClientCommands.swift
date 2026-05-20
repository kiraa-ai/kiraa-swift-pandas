import ArgumentParser
import Foundation

/// DataFrame-aware subcommands. Each one builds a `WireRequest`, sends it
/// to the running daemon via `Client.sendRequest`, and pretty-prints the
/// reply.
///
/// All client subcommands share:
///   - `--socket <path>` — Unix-domain socket path (defaults via `Paths`)
///   - `--timeout <s>`   — per-request timeout (defaults to 30 s, 600 s for `pipe`)
///   - Exit-code contract from [docs/SERVER.md](../../../docs/SERVER.md):
///       0 ok • 2 no server • 3 server returned ok:false • 4 transport error

// MARK: - load

struct Load: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "load",
        abstract: "Load a CSV into the resident server under a name."
    )

    @Argument(help: "Path to the CSV file to load.")
    var path: String

    @Option(name: .long, help: "Name to bind the resulting DataFrame under.")
    var name: String

    @Option(name: .long, help: "Column delimiter (default: comma).")
    var sep: String = ","

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = Client.defaultTimeout

    func run() throws {
        let req = WireRequest(cmd: .load, path: path, name: name, sep: sep)
        let resp = try ClientRunner.send(req, socket: socket, timeout: timeout)
        if let w = resp.warning { logStderr("\(Style.yellow)warning:\(Style.reset) \(w)") }
        guard case .load(let boundName, let rows, let cols, let bytes) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }
        print("\(Style.green)loaded\(Style.reset) \(Style.bold)\(boundName)\(Style.reset): \(formatCount(rows)) rows × \(formatCount(cols)) cols  \(Style.dim)(\(formatBytes(bytes)))\(Style.reset)")
    }
}

// MARK: - pipe

struct Pipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pipe",
        abstract: "Apply a DSL pipeline to a resident DataFrame."
    )

    @Option(name: .long, help: "Source DataFrame name to read from.")
    var from: String

    @Option(name: .long, help: "Name to bind the pipeline result under.")
    var name: String

    @Option(name: .shortAndLong, help: "Inline DSL transform chain.")
    var chain: String?

    @Option(name: .shortAndLong, help: "Path to a .json transform file.")
    var file: String?

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    /// Pipe defaults to a generous timeout — large transforms can run for
    /// minutes against multi-million-row dataframes.
    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = 600

    func run() throws {
        if chain == nil && file == nil {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) pipe requires --chain or --file")
            throw ExitCode(ServerExit.serverError.rawValue)
        }
        var req = WireRequest(cmd: .pipe, name: name, from: from)
        if let chain = chain {
            req.chain = chain
        } else if let file = file {
            // Resolve JSON content on the client side — the daemon may run as
            // a different uid (e.g. under brew services) and not be able to
            // open the caller's transform file.
            do {
                req.json = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                logStderr("\(Style.red)swiftpandas:\(Style.reset) could not read transform file '\(file)': \(error)")
                throw ExitCode(ServerExit.serverError.rawValue)
            }
        }
        let resp = try ClientRunner.send(req, socket: socket, timeout: timeout)
        if let w = resp.warning { logStderr("\(Style.yellow)warning:\(Style.reset) \(w)") }
        guard case .pipe(let boundName, let rows, let cols, let bytes, let stages) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }
        print("\(Style.green)\(from)\(Style.reset) → \(Style.bold)\(boundName)\(Style.reset): \(formatCount(rows)) rows × \(formatCount(cols)) cols  \(Style.dim)(\(formatBytes(bytes)) via \(stages) stage\(stages == 1 ? "" : "s"))\(Style.reset)")
    }
}

// MARK: - save

struct Save: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Write a resident DataFrame to a CSV file."
    )

    @Argument(help: "Resident DataFrame name to save.")
    var name: String

    @Argument(help: "Destination CSV path.")
    var path: String

    @Option(name: .long, help: "Column delimiter (default: comma).")
    var sep: String = ","

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = 120  // CSV writes for big DFs can take a while

    func run() throws {
        let req = WireRequest(cmd: .save, path: path, name: name, sep: sep)
        let resp = try ClientRunner.send(req, socket: socket, timeout: timeout)
        guard case .save(let writtenPath, let rows, let cols) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }
        print("\(Style.green)saved\(Style.reset) \(Style.bold)\(name)\(Style.reset) → \(writtenPath)  \(Style.dim)(\(formatCount(rows)) rows × \(formatCount(cols)) cols)\(Style.reset)")
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List resident DataFrames with shape and size."
    )

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = Client.defaultTimeout

    func run() throws {
        let resp = try ClientRunner.send(.init(cmd: .list), socket: socket, timeout: timeout)
        guard case .list(let items) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }
        if items.isEmpty {
            print("\(Style.dim)no resident dataframes\(Style.reset)")
            return
        }
        // Column widths
        let nameW = max(4, items.map { $0.name.count }.max() ?? 4)
        let rowsW = max(4, items.map { formatCount($0.rows).count }.max() ?? 4)
        let colsW = max(4, items.map { formatCount($0.cols).count }.max() ?? 4)
        let sizeW = max(4, items.map { formatBytes($0.bytes).count }.max() ?? 4)

        print("")
        print("  \(Style.bold)\(pad("NAME", nameW))  \(pad("ROWS", rowsW))  \(pad("COLS", colsW))  \(pad("SIZE", sizeW))  AGE\(Style.reset)")
        print("  \(Style.dim)\(String(repeating: "─", count: nameW + rowsW + colsW + sizeW + 12 + 3))\(Style.reset)")
        for e in items {
            let age = formatTime(Date().timeIntervalSince(e.createdAt))
            print("  \(pad(e.name, nameW))  \(pad(formatCount(e.rows), rowsW))  \(pad(formatCount(e.cols), colsW))  \(pad(formatBytes(e.bytes), sizeW))  \(Style.dim)\(age)\(Style.reset)")
        }
        print("")
    }

    private func pad(_ s: String, _ n: Int) -> String {
        if s.count >= n { return s }
        return s + String(repeating: " ", count: n - s.count)
    }
}

// MARK: - drop

struct Drop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drop",
        abstract: "Remove a resident DataFrame and free its memory."
    )

    @Argument(help: "Resident DataFrame name to drop.")
    var name: String

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = Client.defaultTimeout

    func run() throws {
        let resp = try ClientRunner.send(.init(cmd: .drop, name: name), socket: socket, timeout: timeout)
        guard case .drop(let n, let freed) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }
        print("\(Style.green)dropped\(Style.reset) \(Style.bold)\(n)\(Style.reset)  \(Style.dim)(freed \(formatBytes(freed)))\(Style.reset)")
    }
}

// MARK: - info

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print per-column dtype, non-null count, and size (pandas df.info() equivalent)."
    )

    @Argument(help: "Resident DataFrame name to inspect.")
    var name: String

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = Client.defaultTimeout

    func run() throws {
        let resp = try ClientRunner.send(.init(cmd: .info, name: name), socket: socket, timeout: timeout)
        guard case .info(let n, let rows, let cols, let totalBytes, let columns) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }

        // Compute column widths so the table aligns regardless of dataset.
        let nameW  = max(4, columns.map { $0.name.count }.max() ?? 4)
        let typeW  = max(5, columns.map { $0.dtype.count }.max() ?? 5)
        let nnW    = max(8, columns.map { "\($0.nonNull)".count }.max() ?? 8)
        let sizeW  = max(4, columns.map { formatBytes($0.bytes).count }.max() ?? 4)

        let pad: (String, Int) -> String = { s, w in s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }

        print("")
        print("\(Style.bold)\(n)\(Style.reset)  \(Style.dim)\(formatCount(rows)) rows × \(formatCount(cols)) cols  ·  \(formatBytes(totalBytes))\(Style.reset)")
        print("")
        print("  \(Style.bold)\(pad("COL", nameW))  \(pad("DTYPE", typeW))  \(pad("NON-NULL", nnW))  \(pad("SIZE", sizeW))\(Style.reset)")
        print("  \(Style.dim)\(String(repeating: "─", count: nameW + typeW + nnW + sizeW + 6))\(Style.reset)")
        for c in columns {
            let nullMark = (c.nonNull < rows) ? " \(Style.yellow)(\(rows - c.nonNull) NA)\(Style.reset)" : ""
            print("  \(pad(c.name, nameW))  \(Style.cyan)\(pad(c.dtype, typeW))\(Style.reset)  \(pad("\(c.nonNull)", nnW))  \(pad(formatBytes(c.bytes), sizeW))\(nullMark)")
        }
        print("")
    }
}

// MARK: - show

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the head of a resident DataFrame as CSV."
    )

    @Argument(help: "Resident DataFrame name to show.")
    var name: String

    @Option(name: .long, help: "Number of rows to preview.")
    var head: Int = 10

    @Option(name: .long, help: "Unix-domain socket path.")
    var socket: String?

    @Option(name: .long, help: "Per-request timeout in seconds.")
    var timeout: Double = Client.defaultTimeout

    func run() throws {
        let resp = try ClientRunner.send(
            .init(cmd: .show, name: name, head: head),
            socket: socket,
            timeout: timeout
        )
        guard case .show(_, _, _, let csv, let truncated) = resp.data else {
            throw ClientRunner.unexpectedPayload(resp)
        }
        print(csv, terminator: "")
        if truncated {
            logStderr("\(Style.yellow)swiftpandas:\(Style.reset) output truncated at the daemon's preview cap — use 'save' for the full export")
        }
    }
}

// MARK: - Shared runner

/// Common dial + decode + error-mapping path used by every client subcommand.
enum ClientRunner {

    /// Resolve the socket path (defaulting to `~/.swiftpandas/sock`), dial,
    /// send `req`, decode reply. Maps errors to exit codes:
    ///   - `.notRunning` → 2
    ///   - daemon `ok:false` → 3
    ///   - `.timeout` / `.transport` / `.decode` → 4
    static func send(_ req: WireRequest, socket: String?, timeout: Double) throws -> WireResponse {
        let socketPath: String
        do {
            socketPath = try (socket ?? Paths.socketPath())
        } catch {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) failed to resolve socket path: \(error)")
            throw ExitCode(ServerExit.transportError.rawValue)
        }
        do {
            let resp = try Client.sendRequest(req, socketPath: socketPath, timeout: timeout)
            if !resp.ok {
                let err = resp.error
                logStderr("\(Style.red)swiftpandas:\(Style.reset) \(err?.message ?? "server returned an unknown error")")
                throw ExitCode(ServerExit.serverError.rawValue)
            }
            return resp
        } catch Client.ClientError.notRunning {
            logStderr("\(Style.yellow)swiftpandas:\(Style.reset) no server running")
            logStderr("            Start it with \(Style.bold)swiftpandas server start\(Style.reset).")
            throw ExitCode(ServerExit.notRunning.rawValue)
        } catch Client.ClientError.timeout {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon did not respond within \(timeout)s")
            throw ExitCode(ServerExit.transportError.rawValue)
        } catch is Client.ClientError {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) transport error talking to daemon")
            throw ExitCode(ServerExit.transportError.rawValue)
        } catch let ec as ExitCode {
            throw ec
        } catch {
            logStderr("\(Style.red)swiftpandas:\(Style.reset) unexpected error: \(error)")
            throw ExitCode(ServerExit.transportError.rawValue)
        }
    }

    static func unexpectedPayload(_ resp: WireResponse) -> ExitCode {
        logStderr("\(Style.red)swiftpandas:\(Style.reset) daemon returned an unexpected payload kind")
        return ExitCode(ServerExit.transportError.rawValue)
    }
}
