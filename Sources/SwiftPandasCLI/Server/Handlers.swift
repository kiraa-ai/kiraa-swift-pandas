import Foundation
import SwiftPandas

/// Pure command handlers for the resident-memory daemon.
///
/// Each handler takes a `WireRequest`, mutates or queries a `DataFrameRegistry`
/// actor, and returns a `WireResponse`. They contain no IPC or socket logic —
/// they are equally callable from a daemon's accept loop, from unit tests, or
/// from an in-process embedding. Phase 2 wires these into an `NWListener`
/// accept loop; Phase 1 exercises them via XCTest.
///
/// Heavy work (`DataFrame.readCSV`, `TransformRunner.run`) intentionally runs
/// *outside* the actor: each handler reads from the registry in one `await`,
/// computes, then writes back in a second `await`. This keeps the registry hot
/// and allows independent pipelines to proceed in parallel.
public enum Handlers {

    /// 1 MiB cap on `show` CSV payloads. Larger DataFrames return
    /// `truncated: true` and instruct the client to use `save` instead.
    public static let showByteCap = 1 << 20

    // MARK: - load

    public static func handleLoad(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        guard let path = req.path, !path.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "load: missing 'path'"))
        }
        guard let name = req.name, !name.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "load: missing 'name' (target binding)"))
        }
        let separator: Character = req.sep?.first ?? ","
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(id: req.id, WireError(code: WireErrorCode.io, message: "File not found: '\(path)'"))
        }
        let df: DataFrame
        do {
            df = try DataFrame.readCSV(path: path, separator: separator)
        } catch {
            return .failure(id: req.id, WireError(code: WireErrorCode.io, message: "Failed to read CSV: \(error.localizedDescription)"))
        }
        let overwritten = await registry.bind(name, df)
        return .success(
            id: req.id,
            data: .load(name: name, rows: df.rowCount, cols: df.columnCount, bytes: df.estimatedBytes),
            warning: overwritten ? "overwrote existing df '\(name)'" : nil
        )
    }

    // MARK: - pipe

    public static func handlePipe(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        guard let source = req.from, !source.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "pipe: missing 'from'"))
        }
        guard let target = req.name, !target.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "pipe: missing 'name' (target binding)"))
        }
        let chain = req.chain ?? ""
        let json = req.json ?? ""
        if chain.isEmpty && json.isEmpty {
            return .failure(id: req.id, WireError(code: WireErrorCode.parse, message: "pipe: provide 'chain' or 'json'"))
        }

        guard let sourceDF = await registry.lookup(source) else {
            return .failure(id: req.id, WireError(
                code: WireErrorCode.noSuchDataFrame,
                message: "no dataframe bound to name '\(source)'"
            ))
        }

        let operations: [Operation]
        do {
            if !chain.isEmpty {
                operations = try DSLParser.parse(chain)
            } else {
                operations = try JSONTransformParser.parse(from: json)
            }
        } catch {
            return .failure(id: req.id, WireError.from(error))
        }

        let result: DataFrame
        do {
            result = try TransformRunner(operations: operations, verbose: false).run(on: sourceDF)
        } catch {
            return .failure(id: req.id, WireError.from(error))
        }

        let overwritten = await registry.bind(target, result)
        return .success(
            id: req.id,
            data: .pipe(
                name: target,
                rows: result.rowCount,
                cols: result.columnCount,
                bytes: result.estimatedBytes,
                stages: operations.count
            ),
            warning: overwritten ? "overwrote existing df '\(target)'" : nil
        )
    }

    // MARK: - save

    public static func handleSave(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        guard let name = req.name, !name.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "save: missing 'name'"))
        }
        guard let path = req.path, !path.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "save: missing 'path'"))
        }
        guard let df = await registry.lookup(name) else {
            return .failure(id: req.id, WireError(
                code: WireErrorCode.noSuchDataFrame,
                message: "no dataframe bound to name '\(name)'"
            ))
        }
        let sep = req.sep ?? ","
        do {
            try df.toCSV(path: path, separator: sep)
        } catch {
            return .failure(id: req.id, WireError(code: WireErrorCode.io, message: "Failed to write CSV: \(error.localizedDescription)"))
        }
        return .success(id: req.id, data: .save(path: path, rows: df.rowCount, cols: df.columnCount))
    }

    // MARK: - list

    public static func handleList(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        let items = await registry.list()
        return .success(id: req.id, data: .list(items: items))
    }

    // MARK: - drop

    public static func handleDrop(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        guard let name = req.name, !name.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "drop: missing 'name'"))
        }
        guard let freed = await registry.drop(name) else {
            return .failure(id: req.id, WireError(
                code: WireErrorCode.noSuchDataFrame,
                message: "no dataframe bound to name '\(name)'"
            ))
        }
        return .success(id: req.id, data: .drop(name: name, freedBytes: freed))
    }

    // MARK: - show

    public static func handleShow(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        guard let name = req.name, !name.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "show: missing 'name'"))
        }
        guard let df = await registry.lookup(name) else {
            return .failure(id: req.id, WireError(
                code: WireErrorCode.noSuchDataFrame,
                message: "no dataframe bound to name '\(name)'"
            ))
        }
        let n = max(0, req.head ?? 10)
        let preview = df.head(min(n, df.rowCount))
        var csv = preview.toCSV()
        var truncated = false
        if csv.utf8.count > showByteCap {
            let prefix = csv.utf8.prefix(showByteCap)
            csv = String(decoding: prefix, as: UTF8.self)
            truncated = true
        }
        return .success(id: req.id, data: .show(
            name: name,
            rows: preview.rowCount,
            cols: preview.columnCount,
            csv: csv,
            truncated: truncated
        ))
    }

    // MARK: - info

    /// Per-column introspection: name, dtype, non-null count, byte size.
    /// Equivalent to pandas's `df.info()` but returned as structured data
    /// rather than a free-form printout, so scripts can consume it.
    public static func handleInfo(_ req: WireRequest, registry: DataFrameRegistry) async -> WireResponse {
        guard let name = req.name, !name.isEmpty else {
            return .failure(id: req.id, WireError(code: WireErrorCode.nameRequired, message: "info: missing 'name'"))
        }
        guard let df = await registry.lookup(name) else {
            return .failure(id: req.id, WireError(
                code: WireErrorCode.noSuchDataFrame,
                message: "no dataframe bound to name '\(name)'"
            ))
        }
        var columns: [WireColumnInfo] = []
        for (colName, dtype) in df.dtypes {
            let col = df[colName].data
            columns.append(WireColumnInfo(
                name: colName,
                dtype: "\(dtype)",
                nonNull: col.validCount,
                bytes: col.nbytes
            ))
        }
        return .success(id: req.id, data: .info(
            name: name,
            rows: df.rowCount,
            cols: df.columnCount,
            bytes: df.estimatedBytes,
            columns: columns
        ))
    }

    // MARK: - status

    public static func handleStatus(_ req: WireRequest, registry: DataFrameRegistry, socketPath: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier) async -> WireResponse {
        let count = await registry.count()
        let bytes = await registry.totalBytes()
        let uptime = Date().timeIntervalSince(registry.startedAt)
        return .success(id: req.id, data: .status(
            pid: pid,
            uptimeSeconds: uptime,
            dataframeCount: count,
            totalBytes: bytes,
            socket: socketPath
        ))
    }

    // MARK: - shutdown

    public static func handleShutdown(_ req: WireRequest, registry: DataFrameRegistry, pid: Int32 = ProcessInfo.processInfo.processIdentifier) async -> WireResponse {
        await registry.clear()
        return .success(id: req.id, data: .shutdown(pid: pid))
    }

    // MARK: - dispatch

    /// Convenience entry point that dispatches on `req.cmd`. The Phase 2 accept
    /// loop calls this once per inbound frame.
    public static func dispatch(_ req: WireRequest, registry: DataFrameRegistry, socketPath: String = "") async -> WireResponse {
        // Reject requests from a future / unknown protocol version. We accept
        // exactly the current version — additive schema changes bump it.
        if req.v != WireProtocol.version {
            return .failure(
                id: req.id,
                WireError(
                    code: WireErrorCode.proto,
                    message: "unsupported protocol version \(req.v); daemon expects \(WireProtocol.version)"
                )
            )
        }
        switch req.cmd {
        case .load:     return await handleLoad(req, registry: registry)
        case .pipe:     return await handlePipe(req, registry: registry)
        case .save:     return await handleSave(req, registry: registry)
        case .list:     return await handleList(req, registry: registry)
        case .drop:     return await handleDrop(req, registry: registry)
        case .show:     return await handleShow(req, registry: registry)
        case .info:     return await handleInfo(req, registry: registry)
        case .status:   return await handleStatus(req, registry: registry, socketPath: socketPath)
        case .shutdown: return await handleShutdown(req, registry: registry)
        }
    }
}
