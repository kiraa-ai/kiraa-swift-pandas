# HotStore — the SwiftPandas in-process analytics cache

*Introduced in v0.7.0-beta. Source: `Sources/SwiftPandas/HotStore/`. Tests: `Tests/SwiftPandasTests/HotStoreTests.swift` (hermetic — all disk access goes through a `FileSystemProbe` fake).*

HotStore turns SwiftPandas from a parsing library into a small in-process **analytics database**: files and parsed frames stay resident in memory under one byte budget, consumers check memory before touching disk, and writers publish what they already hold so the next reader never pays for the round trip.

## Why it exists

Pipelines that are *temporally decomposed around disk* — every stage writes a CSV the next stage immediately re-reads — pay the full read+parse cost (~40–45 s per GB of CSV) over and over for bytes that were in memory moments earlier. HotStore removes that tax with two patterns:

1. **Memory-first hot-check** — consumers ask the store first; the store validates freshness against the file's stamp and only falls through to disk when cold or stale.
2. **Write-time publish** — writers hand the store the bytes/frame they just wrote, stamped against the file's post-write stamp, making the consumer's next read a pure memory hit.

## Architecture: two tiers, one budget

```
             ┌─────────────────────────────────────────┐
             │                HotStore                  │
             │  stamp validation · publish · views      │
             │                                          │
             │  ┌───────────────┐  ┌────────────────┐  │
             │  │   TextCache   │  │   FrameCache    │  │
             │  │ tier 1: bytes │  │ tier 2: frames  │  │
             │  └───────┬───────┘  └───────┬─────────┘  │
             │          └────── shared ─────┘            │
             │           byte budget (LRU)               │
             └─────────────────────────────────────────┘
```

- **Tier 1 (`TextCache`)** holds raw `Data` with a hard **byte-identity guarantee**: what comes out is exactly what went in — no line-ending normalization, no BOM stripping, no trimming, ever.
- **Tier 2 (`FrameCache`)** holds parsed `DataFrame`s sized by `DataFrame.estimatedBytes`, so a hot consumer skips the parse as well as the read.
- Both tiers share **one budget ledger**: frames and bytes compete fairly, and eviction is global LRU (coldest unpinned entry first, regardless of tier).

`FrameCache` and `TextCache` can also be created standalone with their own budgets.

## Keys

A `FrameKey` is `name` + `tags`. The package never interprets either — a caller's taxonomy (kind / integration / job id / template id, …) travels in `tags` as caller data. Same name + different tags = different entry.

## Budget, pinning, eviction

| Rule | Behavior |
|---|---|
| Over budget | Evict unpinned entries, coldest `lastAccessedAt` first, until under budget |
| Oversize value | `put` returns `.refusedOversize`; **never stored** (a giant frame can't flush the cache) |
| Pinned entries | Never evicted; pinned totals **may exceed the budget** — that is an explicit caller choice |
| `setBudget` | Re-enforces immediately (shrink = instant eviction) |
| `unpin` while over budget | The entry becomes evictable immediately |

Every departure fires the optional `onEvict` hook with a reason: `.budget`, `.stale`, or `.invalidated`. `removeAll()` is a reset, not an eviction event — it does not fire the hook.

## The hot-check pattern (freshness)

Every file-keyed entry carries a `FileStamp` (mtime + size). The three guarantees consumers — and byte-parity arguments — may rely on:

1. **Never stale.** `text(at:)` / `data(at:)` / `frame(at:key:reader:)` return content identical to a plain disk read at the moment of the last stamp validation. A stamp mismatch **always** evicts and re-reads.
2. **The miss path IS the disk path.** Cold or stale keys read the file (or run your `reader`) exactly as code without the cache would, and propagate that read's own errors unchanged. There are no cache-specific errors on the read path.
3. **Publishes never hurt the writer.** A publish whose stamp can't be read is dropped silently — counted in `stats().droppedPublishes`, never thrown.

```swift
let store = HotStore(budgetBytes: 8 << 30)   // 8 GiB shared pool

// Consumer stage — hot-check instead of String(contentsOf:):
let text = try await store.text(at: sourceURL)

// Hot-check with parse elision (tier 2):
let df = try await store.frame(at: fullURL,
                               key: FrameKey(name: "dataframe_full", tags: ["jobId": jobId])) {
    try CSVReader.strict(columnTypes: contract).read(from: $0)
}
```

## The write-time publish pattern

```swift
// Writer stage — after the bytes are durably on disk:
try body.write(to: url, atomically: true, encoding: .utf8)
await store.publishText(body, for: url)              // stamped post-write

// Producer that already holds the parsed frame:
try CSVWriter(quoting: .all).write(df, to: url)
await store.publishFrame(df, key: key, stampedTo: url)
```

`publishFrame(_:key:stampedTo: nil)` caches an unstamped frame: fetchable by key and usable as a view parent, but a file-validated hot-check treats it as unverifiable and re-reads.

## Materialized views

A view is a cached lazy-query result over a resident parent frame:

```swift
// One parsed supplementary file, N per-template slices — each computed once:
let slice = try await store.view(name: "template-\(id)", over: supplementaryKey) {
    $0.filter(col("template") == id)
}
```

- Cached under the derived key `parent.name + "#" + name` (parent's tags).
- **Auto-invalidated** whenever the parent is evicted, invalidated, replaced, or found stale — a view can never outlive its parent's freshness. If the parent is file-stamped, `view` re-validates the stamp before serving.
- A missing/stale parent throws `HotStoreError.missingParent` — re-load the parent, retry the view.

## Statistics

`stats()` (same combined numbers from any tier of a composed store): `hits`, `misses`, `evictions`, `droppedPublishes`, `bytes`, `entryCount`, `highWaterBytes`, `budgetBytes`.

## Worked example: a three-stage pipeline

```swift
let store = HotStore(budgetBytes: 12 << 30)

// STAGE 1 — source stage writes source.csv (~1 GB) and publishes it.
try sourceText.write(to: sourceURL, atomically: true, encoding: .utf8)
await store.publishText(sourceText, for: sourceURL)

// STAGE 2 — melt re-"reads" source.csv: memory hit, zero disk.
let raw = try await store.text(at: sourceURL)
let melted = transform(raw)
try CSVWriter().write(melted, to: fullURL)
await store.publishFrame(melted, key: fullKey, stampedTo: fullURL, pinned: true)

// STAGE 3 — aggregate, upload, and a2a all consume the SAME resident frame.
let df = try await store.frame(at: fullURL, key: fullKey) {
    try CSVReader().read(from: $0)                 // never runs while fresh
}

// If anything rewrites fullURL out-of-band, the stamp mismatch forces a
// re-read — correctness never depends on pipeline discipline.
```

## What HotStore does *not* do

- **No disk persistence** of the cache, no cross-process sharing — it is a per-process store.
- **No policy.** Which files, which keys/tags, what to pin, and when writers publish belong to the caller.
- **No same-stamp rewrite detection**: freshness is mtime+size, the same contract build systems rely on.

See also `docs/hotstore-handover.md` for the v0.7.0-beta API changelog and engine migration table.
