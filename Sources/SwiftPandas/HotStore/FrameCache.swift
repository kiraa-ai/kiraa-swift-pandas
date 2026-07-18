// ===----------------------------------------------------------------------===//
//
// FrameCache.swift
// SwiftPandas — HotStore submodule
//
// Tier 2 of the hot cache: typed, parsed DataFrames kept resident under a
// byte budget with LRU eviction and pinning.
//
// ===----------------------------------------------------------------------===//

import Foundation

/// A budget-bounded, LRU-evicting in-memory cache of ``DataFrame`` values.
///
/// `FrameCache` is tier 2 of the HotStore: it holds *parsed* frames so that a
/// consumer stage can skip both the disk read and the parse when a producer
/// already materialized the frame. Entries are sized via
/// ``DataFrame/estimatedBytes`` and compete for one byte budget; when the
/// budget is exceeded, the coldest (least recently accessed) unpinned entry
/// is evicted first, repeatedly, until the pool fits.
///
/// ## Semantics the caller may rely on
/// - **Oversize refusal** — a frame larger than the entire budget is refused
///   (``PutOutcome/refusedOversize``) and never stored, so one giant frame
///   cannot flush the cache.
/// - **Pinning** — pinned entries are never evicted. Pinned bytes still count
///   toward the budget, and the pinned total may exceed the budget; that is
///   an explicit caller choice (pin policy belongs to the caller, not the
///   package).
/// - **Standalone or composed** — created directly, a `FrameCache` owns its
///   own budget. Created by a ``HotStore``, it shares one budget pool with
///   the store's ``TextCache`` (frames and raw bytes compete fairly), and
///   `stats()` reports the combined pool.
public actor FrameCache {
    internal let ledger: HotBudget

    /// Creates a standalone frame cache with its own byte budget.
    ///
    /// - Parameters:
    ///   - budgetBytes: Maximum resident bytes before LRU eviction begins.
    ///   - onEvict: Optional hook fired (outside any internal lock) once per
    ///     entry that leaves the cache, with the reason it left.
    public init(budgetBytes: Int, onEvict: (@Sendable (FrameKey, EvictionReason) -> Void)? = nil) {
        self.ledger = HotBudget(budgetBytes: budgetBytes, onEvict: onEvict)
    }

    /// Creates a tier view over a shared ledger (used by ``HotStore``).
    internal init(ledger: HotBudget) {
        self.ledger = ledger
    }

    /// Stores a frame under `key`, evicting cold entries if needed.
    ///
    /// - Returns: ``PutOutcome/stored`` for a new key,
    ///   ``PutOutcome/replaced`` if the key existed (any materialized views
    ///   over the old entry are invalidated), or
    ///   ``PutOutcome/refusedOversize`` if `df` alone exceeds the budget
    ///   (in which case nothing was stored).
    @discardableResult
    public func put(_ df: DataFrame, key: FrameKey, pinned: Bool = false) -> PutOutcome {
        ledger.put(
            SlotKey(tier: .frame, key: key),
            payload: .frame(df),
            bytes: df.estimatedBytes,
            pinned: pinned,
            stamp: nil
        )
    }

    /// Fetches the frame stored under `key`, refreshing its LRU position.
    /// Counts a hit or a miss in ``stats()``.
    public func get(_ key: FrameKey) -> DataFrame? {
        guard case .frame(let df)? = ledger.get(SlotKey(tier: .frame, key: key)) else {
            return nil
        }
        return df
    }

    /// Removes the entry under `key` (and any materialized views derived
    /// from it). No-op if absent.
    public func invalidate(_ key: FrameKey) {
        ledger.invalidate(SlotKey(tier: .frame, key: key))
    }

    /// Marks the entry under `key` as never-evictable. No-op if absent.
    public func pin(_ key: FrameKey) {
        ledger.pin(SlotKey(tier: .frame, key: key))
    }

    /// Makes the entry under `key` evictable again; it may be evicted
    /// immediately if the pool is over budget. No-op if absent.
    public func unpin(_ key: FrameKey) {
        ledger.unpin(SlotKey(tier: .frame, key: key))
    }

    /// A snapshot of the budget pool this cache participates in. When
    /// composed inside a ``HotStore`` the numbers cover both tiers.
    public func stats() -> CacheStats {
        ledger.stats()
    }

    /// Replaces the byte budget and re-enforces it immediately.
    public func setBudget(bytes: Int) {
        ledger.setBudget(bytes: bytes)
    }

    /// Drops every entry in the budget pool (both tiers when composed) and
    /// resets byte accounting. Does not fire `onEvict` and does not reset
    /// hit/miss/eviction counters.
    public func removeAll() {
        ledger.removeAll()
    }
}
