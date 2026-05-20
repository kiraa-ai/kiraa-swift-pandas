import Foundation
import Network
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix-domain-socket transport for the resident-memory daemon.
///
/// Server side uses `NWListener` on `NWEndpoint.unix(path:)`; client side uses
/// `NWConnection` over the same endpoint. Every `Connection` wraps a single
/// `NWConnection` behind an actor that buffers received bytes and serves
/// newline-delimited frames via ``Connection/receiveLine()``.
///
/// Wire framing is the simplest thing that works: one JSON object per line.
/// Frame size is capped at ``maxFrameBytes`` (16 MiB) — frames larger than
/// that throw ``TransportError/oversizedFrame`` so a malformed client cannot
/// exhaust the daemon's memory by streaming bytes without a newline.
public enum Transport {
    public enum TransportError: Error, Equatable {
        /// No daemon is listening: either the socket file is absent (ENOENT)
        /// or the kernel refused the connection (ECONNREFUSED). Subcommands
        /// map this to the user-visible "no server running" exit-2 path.
        case notRunning
        /// The peer closed the connection mid-stream.
        case connectionClosed
        /// The dial or per-operation timeout fired.
        case timeout
        /// A single frame exceeded ``maxFrameBytes``.
        case oversizedFrame
        /// Any other `NWError` or callback failure; message captured for logs.
        case underlying(String)
    }

    /// Hard cap on a single frame, to keep a misbehaving client from
    /// exhausting daemon memory.
    public static let maxFrameBytes = 16 * 1024 * 1024

    // MARK: - Connection

