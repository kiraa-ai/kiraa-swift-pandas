// ===----------------------------------------------------------------------===//
//
// HotStoreTypes.swift
// SwiftPandas — HotStore submodule
//
// Public value types shared by the hot-cache tiers: cache keys, outcomes,
// statistics, file stamps, and the file-system probe abstraction that makes
// the whole submodule hermetically testable.
//
// The HotStore submodule implements an in-process, memory-first cache with
// two tiers sharing one byte budget:
//
//   * Tier 1 — ``TextCache``: raw bytes / text, byte-identity guaranteed.
//   * Tier 2 — ``FrameCache``: parsed ``DataFrame`` values.
//
// ``HotStore`` composes both tiers with file-stamp freshness validation so a
// caller can replace "read file from disk, parse" with a single hot-check
// call that only touches disk when the cache is cold or stale.
//
// ===----------------------------------------------------------------------===//

import Foundation

// MARK: - FrameKey

/// Identity of a cached entry.
///
/// A `FrameKey` is an opaque caller-defined identity: SwiftPandas never
/// interprets `name` or `tags`. Callers with a richer taxonomy (kind /
/// integration / job id / template id, …) should carry it in `tags` — the
/// taxonomy is caller data, not package schema. Two keys are the same entry
/// exactly when both `name` and `tags` are equal.
///
/// ```swift
/// let key = FrameKey(name: "dataframe_full",
///                    tags: ["kind": "pipeline", "jobId": "J-123"])
/// ```
public struct FrameKey: Hashable, Sendable {
    /// Primary, human-readable identity of the entry (e.g. a logical file
    /// name). Derived materialized-view keys are formed as
    /// `parent.name + "#" + viewName` (see ``HotStore/view(name:over:plan:)``).
    public let name: String

    /// Caller-defined discriminator tags. Part of the entry identity: the
    /// same `name` with different `tags` is a different entry.
    public let tags: [String: String]

    /// Creates a key from a name and optional discriminator tags.
    public init(name: String, tags: [String: String] = [:]) {
        self.name = name
        self.tags = tags
    }
}

// MARK: - Outcomes and reasons

/// Result of storing an entry in a hot-cache tier.
public enum PutOutcome: Equatable, Sendable {
    /// The entry was stored under a previously-unused key.
    case stored

    /// The entry's size exceeds the entire budget. The entry was **not**
    /// stored — oversize values are refused outright rather than admitted
    /// and immediately evicted, so a giant frame can never flush the whole
    /// cache on its way through.
    case refusedOversize

    /// An entry already existed under this key and was replaced. Any
    /// materialized views derived from the previous entry are invalidated,
    /// because they were computed from content that no longer exists.
    case replaced
}

/// Why an entry left the cache. Delivered to the `onEvict` hook.
public enum EvictionReason: Equatable, Sendable {
    /// Evicted to bring total bytes back under budget (LRU order,
    /// coldest unpinned entry first).
    case budget

    /// The entry's ``FileStamp`` no longer matched the file on disk. A stale
    /// entry is always evicted before the caller sees any data — a hot read
    /// can never return stale bytes.
    case stale

    /// Explicitly invalidated by the caller, or cascaded from the
    /// invalidation/eviction/replacement of a parent entry (materialized
    /// views die with their parent).
    case invalidated
}

// MARK: - CacheStats

/// A point-in-time snapshot of hot-cache counters.
///
/// When ``FrameCache`` and ``TextCache`` are composed inside a ``HotStore``,
/// they share one budget ledger, so `stats()` returns the same combined
/// numbers from every tier.
public struct CacheStats: Equatable, Sendable {
    /// Reads that were served from memory.
    public let hits: Int
    /// Reads that fell through to the caller (cold key, or stale entry that
    /// was evicted and re-read).
    public let misses: Int
    /// Entries removed for any ``EvictionReason``.
    public let evictions: Int
    /// Publishes dropped because the file's stamp could not be read at
    /// publish time (see ``HotStore/publishText(_:for:)``). Dropped publishes
    /// are silent by design — the writer must never fail because the cache
    /// could not accept a copy — but they are counted here so an operator can
    /// notice a publish seam that never lands.
    public let droppedPublishes: Int
    /// Current resident bytes across both tiers (pinned + unpinned).
    public let bytes: Int
    /// Current number of resident entries across both tiers.
    public let entryCount: Int
    /// The largest value `bytes` has ever reached.
    public let highWaterBytes: Int
    /// The current byte budget.
    public let budgetBytes: Int
}

// MARK: - FileStamp

/// A cheap freshness fingerprint of a file: modification time plus size.
///
/// Two stamps being equal is the HotStore's definition of "the file has not
/// changed since we cached it". This is the same contract editors and build
/// systems rely on; it does not detect a same-size, same-mtime rewrite
/// (which requires a deliberate adversary or sub-mtime-granularity rewrite).
public struct FileStamp: Equatable, Sendable {
    /// The file's modification date at stamp time.
    public let modifiedAt: Date
    /// The file's size in bytes at stamp time.
    public let size: Int

    /// Creates a stamp from an observed modification date and size.
    public init(modifiedAt: Date, size: Int) {
        self.modifiedAt = modifiedAt
        self.size = size
    }
}

// MARK: - FileSystemProbe

/// The HotStore's only window onto the file system.
///
/// All disk access performed by ``HotStore`` goes through this protocol, so
/// tests can substitute an in-memory fake and exercise every cache path —
/// cold read, hot hit, stale eviction, publish stamping — hermetically,
/// with no real files involved.
public protocol FileSystemProbe: Sendable {
    /// Returns the current freshness stamp of the file at `url`.
    /// - Throws: If the file does not exist or its attributes cannot be read.
    func stamp(of url: URL) throws -> FileStamp

    /// Reads the complete contents of the file at `url`.
    ///
    /// The returned `Data` must be a stable, self-contained copy: HotStore
    /// retains it in the cache, so it must not alias a mapping that mutates
    /// if the underlying file is rewritten.
    /// - Throws: If the file cannot be read.
    func read(_ url: URL) throws -> Data
}

/// The production ``FileSystemProbe``: real files via `FileManager` / `Data`.
public struct RealFileSystemProbe: FileSystemProbe {
    /// Creates a probe over the real file system.
    public init() {}

    public func stamp(of url: URL) throws -> FileStamp {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return FileStamp(modifiedAt: modified, size: size)
    }

    public func read(_ url: URL) throws -> Data {
        // Deliberately NOT `.mappedIfSafe`: the cache retains this Data, and
        // a memory-mapped buffer would silently change (or fault) if the file
        // on disk were rewritten — violating the tier-1 byte-identity
        // guarantee. A private copy is the only safe thing to cache.
        try Data(contentsOf: url)
    }
}

// MARK: - Errors

/// Errors thrown by HotStore operations that are cache-specific.
///
/// Read-path methods (`text(at:)`, `data(at:)`, `frame(at:key:...)`)
/// deliberately do **not** throw cache-specific errors — their miss path is
/// a plain disk read and only surfaces the disk read's own errors. Only the
/// materialized-view API can fail for a cache-shaped reason.
public enum HotStoreError: Error, Equatable {
    /// ``HotStore/view(name:over:plan:)`` was asked to build a view over a
    /// parent frame that is not resident (never published, evicted, or found
    /// stale). Re-publish or re-load the parent, then retry the view.
    case missingParent(FrameKey)
}
