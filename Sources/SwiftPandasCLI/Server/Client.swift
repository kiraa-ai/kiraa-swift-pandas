import Foundation

/// Synchronous façade over `Transport` for use from ArgumentParser
/// subcommands (whose `run()` methods are sync-throwing).
///
/// Internally bridges into async via `Task.detached` + `DispatchSemaphore`.
/// The single public entry point is ``sendRequest(_:socketPath:timeout:)``,
/// which dials, sends one frame, reads one reply, closes, and returns.
public enum Client {

    /// Default per-request timeout for non-pipe commands.
    public static let defaultTimeout: TimeInterval = 30

    /// Errors surfaced to client subcommands. Each maps directly to an exit
    /// code:
    ///   - `.notRunning`   → exit 2 ("no server running")
    ///   - `.transport`    → exit 4 (I/O failure)
    ///   - `.decode`       → exit 4 (malformed reply)
    ///   - `.timeout`      → exit 4
    public enum ClientError: Error, Equatable {
        case notRunning
        case transport(String)
        case decode(String)
        case timeout
    }

    /// Dial the daemon, send `req`, receive one reply, close.
    ///
    /// This method blocks the calling thread until the round trip completes
    /// or `timeout + 5` seconds elapse — whichever comes first. The extra
    /// 5 seconds covers connection-setup latency on slow / loaded systems.
    public static func sendRequest(
        _ req: WireRequest,
        socketPath: String,
        timeout: TimeInterval = defaultTimeout
    ) throws -> WireResponse {
        let outcome = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            do {
                let conn = try await Transport.dial(socketPath: socketPath, timeout: timeout)
                defer { Task { await conn.close() } }

                try await conn.send(WireFrame.encode(req))
                let frame = try await conn.receiveLine()
                let resp = try WireFrame.decode(WireResponse.self, from: frame)
                outcome.set(.success(resp))
            } catch let t as Transport.TransportError {
                switch t {
                case .notRunning:        outcome.set(.failure(.notRunning))
                case .timeout:           outcome.set(.failure(.timeout))
                case .connectionClosed,
                     .oversizedFrame,
                     .underlying:        outcome.set(.failure(.transport("\(t)")))
                }
            } catch let d as DecodingError {
                outcome.set(.failure(.decode("\(d)")))
            } catch {
                outcome.set(.failure(.transport("\(error)")))
            }
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout + 5)
        switch waitResult {
        case .timedOut:
            throw ClientError.timeout
        case .success:
            switch outcome.current {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }
}

// MARK: - Internal box

/// Lock-protected single-cell holder so the detached Task can write the
/// outcome and the calling thread can read it after the semaphore signal.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<WireResponse, Client.ClientError> = .failure(.timeout)

    var current: Result<WireResponse, Client.ClientError> {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ v: Result<WireResponse, Client.ClientError>) {
        lock.lock(); defer { lock.unlock() }
        value = v
    }
}