    /// One in-flight Unix-domain connection. Serialises sends and receives
    /// internally via actor isolation; the buffered byte queue is mutated
    /// only from inside the actor.
    public actor Connection {
        private let nw: NWConnection
        private var pending = Data()
        private var closed = false

        init(_ nw: NWConnection) {
            self.nw = nw
        }

        /// Wait until the underlying NWConnection reaches `.ready`. Maps
        /// ENOENT and ECONNREFUSED to ``TransportError/notRunning``. Used by
        /// ``Transport/dial(socketPath:timeout:)`` only — server-side
        /// connections start implicitly via ``startForServer()``.
        fileprivate func waitReady(timeout: TimeInterval) async throws {
            let queue = Connection.callbackQueue
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let resumer = OneShotResumer(cont)
                nw.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resumer.resume(.success(()))
                    case .failed(let err):
                        resumer.resume(.failure(Connection.mapNWError(err)))
                    case .cancelled:
                        resumer.resume(.failure(TransportError.connectionClosed))
                    default:
                        break
                    }
                }
                nw.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    resumer.resume(.failure(TransportError.timeout))
                }
            }
        }

        /// Drive a server-accepted connection through its state machine.
        /// Doesn't block — the connection becomes usable once NWConnection
        /// reaches `.ready`, which happens off-thread.
        fileprivate func startForServer() {
            nw.stateUpdateHandler = { _ in /* server-side: no need to gate on ready */ }
            nw.start(queue: Connection.callbackQueue)
        }

        /// Send a single byte buffer. Newline framing is the caller's
        /// responsibility — typically you encode via ``WireFrame/encode(_:)``
        /// which appends `\n` for you.
        public func send(_ data: Data) async throws {
            if closed { throw TransportError.connectionClosed }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                nw.send(content: data, completion: .contentProcessed { error in
                    if let error = error {
                        cont.resume(throwing: TransportError.underlying("\(error)"))
                    } else {
                        cont.resume()
                    }
                })
            }
        }

        /// Read bytes from the connection until a `\n` (0x0A) is seen,
        /// returning the line **including** the terminating newline.
        /// Throws ``TransportError/oversizedFrame`` once the buffer exceeds
        /// ``maxFrameBytes`` without a newline.
        public func receiveLine() async throws -> Data {
            if closed { throw TransportError.connectionClosed }
            while true {
                if let idx = pending.firstIndex(of: 0x0A) {
                    let end = pending.index(after: idx)
                    let line = Data(pending[..<end])
                    pending.removeSubrange(..<end)
                    return line
                }
                if pending.count > Transport.maxFrameBytes {
                    throw TransportError.oversizedFrame
                }
                let chunk = try await receiveChunk()
                pending.append(chunk)
            }
        }

        private func receiveChunk() async throws -> Data {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error = error {
                        cont.resume(throwing: TransportError.underlying("\(error)"))
                        return
                    }
                    if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(throwing: TransportError.connectionClosed)
                        return
                    }
                    cont.resume(throwing: TransportError.connectionClosed)
                }
            }
        }

        /// Cancel the underlying NWConnection. Idempotent.
        public func close() {
            if !closed {
                closed = true
                nw.cancel()
            }
        }

        // MARK: - Helpers

        nonisolated static let callbackQueue = DispatchQueue(
            label: "swiftpandas.transport",
            qos: .userInitiated
        )

        static func mapNWError(_ err: NWError) -> TransportError {
            switch err {
            case .posix(let code):
                if code == .ECONNREFUSED || code == .ENOENT {
                    return .notRunning
                }
                return .underlying("posix \(code)")
            default:
                return .underlying("\(err)")
            }
        }
    }

    // MARK: - Listener

    /// A running NWListener bound to a Unix-domain socket. `close()` cancels
    /// the listener and unlinks the socket file.
    public final class Listener: @unchecked Sendable {
        private let nw: NWListener
        public let socketPath: String
        private var closed = false
        private let lock = NSLock()

        init(_ nw: NWListener, socketPath: String) {
            self.nw = nw
            self.socketPath = socketPath
        }

        public func close() {
            lock.lock()
            defer { lock.unlock() }
            if !closed {
                closed = true
                nw.cancel()
                unlink(socketPath)
            }
        }
    }

    // MARK: - Listen

    /// Start a listener on `socketPath`. The provided handler is invoked once
    /// per accepted connection; its lifetime is the caller's responsibility
    /// (typically the daemon's accept loop spawns a Task per connection).
    ///
    /// On success the socket file exists, is chmod 0600, and `NWListener` is
    /// in `.ready` state.
    public static func listen(
        socketPath: String,
        onConnection: @escaping @Sendable (Connection) async -> Void
    ) async throws -> Listener {
        // Best-effort: remove stale socket file from a previous crashed daemon.
        unlink(socketPath)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        params.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            throw TransportError.underlying("NWListener init failed: \(error)")
        }

        let queue = Connection.callbackQueue
        let wrapper = Listener(listener, socketPath: socketPath)

        listener.newConnectionHandler = { nwConn in
            let conn = Connection(nwConn)
            Task.detached {
                await conn.startForServer()
                await onConnection(conn)
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumer = OneShotResumer(cont)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.resume(.success(()))
                case .failed(let err):
                    resumer.resume(.failure(TransportError.underlying("listener failed: \(err)")))
                case .cancelled:
                    resumer.resume(.failure(TransportError.connectionClosed))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }

        // Tighten socket perms to owner-only.
        chmod(socketPath, 0o600)

        return wrapper
    }

    // MARK: - Dial

    /// Open a client connection to `socketPath`, waiting up to `timeout`
    /// seconds for the kernel to confirm the connection.
    ///
    /// - Throws ``TransportError/notRunning`` if the socket file is missing
    ///   or the kernel returns ECONNREFUSED. Both are the client's signal to
    ///   exit 2 with "no server running".
    /// - Throws ``TransportError/timeout`` if the daemon accepts the socket
    ///   but never transitions to `.ready` within the budget (rare; usually
    ///   indicates a hung daemon).
    public static func dial(socketPath: String, timeout: TimeInterval = 30) async throws -> Connection {
        // Fast-path: if the socket file doesn't exist, no daemon is running.
        // This bypasses NWConnection's slower state machine for the common case.
        var st = stat()
        if stat(socketPath, &st) != 0 {
            if errno == ENOENT {
                throw TransportError.notRunning
            }
        }

        let endpoint = NWEndpoint.unix(path: socketPath)
        let nwConn = NWConnection(to: endpoint, using: .tcp)
        let conn = Connection(nwConn)
        do {
            try await conn.waitReady(timeout: timeout)
        } catch {
            await conn.close()
            throw error
        }
        return conn
    }
}

// MARK: - Internal helper

/// Wraps a `CheckedContinuation` so only the first call to `resume(_:)` takes
/// effect; later calls are silently ignored. Used to merge multiple sources
/// of completion (state callback, timeout, cancellation) onto a single
/// continuation without crashing on a double-resume.
private final class OneShotResumer<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let cont: CheckedContinuation<T, Error>

    init(_ cont: CheckedContinuation<T, Error>) {
        self.cont = cont
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        lock.unlock()
        switch result {
        case .success(let v): cont.resume(returning: v)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}
