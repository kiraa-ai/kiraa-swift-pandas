import Foundation

/// Wire protocol for the resident-memory daemon.
///
/// Messages are exchanged as newline-delimited JSON over a Unix-domain socket:
/// the client writes a single `Request` followed by `\n`, the server replies
/// with a single `Response` followed by `\n`. The format is deliberately
/// minimal so it can be exercised with `nc -U` during development.
///
/// All field names use snake_case to match the published wire format; Swift
/// property names follow the language convention and are mapped via
/// `CodingKeys`.

public enum WireProtocol {
    /// Current protocol version. Bumped on any breaking schema change.
    public static let version = 1
}

// MARK: - Request

/// A single command from a client to the daemon.
///
/// Fields are optional at the struct level because each command uses only a
/// subset; handlers are responsible for validating that the fields they
/// require are present.
public struct WireRequest: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var cmd: WireCommand

    // command-specific arguments
    public var path: String?
    /// Name of the DataFrame this command operates on. For `load`/`pipe`
    /// this is the **target** binding (where the result goes). For
    /// `save`/`drop`/`show` it's the **source** (what to operate on).
    public var name: String?
    public var from: String?
    public var chain: String?
    public var json: String?
    public var sep: String?
    public var head: Int?

    public init(
        v: Int = WireProtocol.version,
        id: String = UUID().uuidString,
        cmd: WireCommand,
        path: String? = nil,
        name: String? = nil,
        from: String? = nil,
        chain: String? = nil,
        json: String? = nil,
        sep: String? = nil,
        head: Int? = nil
    ) {
        self.v = v
        self.id = id
        self.cmd = cmd
        self.path = path
        self.name = name
        self.from = from
        self.chain = chain
        self.json = json
        self.sep = sep
        self.head = head
    }
}

/// The discriminator for which command the client wants the daemon to run.
public enum WireCommand: String, Codable, Sendable, CaseIterable {
    case load
    case pipe
    case save
    case list
    case drop
    case show
    case info
    case status
    case shutdown
}

/// Per-column description returned by `info`. Matches what pandas's
/// `df.info()` shows but in a structured, machine-readable form.
public struct WireColumnInfo: Codable, Equatable, Sendable {
    public let name: String
    public let dtype: String   // "float64" | "int64" | "string" | "bool"
    public let nonNull: Int
    public let bytes: Int

    public init(name: String, dtype: String, nonNull: Int, bytes: Int) {
        self.name = name
        self.dtype = dtype
        self.nonNull = nonNull
        self.bytes = bytes
    }

    enum CodingKeys: String, CodingKey {
        case name, dtype
        case nonNull = "non_null"
        case bytes
    }
}

// MARK: - Response

/// A single reply from the daemon to a client. Pairs with the originating
/// request via `id`.
public struct WireResponse: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var ok: Bool
    public var data: WireData?
    public var error: WireError?
    public var warning: String?

    public init(
        v: Int = WireProtocol.version,
        id: String,
        ok: Bool,
        data: WireData? = nil,
        error: WireError? = nil,
        warning: String? = nil
    ) {
        self.v = v
        self.id = id
        self.ok = ok
        self.data = data
        self.error = error
        self.warning = warning
    }

    public static func success(id: String, data: WireData, warning: String? = nil) -> WireResponse {
        WireResponse(id: id, ok: true, data: data, warning: warning)
    }

    public static func failure(id: String, _ error: WireError) -> WireResponse {
        WireResponse(id: id, ok: false, error: error)
    }
}

