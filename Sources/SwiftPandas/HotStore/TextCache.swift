// ===----------------------------------------------------------------------===//
//
// TextCache.swift
// SwiftPandas — HotStore submodule
//
// Tier 1 of the hot cache: raw bytes / text, with a hard byte-identity
// guarantee. What comes out is exactly what went in — no normalization ever.
//
// ===----------------------------------------------------------------------===//

import Foundation

/// A budget-bounded, LRU-evicting in-memory cache of raw file bytes.
///
/// `TextCache` is tier 1 of the HotStore. It exists for the byte-parity
/// case: a stage that wrote a file (or downloaded it) can publish the exact
/// bytes, and any later stage that would re-read the file gets those exact
/// bytes back. **Byte identity is guaranteed** — the cache never trims,
/// transcodes, normalizes line endings, or strips BOMs. ``text(_:)`` decodes
/// the stored bytes as UTF-8 on the way out (invalid sequences become
/// U+FFFD), but the stored `Data` itself is untouched and retrievable
/// verbatim via ``data(_:)``.
///
/// Budget, LRU, pinning, oversize refusal, and statistics semantics are
/// identical to ``FrameCache``. When composed inside a ``HotStore`` the two
/// tiers share one budget pool — frames and bytes compete fairly.
public actor TextCache {
    internal let ledger: HotBudget

    /// Creates a standalone text cache with its own byte budget.
    ///
    /// - Parameters:
    ///   - budgetBytes: Maximum resident bytes before LRU eviction begins.
    ///   - onEvict: Optional hook fired once per entry that leaves the cache.
    public init(budgetBytes: Int, onEvict: (@Sendable (FrameKey, EvictionReason) -> Void)? = nil) {
        self.ledger = HotBudget(budgetBytes: budgetBytes, onEvict: onEvict)
    }

    /// Creates a tier view over a shared ledger (used by ``HotStore``).
    internal init(ledger: HotBudget) {
        self.ledger = ledger
    }

    /// Stores raw bytes under `key`, evicting cold entries if needed.
    ///
    /// The bytes are stored verbatim and will be returned verbatim.
    ///
    /// - Returns: ``PutOutcome/stored``, ``PutOutcome/replaced``, or
    ///   ``PutOutcome/refusedOversize`` (nothing stored) if `data` alone
    ///   exceeds the budget.
    @discardableResult
    public func put(_ data: Data, key: FrameKey, pinned: Bool = false) -> PutOutcome {
        ledger.put(
            SlotKey(tier: .text, key: key),
            payload: .bytes(data),
            bytes: data.count,
            pinned: pinned,
            stamp: nil
        )
    }

    /// Fetches the exact bytes stored under `key` (LRU touch; counted as a
    /// hit or miss).
    public func data(_ key: FrameKey) -> Data? {
        guard case .bytes(let d)? = ledger.get(SlotKey(tier: .text, key: key)) else {
            return nil
        }
        return d
    }

    /// Fetches the bytes stored under `key`, decoded as UTF-8.
    ///
    /// Decoding is the only transformation applied, and it is deterministic:
    /// the same stored bytes always produce the same string, so repeated hot
    /// reads are identical. Invalid UTF-8 sequences decode to U+FFFD; a UTF-8
    /// BOM is preserved as a leading U+FEFF. Use ``data(_:)`` when the
    /// literal bytes matter.
    public func text(_ key: FrameKey) -> String? {
        guard let d = data(key) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Removes the entry under `key`. No-op if absent.
    public func invalidate(_ key: FrameKey) {
        ledger.invalidate(SlotKey(tier: .text, key: key))
    }

    /// Marks the entry under `key` as never-evictable. No-op if absent.
    public func pin(_ key: FrameKey) {
        ledger.pin(SlotKey(tier: .text, key: key))
    }

    /// Makes the entry under `key` evictable again. No-op if absent.
    public func unpin(_ key: FrameKey) {
        ledger.unpin(SlotKey(tier: .text, key: key))
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
