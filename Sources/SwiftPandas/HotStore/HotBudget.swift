// ===----------------------------------------------------------------------===//
//
// HotBudget.swift
// SwiftPandas — HotStore submodule
//
// The shared budget ledger behind FrameCache, TextCache, and HotStore.
//
// ## Why a lock-protected class and not an actor
//
// FrameCache, TextCache, and HotStore are actors; the ledger they share must
// be callable *synchronously* from all three (an actor cannot synchronously
// await another actor). A `NSLock`-protected final class gives every tier a
// synchronous, mutually-exclusive view of one entry table, one byte total,
// and one LRU clock — which is exactly what "frames and bytes compete fairly
// for one budget" requires. All public API remains actor-isolated; this class
// is an internal implementation detail.
//
// ## Data model
//
// One flat entry table keyed by (tier, FrameKey). Each entry records its
// payload (frame or bytes), size, pin state, last-access tick from a global
// monotonically increasing LRU clock, and an optional FileStamp binding it to
// a file's content at cache time. A dependents map records materialized views
// so they can be cascaded away when their parent leaves the cache for any
// reason.
//
// ===----------------------------------------------------------------------===//

import Foundation

/// Which tier an entry belongs to. Same `FrameKey` in different tiers is a
/// different entry (a file's raw bytes and its parsed frame coexist).
internal enum HotTier: Hashable {
    case frame
    case text
}

/// Full identity of a ledger entry: tier + caller key.
internal struct SlotKey: Hashable {
    let tier: HotTier
    let key: FrameKey
}

/// Type-erased cached value.
internal enum HotPayload {
    case frame(DataFrame)
    case bytes(Data)
}

/// One resident cache entry.
private struct HotEntry {
    var payload: HotPayload
    var bytes: Int
    var pinned: Bool
    var lastAccessTick: UInt64
    /// Freshness fingerprint of the file this entry was cached from, if any.
    /// Entries without a stamp can be fetched by key but never satisfy a
    /// file-validated hot-check (they are treated as unverifiable → stale).
    var stamp: FileStamp?
    /// The file this entry was stamped against, if any. Lets consumers
    /// (materialized views) re-validate the parent's freshness on access.
    var url: URL?
}