/// Structured error payload returned when `ok == false`.
///
/// `code` is a stable string the client uses for branching (exit codes,
/// machine readable handling). `message` is a human-readable description that
/// is safe to print to stderr.
public struct WireError: Codable, Equatable, Sendable, Error {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// Stable error codes the daemon may emit. Clients should treat unknown codes
/// as opaque strings — adding a new code is not a breaking change.
public enum WireErrorCode {
    public static let noSuchDataFrame = "no_such_df"
    public static let nameRequired = "name_required"
    public static let parse = "parse"
    public static let io = "io"
    public static let typeMismatch = "type_mismatch"
    public static let unknownColumn = "unknown_column"
    public static let divisionByZero = "division_by_zero"
    public static let unknownOperation = "unknown_operation"
    public static let aggWithoutGroupBy = "agg_without_groupby"
    public static let emptyPipeline = "empty_pipeline"
    public static let proto = "protocol"
    public static let internalError = "internal"
}

// MARK: - Response payloads

/// Discriminated payload for a successful response. Each command produces a
/// specific case; the field names match the published wire shape.
public enum WireData: Codable, Equatable, Sendable {
    case load(name: String, rows: Int, cols: Int, bytes: Int)
    case pipe(name: String, rows: Int, cols: Int, bytes: Int, stages: Int)
    case save(path: String, rows: Int, cols: Int)
    case list(items: [DataFrameRegistry.Entry])
    case drop(name: String, freedBytes: Int)
    case show(name: String, rows: Int, cols: Int, csv: String, truncated: Bool)
    case info(name: String, rows: Int, cols: Int, bytes: Int, columns: [WireColumnInfo])
    case status(pid: Int32, uptimeSeconds: Double, dataframeCount: Int, totalBytes: Int, socket: String)
    case shutdown(pid: Int32)

    enum CodingKeys: String, CodingKey {
        case kind
        case name, rows, cols, bytes, stages
        case path
        case items
        case freedBytes = "freed_bytes"
        case csv, truncated
        case columns
        case pid
        case uptimeSeconds = "uptime_s"
        case dataframeCount = "df_count"
        case totalBytes = "total_bytes"
        case socket
    }

