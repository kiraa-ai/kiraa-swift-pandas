import Foundation
import SwiftPandas

/// Thread-safe, in-memory registry of named DataFrames.
///
/// The registry is the "memory area" where DataFrames live for the lifetime of
/// the resident server. All DataFrame-aware subcommands (`load`, `pipe`, `save`,
/// `list`, `drop`, `show`) route their state through a single registry actor
/// inside the daemon process. Clients hold no DataFrame state — they only
/// exchange names and DSL strings with the server.
///
/// ## Semantics
/// - `bind(_:_:)` overwrites an existing entry with the same name. The return
///   value indicates whether an existing slot was replaced (so callers can
///   surface a `warning` in the wire reply).
/// - `lookup(_:)` returns the bound DataFrame by value; because `DataFrame` is a
///   `Sendable` value type with copy-on-write buffers, the read is cheap and
///   does not block subsequent mutations.
/// - `drop(_:)` returns the freed byte count for accounting; returns `nil` if
///   the name was not bound (the caller should map that to `no_such_df`).
/// - `list()` is a snapshot; it does not observe concurrent mutations.
///
/// ## Concurrency
/// Serialization happens at actor boundaries. Heavy work (CSV parsing,
/// pipeline execution) must run *outside* the actor — read the DataFrame in
/// one hop, compute, then bind the result in a second hop. This keeps the
/// registry hot and lets independent pipelines proceed in parallel.
public actor DataFrameRegistry {
    /// A single named DataFrame slot in the registry.
    public struct Slot: Sendable {
        public let df: DataFrame
        public let createdAt: Date
        public var lastTouched: Date
    }

    /// A snapshot row returned by ``list()`` and reported to clients.
    public struct Entry: Sendable, Codable, Equatable {
        public let name: String
        public let rows: Int
        public let cols: Int
        public let bytes: Int
        public let createdAt: Date
    }

    private var slots: [String: Slot] = [:]
    public let startedAt: Date

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// Bind `df` under `name`, overwriting any existing entry.
    /// - Returns: `true` if an existing entry was replaced.
    @discardableResult
    public func bind(_ name: String, _ df: DataFrame) -> Bool {
        let now = Date()
        let existed = slots[name] != nil
        slots[name] = Slot(df: df, createdAt: now, lastTouched: now)
        return existed
    }

    /// Return the DataFrame bound to `name`, or `nil` if unbound.
    public func lookup(_ name: String) -> DataFrame? {
        guard var slot = slots[name] else { return nil }
        slot.lastTouched = Date()
        slots[name] = slot
        return slot.df
    }

    /// Drop the entry at `name`. Returns its estimated byte size, or `nil` if
    /// the name was not bound.
    public func drop(_ name: String) -> Int? {
        guard let slot = slots.removeValue(forKey: name) else { return nil }
        return slot.df.estimatedBytes
    }

    /// Snapshot of all bound entries, sorted by binding time (oldest first).
    public func list() -> [Entry] {
        slots
            .map { (name, slot) in
                Entry(
                    name: name,
                    rows: slot.df.rowCount,
                    cols: slot.df.columnCount,
                    bytes: slot.df.estimatedBytes,
                    createdAt: slot.createdAt
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Number of DataFrames currently held.
    public func count() -> Int { slots.count }

    /// Sum of estimated bytes across all bound DataFrames.
    public func totalBytes() -> Int {
        slots.values.reduce(0) { $0 + $1.df.estimatedBytes }
    }

    /// Remove all entries. Returns the total bytes freed.
    @discardableResult
    public func clear() -> Int {
        let freed = totalBytes()
        slots.removeAll()
        return freed
    }
}