/// The shared cache engine: entry storage, LRU eviction, pinning, freshness
/// stamps, dependency cascade, and statistics — all under one lock.
///
/// Thread safety: every public method takes `lock` for the duration of the
/// mutation, collects any evictions into a local list, releases the lock, and
/// only then fires the `onEvict` hook — so the hook can safely call back into
/// the cache without deadlocking.
internal final class HotBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [SlotKey: HotEntry] = [:]
    /// parent slot → derived (materialized view) slots that must die with it.
    private var dependents: [SlotKey: Set<SlotKey>] = [:]
    /// derived slot → its parent, for cleanup when the view itself is removed.
    private var parentOf: [SlotKey: SlotKey] = [:]
    private var tick: UInt64 = 0
    private var budgetBytes: Int
    private var totalBytes = 0
    private var hits = 0
    private var misses = 0
    private var evictions = 0
    private var droppedPublishes = 0
    private var highWaterBytes = 0
    private let onEvict: (@Sendable (FrameKey, EvictionReason) -> Void)?

    init(budgetBytes: Int, onEvict: (@Sendable (FrameKey, EvictionReason) -> Void)?) {
        self.budgetBytes = max(0, budgetBytes)
        self.onEvict = onEvict
    }

    // MARK: - Store

    /// Inserts or replaces an entry, then enforces the budget.
    ///
    /// - Oversize refusal: a payload larger than the entire current budget is
    ///   never stored (`.refusedOversize`) — admitting it would flush every
    ///   other entry for a value that still couldn't stay resident.
    /// - Replacement cascades: replacing a parent invalidates its dependents,
    ///   because they were derived from content that no longer exists.
    /// - `dependentOn`: registers the new entry as a materialized view of the
    ///   given parent slot *atomically* with the insert, so a budget eviction
    ///   of the parent triggered by this very insert still cascades correctly.
    func put(
        _ slot: SlotKey,
        payload: HotPayload,
        bytes: Int,
        pinned: Bool,
        stamp: FileStamp?,
        url: URL? = nil,
        dependentOn parent: SlotKey? = nil
    ) -> PutOutcome {
        var fired: [(FrameKey, EvictionReason)] = []
        lock.lock()
        let outcome: PutOutcome
        if bytes > budgetBytes {
            outcome = .refusedOversize
        } else {
            let existed = entries[slot] != nil
            if existed {
                // Views derived from the old content are now meaningless.
                removeLocked(slot, reason: .invalidated, fired: &fired, countEviction: false)
            }
            tick &+= 1
            entries[slot] = HotEntry(
                payload: payload, bytes: bytes, pinned: pinned,
                lastAccessTick: tick, stamp: stamp, url: url
            )
            totalBytes += bytes
            highWaterBytes = max(highWaterBytes, totalBytes)
            if let parent {
                dependents[parent, default: []].insert(slot)
                parentOf[slot] = parent
            }
            evictToBudgetLocked(fired: &fired)
            // The just-inserted entry may itself have been evicted if
            // everything else was pinned; the outcome still reports the
            // store/replace that happened.
            outcome = existed ? .replaced : .stored
        }
        lock.unlock()
        fire(fired)
        return outcome
    }

    // MARK: - Fetch

    /// Plain fetch by key: LRU-touches on hit; counts a hit or a miss.
    func get(_ slot: SlotKey) -> HotPayload? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[slot] else {
            misses += 1
            return nil
        }
        hits += 1
        tick &+= 1
        entry.lastAccessTick = tick
        entries[slot] = entry
        return entry.payload
    }

    /// Stamp-validated fetch: returns the payload only when the entry's
    /// stored stamp equals `stamp`. A mismatched or absent stamp **always**
    /// evicts the entry (reason `.stale`, cascading to dependents) and
    /// reports a miss — a hot read can never return stale bytes.
    func getIfFresh(_ slot: SlotKey, stamp: FileStamp?) -> HotPayload? {
        var fired: [(FrameKey, EvictionReason)] = []
        lock.lock()
        var result: HotPayload?
        if var entry = entries[slot] {
            if let stamp, entry.stamp == stamp {
                hits += 1
                tick &+= 1
                entry.lastAccessTick = tick
                entries[slot] = entry
                result = entry.payload
            } else {
                removeLocked(slot, reason: .stale, fired: &fired)
                misses += 1
            }
        } else {
            misses += 1
        }
        lock.unlock()
        fire(fired)
        return result
    }

    /// The stored file binding (stamp + URL) for a slot, without touching
    /// LRU order or hit/miss counters. Returns `nil` when the slot is absent;
    /// returns `(nil, nil)` when the entry exists but is not file-bound.
    /// Used by ``HotStore/view(name:over:plan:)`` to verify a parent frame is
    /// still fresh before serving a view derived from it.
    func bindingOf(_ slot: SlotKey) -> (stamp: FileStamp?, url: URL?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[slot] else { return nil }
        return (entry.stamp, entry.url)
    }

    // MARK: - Removal

    /// Explicitly removes an entry (reason `.invalidated`), cascading to any
    /// materialized views derived from it. No-op if absent.
    func invalidate(_ slot: SlotKey) {
        var fired: [(FrameKey, EvictionReason)] = []
        lock.lock()
        removeLocked(slot, reason: .invalidated, fired: &fired)
        lock.unlock()
        fire(fired)
    }

    /// Removes an entry that was found stale (reason `.stale`), cascading to
    /// dependents. No-op if absent.
    func evictStale(_ slot: SlotKey) {
        var fired: [(FrameKey, EvictionReason)] = []
        lock.lock()
        removeLocked(slot, reason: .stale, fired: &fired)
        lock.unlock()
        fire(fired)
    }

    /// Drops every entry and resets byte accounting. Counters (hits, misses,
    /// evictions, high-water) are preserved; the `onEvict` hook is **not**
    /// fired — removeAll is a caller-requested reset, not an eviction event.
    func removeAll() {
        lock.lock()
        entries.removeAll()
        dependents.removeAll()
        parentOf.removeAll()
        totalBytes = 0
        lock.unlock()
    }

    // MARK: - Pinning

    /// Marks an entry as never-evictable. Pinned bytes still count toward the
    /// budget total, so pinning aggressively can push unpinned entries out —
    /// and pinned totals may exceed the budget: that is an explicit caller
    /// choice, not an error. No-op if the key is absent.
    func pin(_ slot: SlotKey) {
        lock.lock()
        entries[slot]?.pinned = true
        lock.unlock()
    }

    /// Clears the pin. The entry becomes evictable again; if the pool is
    /// currently over budget it may be evicted immediately.
    func unpin(_ slot: SlotKey) {
        var fired: [(FrameKey, EvictionReason)] = []
        lock.lock()
        entries[slot]?.pinned = false
        evictToBudgetLocked(fired: &fired)
        lock.unlock()
        fire(fired)
    }

    // MARK: - Budget & stats

    /// Replaces the byte budget and re-enforces it immediately (shrinking the
    /// budget evicts coldest-first right away).
    func setBudget(bytes: Int) {
        var fired: [(FrameKey, EvictionReason)] = []
        lock.lock()
        budgetBytes = max(0, bytes)
        evictToBudgetLocked(fired: &fired)
        lock.unlock()
        fire(fired)
    }

    /// Counts a publish that was dropped because its file stamp was
    /// unreadable (see ``HotStore/publishText(_:for:)``).
    func noteDroppedPublish() {
        lock.lock()
        droppedPublishes += 1
        lock.unlock()
    }

    /// Snapshot of all counters.
    func stats() -> CacheStats {
        lock.lock()
        defer { lock.unlock() }
        return CacheStats(
            hits: hits, misses: misses, evictions: evictions,
            droppedPublishes: droppedPublishes,
            bytes: totalBytes, entryCount: entries.count,
            highWaterBytes: highWaterBytes, budgetBytes: budgetBytes
        )
    }

    // MARK: - Internals (must hold lock)

    /// Evicts unpinned entries, coldest `lastAccessTick` first, until
    /// `totalBytes <= budgetBytes` or only pinned entries remain.
    private func evictToBudgetLocked(fired: inout [(FrameKey, EvictionReason)]) {
        while totalBytes > budgetBytes {
            var coldest: SlotKey?
            var coldestTick = UInt64.max
            for (slot, entry) in entries where !entry.pinned {
                if entry.lastAccessTick < coldestTick {
                    coldestTick = entry.lastAccessTick
                    coldest = slot
                }
            }
            guard let victim = coldest else { break } // everything left is pinned
            removeLocked(victim, reason: .budget, fired: &fired)
        }
    }

    /// Removes one entry plus its dependent views (recursively), collecting
    /// `onEvict` notifications. Dependents are reported with the same reason
    /// as the parent removal that triggered the cascade, except budget
    /// evictions, whose dependents report `.invalidated` (the view wasn't
    /// cold — it just lost its parent).
    private func removeLocked(
        _ slot: SlotKey,
        reason: EvictionReason,
        fired: inout [(FrameKey, EvictionReason)],
        countEviction: Bool = true
    ) {
        guard let entry = entries.removeValue(forKey: slot) else { return }
        totalBytes -= entry.bytes
        if countEviction { evictions += 1 }
        if countEviction { fired.append((slot.key, reason)) }
        if let parent = parentOf.removeValue(forKey: slot) {
            dependents[parent]?.remove(slot)
            if dependents[parent]?.isEmpty == true { dependents[parent] = nil }
        }
        if let children = dependents.removeValue(forKey: slot) {
            let childReason: EvictionReason = (reason == .budget) ? .invalidated : reason
            for child in children {
                removeLocked(child, reason: childReason, fired: &fired)
            }
        }
    }

    /// Fires collected eviction notifications outside the lock.
    private func fire(_ list: [(FrameKey, EvictionReason)]) {
        guard let onEvict, !list.isEmpty else { return }
        for (key, reason) in list {
            onEvict(key, reason)
        }
    }
}