    private enum Kind: String, Codable { case load, pipe, save, list, drop, show, info, status, shutdown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .load:
            self = .load(
                name: try c.decode(String.self, forKey: .name),
                rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols),
                bytes: try c.decode(Int.self, forKey: .bytes)
            )
        case .pipe:
            self = .pipe(
                name: try c.decode(String.self, forKey: .name),
                rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols),
                bytes: try c.decode(Int.self, forKey: .bytes),
                stages: try c.decode(Int.self, forKey: .stages)
            )
        case .save:
            self = .save(
                path: try c.decode(String.self, forKey: .path),
                rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols)
            )
        case .list:
            self = .list(items: try c.decode([DataFrameRegistry.Entry].self, forKey: .items))
        case .drop:
            self = .drop(
                name: try c.decode(String.self, forKey: .name),
                freedBytes: try c.decode(Int.self, forKey: .freedBytes)
            )
        case .show:
            self = .show(
                name: try c.decode(String.self, forKey: .name),
                rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols),
                csv: try c.decode(String.self, forKey: .csv),
                truncated: try c.decode(Bool.self, forKey: .truncated)
            )
        case .info:
            self = .info(
                name: try c.decode(String.self, forKey: .name),
                rows: try c.decode(Int.self, forKey: .rows),
                cols: try c.decode(Int.self, forKey: .cols),
                bytes: try c.decode(Int.self, forKey: .bytes),
                columns: try c.decode([WireColumnInfo].self, forKey: .columns)
            )
        case .status:
            self = .status(
                pid: try c.decode(Int32.self, forKey: .pid),
                uptimeSeconds: try c.decode(Double.self, forKey: .uptimeSeconds),
                dataframeCount: try c.decode(Int.self, forKey: .dataframeCount),
                totalBytes: try c.decode(Int.self, forKey: .totalBytes),
                socket: try c.decode(String.self, forKey: .socket)
            )
        case .shutdown:
            self = .shutdown(pid: try c.decode(Int32.self, forKey: .pid))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .load(let name, let rows, let cols, let bytes):
            try c.encode(Kind.load, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(rows, forKey: .rows)
            try c.encode(cols, forKey: .cols)
            try c.encode(bytes, forKey: .bytes)
        case .pipe(let name, let rows, let cols, let bytes, let stages):
            try c.encode(Kind.pipe, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(rows, forKey: .rows)
            try c.encode(cols, forKey: .cols)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(stages, forKey: .stages)
        case .save(let path, let rows, let cols):
            try c.encode(Kind.save, forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(rows, forKey: .rows)
            try c.encode(cols, forKey: .cols)
        case .list(let items):
            try c.encode(Kind.list, forKey: .kind)
            try c.encode(items, forKey: .items)
        case .drop(let name, let freedBytes):
            try c.encode(Kind.drop, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(freedBytes, forKey: .freedBytes)
        case .show(let name, let rows, let cols, let csv, let truncated):
            try c.encode(Kind.show, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(rows, forKey: .rows)
            try c.encode(cols, forKey: .cols)
            try c.encode(csv, forKey: .csv)
            try c.encode(truncated, forKey: .truncated)
        case .info(let name, let rows, let cols, let bytes, let columns):
            try c.encode(Kind.info, forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(rows, forKey: .rows)
            try c.encode(cols, forKey: .cols)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(columns, forKey: .columns)
        case .status(let pid, let uptime, let dfCount, let totalBytes, let socket):
            try c.encode(Kind.status, forKey: .kind)
            try c.encode(pid, forKey: .pid)
            try c.encode(uptime, forKey: .uptimeSeconds)
            try c.encode(dfCount, forKey: .dataframeCount)
            try c.encode(totalBytes, forKey: .totalBytes)
            try c.encode(socket, forKey: .socket)
        case .shutdown(let pid):
            try c.encode(Kind.shutdown, forKey: .kind)
            try c.encode(pid, forKey: .pid)
        }
    }
}

// MARK: - Frame helpers

/// Encode a wire value to a single newline-terminated JSON line.
public enum WireFrame {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        var data = try enc.encode(value)
        data.append(0x0A) // '\n'
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let trimmed: Data
        if let last = data.last, last == 0x0A {
            trimmed = data.subdata(in: 0..<(data.count - 1))
        } else {
            trimmed = data
        }
        return try dec.decode(type, from: trimmed)
    }
}

// MARK: - CLIError mapping

extension WireError {
    /// Build a wire error from a Swift error, mapping `CLIError` cases to
    /// stable codes the client can branch on.
    public static func from(_ error: Error) -> WireError {
        if let cli = error as? CLIError {
            switch cli {
            case .unknownOperation:    return WireError(code: WireErrorCode.unknownOperation, message: cli.errorDescription ?? "\(cli)")
            case .malformedExpression: return WireError(code: WireErrorCode.parse,            message: cli.errorDescription ?? "\(cli)")
            case .unknownColumn:       return WireError(code: WireErrorCode.unknownColumn,    message: cli.errorDescription ?? "\(cli)")
            case .typeMismatch:        return WireError(code: WireErrorCode.typeMismatch,     message: cli.errorDescription ?? "\(cli)")
            case .divisionByZero:      return WireError(code: WireErrorCode.divisionByZero,   message: cli.errorDescription ?? "\(cli)")
            case .invalidCastTarget:   return WireError(code: WireErrorCode.parse,            message: cli.errorDescription ?? "\(cli)")
            case .aggWithoutGroupBy:   return WireError(code: WireErrorCode.aggWithoutGroupBy, message: cli.errorDescription ?? "\(cli)")
            case .noTransformProvided: return WireError(code: WireErrorCode.parse,            message: cli.errorDescription ?? "\(cli)")
            case .fileNotFound:        return WireError(code: WireErrorCode.io,               message: cli.errorDescription ?? "\(cli)")
            case .emptyPipeline:       return WireError(code: WireErrorCode.emptyPipeline,    message: cli.errorDescription ?? "\(cli)")
            }
        }
        if let wire = error as? WireError { return wire }
        return WireError(code: WireErrorCode.internalError, message: "\(error)")
    }
}
