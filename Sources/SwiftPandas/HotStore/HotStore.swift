// ===----------------------------------------------------------------------===//
//
// HotStore.swift
// SwiftPandas — HotStore submodule
//
// The one-call hot-check: composes FrameCache (tier 2, parsed frames) and
// TextCache (tier 1, raw bytes) over one shared budget, plus file-stamp
// freshness validation and write-time publishing.
//
// ## The hot-check pattern
//
// A pipeline that is temporally decomposed around disk — every stage writes
// a file the next stage immediately re-reads — replaces each read with:
//
//     let text = try store.text(at: url)          // instead of String(contentsOf:)
//     let df   = try store.frame(at: url, key: k) { try CSVReader().read(from: $0) }
//
// and each write publishes what the writer already holds:
//
//     try body.write(to: url, atomically: true, encoding: .utf8)
//     await store.publishText(body, for: url)      // stamp taken post-write
//
// The consumer's hot path skips disk and parse entirely; its miss path IS
// the plain disk path — same bytes, same failure modes.
//
// ===----------------------------------------------------------------------===//

import Foundation

/// A two-tier, budget-bounded, file-stamp-validated hot cache.
///
/// `HotStore` composes a ``TextCache`` (raw bytes, byte-identity guaranteed)
/// and a ``FrameCache`` (parsed ``DataFrame`` values) over **one shared byte
/// budget** — frames and bytes compete fairly, coldest unpinned entry
/// evicted first. On top of the tiers it adds file-backed freshness: every
/// file-keyed entry carries a ``FileStamp`` (mtime + size), and every hot
/// read re-validates the stamp before serving from memory.
///
/// ## Guarantees (the ones a byte-parity argument may lean on)
///
/// 1. **Never stale.** ``text(at:)`` / ``data(at:)`` / ``frame(at:key:pinned:reader:)``
///    return content identical to what a plain disk read would return at the
///    moment of the last stamp validation. A stamp mismatch **always** evicts
///    and re-reads — a hot read can never return stale bytes.
/// 2. **The miss path IS the disk path.** On a cold or stale key these
///    methods read the file (or run your `reader`) exactly as calling code
///    would without the cache, and propagate that read's own errors
///    unchanged. There are no cache-specific errors on the read path.
/// 3. **Publishes never hurt the writer.** ``publishText(_:for:)`` and
///    friends stamp against the file's post-write stamp; if the stamp cannot
///    be read the publish is dropped silently — counted in
///    ``CacheStats/droppedPublishes``, never thrown into the writer.
///
/// ## Ownership split
///
/// The store owns caching mechanics: budget, LRU, pinning, stamps, eviction,
/// statistics. The caller owns policy: which files, which keys/tags, what to
/// pin, and when a writer publishes.
public actor HotStore {
    /// Tier 2: parsed frames. Shares this store's budget pool.
    public let frames: FrameCache
    /// Tier 1: raw bytes. Shares this store's budget pool.
    public let texts: TextCache

    private let ledger: HotBudget
    private let probe: FileSystemProbe

    /// Creates a hot store with a shared byte budget for both tiers.
    ///
    /// - Parameters:
    ///   - budgetBytes: Maximum resident bytes across frames and bytes.
    ///   - probe: File-system access used for stamps and raw reads. Tests
    ///     pass a fake to run hermetically; production uses the default
    ///     ``RealFileSystemProbe``.
    ///   - onEvict: Optional hook fired once per entry that leaves the cache.
    public init(
        budgetBytes: Int,
        probe: FileSystemProbe = RealFileSystemProbe(),
        onEvict: (@Sendable (FrameKey, EvictionReason) -> Void)? = nil
    ) {
        let ledger = HotBudget(budgetBytes: budgetBytes, onEvict: onEvict)
        self.ledger = ledger
        self.probe = probe
        self.frames = FrameCache(ledger: ledger)
        self.texts = TextCache(ledger: ledger)
    }

    // MARK: - File keys

    /// The tier-1 key a file URL caches under: its standardized path.
    private nonisolated func fileKey(_ url: URL) -> FrameKey {
        FrameKey(name: url.standardizedFileURL.path)
    }

    // MARK: - Hot-check reads

    /// Returns the file's bytes — from memory when fresh, from disk otherwise.
    ///
    /// The stamp is taken **before** the disk read, so a file rewritten
    /// between stamp and read caches as already-stale and re-reads on the
    /// next access (the safe direction). If the stamp itself cannot be read,
    /// the disk read still proceeds and its result is returned uncached, so
    /// the failure modes are exactly those of a plain `Data(contentsOf:)`.
    ///
    /// - Throws: Only errors from the underlying disk read (guarantee 2).
    public func data(at url: URL) throws -> Data {
        let slot = SlotKey(tier: .text, key: fileKey(url))
        let stamp = try? probe.stamp(of: url)
        if case .bytes(let cached)? = ledger.getIfFresh(slot, stamp: stamp) {
            return cached
        }
        let fresh = try probe.read(url)
        if let stamp {
            _ = ledger.put(slot, payload: .bytes(fresh), bytes: fresh.count,
                           pinned: false, stamp: stamp, url: url)
        }
        return fresh
    }

    /// Returns the file's content as a UTF-8 string — from memory when
    /// fresh, from disk otherwise.
    ///
    /// **Byte identity:** the returned string decodes exactly the bytes a
    /// plain disk read would return at the moment of the last stamp
    /// validation — no normalization of line endings, whitespace, or BOMs
    /// (a UTF-8 BOM is preserved as a leading U+FEFF). For valid UTF-8 the
    /// result equals `String(contentsOf: url, encoding: .utf8)`. Invalid
    /// UTF-8 sequences decode to U+FFFD — deterministically, so cold and
    /// warm reads are always identical. When the literal bytes matter, use
    /// ``data(at:)``.
    ///
    /// - Throws: Only errors from the underlying disk read (guarantee 2).
    public func text(at url: URL) throws -> String {
        String(decoding: try data(at: url), as: UTF8.self)
    }

    /// Returns the parsed frame for a file — from memory when fresh,
    /// otherwise by running `reader` against the file.
    ///
    /// This is the tier-2 hot-check: a cache hit skips both the disk read
    /// and the parse. A stamp mismatch evicts the entry (and any views
    /// derived from it) and re-runs `reader`; `reader`'s errors propagate
    /// unchanged, and its result is cached only when the file's stamp was
    /// readable.
    ///
    /// - Parameters:
    ///   - url: The file whose freshness governs the cached frame.
    ///   - key: The caller's identity for the frame (name + taxonomy tags).
    ///   - pinned: Pin the freshly-cached entry (see ``FrameCache`` pinning
    ///     semantics). An already-fresh cached entry keeps its pin state.
    ///   - reader: How to produce the frame from the file on a miss — e.g.
    ///     `{ try CSVReader.strict(columnTypes: contract).read(from: $0) }`.
    /// - Throws: Only errors thrown by `reader` (guarantee 2).
    public func frame(
        at url: URL,
        key: FrameKey,
        pinned: Bool = false,
        reader: @Sendable (URL) throws -> DataFrame
    ) throws -> DataFrame {
        let slot = SlotKey(tier: .frame, key: key)
        let stamp = try? probe.stamp(of: url)
        if case .frame(let cached)? = ledger.getIfFresh(slot, stamp: stamp) {
            return cached
        }
        let df = try reader(url)
        if let stamp {
            _ = ledger.put(slot, payload: .frame(df), bytes: df.estimatedBytes,
                           pinned: pinned, stamp: stamp, url: url)
        }
        return df
    }

    // MARK: - Write-time publish

    /// Publishes text a writer already holds, stamped against the file's
    /// **post-write** stamp, so the next ``text(at:)`` for `url` is a hot hit.
    ///
    /// Call *after* the bytes are durably on disk. If the stamp cannot be
    /// read (file missing, permission change, racing delete) the publish is
    /// dropped silently — counted in ``CacheStats/droppedPublishes``, never
    /// thrown into the writer (guarantee 3). The consumer then simply takes
    /// the plain disk path.
    public func publishText(_ s: String, for url: URL) {
        publishData(Data(s.utf8), for: url)
    }

    /// Publishes raw bytes a writer already holds, stamped against the
    /// file's post-write stamp. Same drop semantics as ``publishText(_:for:)``.
    public func publishData(_ data: Data, for url: URL) {
        guard let stamp = try? probe.stamp(of: url) else {
            ledger.noteDroppedPublish()
            return
        }
        _ = ledger.put(SlotKey(tier: .text, key: fileKey(url)),
                       payload: .bytes(data), bytes: data.count,
                       pinned: false, stamp: stamp, url: url)
    }

    /// Publishes a frame a producer already holds.
    ///
    /// - When `url` is non-nil the entry is stamped against that file's
    ///   post-write stamp and will satisfy ``frame(at:key:pinned:reader:)``
    ///   hot-checks for it; an unreadable stamp drops the publish silently
    ///   (counted, never thrown — guarantee 3).
    /// - When `url` is nil the frame is cached unstamped: retrievable via
    ///   ``get(_:)`` / ``FrameCache/get(_:)`` and usable as a view parent,
    ///   but a file-validated hot-check will treat it as unverifiable and
    ///   re-read.
    public func publishFrame(_ df: DataFrame, key: FrameKey, stampedTo url: URL?, pinned: Bool = false) {
        let slot = SlotKey(tier: .frame, key: key)
        if let url {
            guard let stamp = try? probe.stamp(of: url) else {
                ledger.noteDroppedPublish()
                return
            }
            _ = ledger.put(slot, payload: .frame(df), bytes: df.estimatedBytes,
                           pinned: pinned, stamp: stamp, url: url)
        } else {
            _ = ledger.put(slot, payload: .frame(df), bytes: df.estimatedBytes,
                           pinned: pinned, stamp: nil)
        }
    }

    // MARK: - Materialized views

    /// Returns a cached materialized view over a resident parent frame,
    /// computing (and caching) it on first access.
    ///
    /// The view's result is cached under the derived key
    /// `parent.name + "#" + name` (with the parent's tags) and registered as
    /// a dependent of the parent: it is auto-invalidated whenever the parent
    /// is evicted, invalidated, replaced, or found stale. If the parent is
    /// file-stamped, this method re-validates the stamp before serving the
    /// view, so a view can never outlive its parent's freshness.
    ///
    /// Typical use: per-template supplementary join indexes become views
    /// over one parsed parent —
    /// ```swift
    /// let ageing = try await store.view(name: "template-42", over: supplementaryKey) {
    ///     $0.filter(col("template") == "42")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - name: The view's name, unique per parent.
    ///   - parent: Key of the resident parent frame.
    ///   - plan: The lazy query defining the view; it is optimized and
    ///     collected once, on the computing access.
    /// - Throws: ``HotStoreError/missingParent(_:)`` if the parent is not
    ///   resident (never published, evicted, or found stale just now).
    ///   Re-load the parent, then retry.
    public func view(
        name: String,
        over parent: FrameKey,
        plan: @Sendable (LazyDataFrame) -> LazyDataFrame
    ) throws -> DataFrame {
        let parentSlot = SlotKey(tier: .frame, key: parent)

        // Re-validate a file-bound parent before trusting anything derived
        // from it. A stale parent (and, by cascade, all its views) is
        // evicted here, and the caller is told to re-load.
        if let binding = ledger.bindingOf(parentSlot),
           let boundURL = binding.url {
            let current = try? probe.stamp(of: boundURL)
            if current == nil || current != binding.stamp {
                ledger.evictStale(parentSlot)
                throw HotStoreError.missingParent(parent)
            }
        }

        let derivedKey = FrameKey(name: parent.name + "#" + name, tags: parent.tags)
        let derivedSlot = SlotKey(tier: .frame, key: derivedKey)
        if case .frame(let cached)? = ledger.get(derivedSlot) {
            return cached
        }

        guard case .frame(let parentDF)? = ledger.get(parentSlot) else {
            throw HotStoreError.missingParent(parent)
        }
        let result = plan(parentDF.lazy()).collect()
        _ = ledger.put(derivedSlot, payload: .frame(result),
                       bytes: result.estimatedBytes,
                       pinned: false, stamp: nil, dependentOn: parentSlot)
        return result
    }

    // MARK: - Pass-throughs

    /// Fetches a cached frame by key (tier 2). See ``FrameCache/get(_:)``.
    public func get(_ key: FrameKey) -> DataFrame? {
        guard case .frame(let df)? = ledger.get(SlotKey(tier: .frame, key: key)) else {
            return nil
        }
        return df
    }

    /// Removes the entry under `key` from **both** tiers, cascading to any
    /// materialized views. No-op where absent.
    public func invalidate(_ key: FrameKey) {
        ledger.invalidate(SlotKey(tier: .frame, key: key))
        ledger.invalidate(SlotKey(tier: .text, key: key))
    }

    /// A snapshot of the shared budget pool (both tiers).
    public func stats() -> CacheStats {
        ledger.stats()
    }

    /// Replaces the shared byte budget and re-enforces it immediately.
    public func setBudget(bytes: Int) {
        ledger.setBudget(bytes: bytes)
    }

    /// Drops every entry in both tiers and resets byte accounting. Does not
    /// fire `onEvict`; preserves hit/miss/eviction counters.
    public func removeAll() {
        ledger.removeAll()
    }
}
