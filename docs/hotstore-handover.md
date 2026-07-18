# SwiftPandas v0.7.0-beta — Hot-Cache Handover (engine integration)

**Audience:** the engine's hot-cache workstream. This document is the contract the engine plan consumes; engine work starts here.
**Version:** `0.6.2-beta → 0.7.0-beta` (additive — the engine builds against the bumped package with zero code changes; migration is opt-in per call site).
**Deep dive:** `docs/hotstore.md`. **Tests:** `Tests/SwiftPandasTests/{HotStoreTests,CSVContractTests,JoinIndexAndMemoryTests}.swift`.

---

## 1. Changelog — every new public API

### HotStore submodule (`Sources/SwiftPandas/HotStore/`)
| API | What it is |
|---|---|
| `FrameKey(name:tags:)` | Cache identity; taxonomy travels in `tags` (caller data) |
| `PutOutcome` | `.stored \| .refusedOversize \| .replaced` |
| `EvictionReason` | `.budget \| .stale \| .invalidated` |
| `CacheStats` | `hits, misses, evictions, droppedPublishes, bytes, entryCount, highWaterBytes, budgetBytes` |
| `FileStamp(modifiedAt:size:)` | Freshness fingerprint |
| `FileSystemProbe` / `RealFileSystemProbe` | Disk abstraction; tests inject a fake |
| `HotStoreError.missingParent` | Only cache-shaped error, thrown by `view` alone |
| `actor FrameCache` | `init(budgetBytes:onEvict:)`, `put(_:key:pinned:) -> PutOutcome`, `get`, `invalidate`, `pin`, `unpin`, `stats`, `setBudget`, `removeAll` |
| `actor TextCache` | Same shape over `Data`; `data(_:)`, `text(_:)` |
| `actor HotStore` | `init(budgetBytes:probe:onEvict:)`; `text(at:)`, `data(at:)`, `frame(at:key:pinned:reader:)`; `publishText(_:for:)`, `publishData(_:for:)`, `publishFrame(_:key:stampedTo:pinned:)`; `view(name:over:plan:)`; pass-throughs `get/invalidate/stats/setBudget/removeAll`; tier handles `.frames` / `.texts` |

### Contract-driven CSV reading
| API | What it is |
|---|---|
| `CSVReader.strict(columnTypes: [String: DTypeEnum], separator:header:naValues:)` | Never infers; unlisted columns stay `.string` |
| `CSVReader.allStrings` | Every column `.string` |
| `CSVReader.ParseMode` / `CSVReader.mode` | `.infer` (default, unchanged) / `.strict` / `.allStrings` |
| `CSVReader.readWithReport(from: String\|URL)` | `(frame, [ColumnParseFailure])` |
| `ColumnParseFailure` | `column, declaredType, failedCount, firstFailedRow, firstFailedValue` — moved into the package |
| `CSVReader.rows(url:) -> CSVRowSequence` | Streaming rows over a memory-mapped file; constant memory; `header` + `columnCount` exposed |
| `CSVReader.dimensions(url:)` (+ `separator:header:` variant) | `(rows, cols)` in one quote-aware pass, zero cell parsing |
| `CSVLine.parse(_:)` (+ separator variant), `CSVLine.format(_:quoting:)`, `CSVLine.escapeField(_:quoting:)` | THE canonical RFC-4180 codec |
| `CSVQuoting` | `.minimal` (RFC 4180) / `.all` (QUOTE_ALL) |
| `CSVWriter(quoting:)`, `DataFrame.toCSV(..., quoting:)` | Write-side symmetry |

### DataFrame utilities
| API | What it is |
|---|---|
| `DataFrame.index(on: String)` / `index(on: [String], separator:)` | Row indexes, **last-row-wins** |
| `DataFrame.lookupTable(key:value:)` | `[String: String]` join dict, **last-row-wins** |
| `DataFrame.estimatedBytes` | Accuracy pass: string columns now model slot + heap payload + header (±20% bound, tested) |

### Behavior changes (deliberate, byte-parity-reviewed)
- **Duplicate CSV headers now merge last-wins in every read mode** (previously the frame carried a duplicate name whose lookups already resolved to the last column's data — the display/name list was inconsistent). Matches `columnDTypeMap` last-wins.
- **Minimal-mode CSVWriter also quotes fields containing a bare CR** (RFC 4180 compliance; previously only separator/quote/LF).
- `StringArray.nbytes` grew (slot + header modeling): budget numbers based on it become more honest, not different in kind.

## 2. Migration table — engine call site → package replacement

| Engine call site (§2 inventory) | Replacement |
|---|---|
| `GenericDataFrameProcessor.swift:305`, `Dataframe.swift:1976` — melt re-reads `source.csv` the source stage just wrote | Source stage: `publishText(sourceText, for: sourceURL)` after write. Melt: `try await store.text(at: sourceURL)` |
| `Executor+AnalyticalMerge.swift:111` — merge re-reads chunk CSVs | Chunk writers publish per-chunk (`publishText`/`publishFrame(stampedTo:)`); merge hot-checks each |
| `Executor+CSVPipeline.swift:45` (aggregate), `JobAllocator+Database.swift:1067` (upload, duplicate of STEP 9's read), a2a — all re-read `dataframe_full.csv` | Producer: `publishFrame(df, key: fullKey, stampedTo: fullURL, pinned: true)`. All three consumers: `store.frame(at: fullURL, key: fullKey, reader: …)` — the duplicate upload read collapses into a hit. a2a may prefer `store.data(at:)` (tier 1) for byte-level certification |
| `AfterPhaseEvaluator.swift:166`, `Executor+CSVPipeline.swift:245` — after-phase + archive summary re-read `dataframe_aggregated.csv` | Same publish/hot-check pair on the aggregated frame |
| `AfterPhaseEvaluator+CSV.swift:316` and `:391` — final dataframe read **twice** in STEP 5 | One `store.frame(at:key:reader:)`; second call is a hit |
| `AfterPhaseEvaluator+Arithmetic.swift:196-238` — supplementary files re-parsed **per template**, per-evaluator cache | Parse once, `publishFrame(supp, key: suppKey, stampedTo: url, pinned: true)`; per-template slices become `store.view(name: "template-\(id)", over: suppKey) { plan }`. Delete the per-evaluator caches |
| `LA01Source.swift:340` (and FA/MA/PA/WA analogs) — re-read files just written **only to count rows/cols** | `CSVReader.dimensions(url:)` — one streaming pass, no cell parsing (or count from the in-memory frame before writing) |
| ≥9 hand-rolled CSV parsers copying `KOSource.parseCSV` semantics by comment (`LA01Metadata.swift:141-144`, `MA01Metadata.swift:43`, `PA01Metadata.swift:48`) | `CSVLine.parse(_:)` per record, or `CSVReader.rows(url:)` for streaming row walks — one canonical RFC-4180 implementation instead of comment-enforced copies |
| Engine `SwiftPandasLoader.makeColumn` + engine `ColumnParseFailure` | **Delete both.** `CSVReader.strict(columnTypes:)` + `readWithReport(from:)` — the numerification regression test now lives in the package (`CSVStrictReaderTests.test_allDigitIDs_stayStrings_underContract`) |
| Per-evaluator `[String: [String: String]]` supplementary join dicts; tensor `SideTable.fromCSV` build pattern | **Delete.** `df.lookupTable(key:value:)` / `df.index(on:)` — last-row-wins guaranteed |
| Engine QUOTE_ALL writer (source.csv) and minimal writer (demo CSV) conventions | `CSVWriter(quoting: .all)` / `.minimal`; `CSVLine.escapeField` for one-off fields |

## 3. Byte-compatibility guarantees the engine may rely on

*(These are stated verbatim in the API doc comments; this section is the citable list for the a2a parity argument.)*

1. **Tier-1 byte identity.** `TextCache` returns stored bytes verbatim — no normalization ever. `HotStore.data(at:)` returns the file's exact bytes; `text(at:)` is exactly those bytes decoded as UTF-8 (BOM preserved as U+FEFF, invalid sequences → U+FFFD deterministically, identical cold and warm; equals `String(contentsOf:url,encoding:.utf8)` for valid UTF-8).
2. **Stamp semantics.** Freshness = mtime + size equality. A stamp mismatch always evicts and re-reads before anything is served; stamps are taken *before* miss reads and *after* publishes (both the safe directions). Same-stamp same-size rewrites are the documented blind spot.
3. **Miss = disk.** Hot-check miss paths perform the plain disk read / caller `reader` and propagate its errors unchanged; no cache-specific read errors exist.
4. **Strict parsing.** Declared columns parse to declared dtypes; **unlisted columns stay `.string`** — auto-numerification cannot happen under a contract. Failures become NA and are reported per column.
5. **Duplicate headers: last-wins** (data and position), all read modes.
6. **Join utilities: last-row-wins**, keys/values rendered as CSV round-trip text (integral doubles collapse `42.0 → "42"`, NA → `""`).
7. **Quoting modes.** `.minimal` = RFC 4180 (quote only on separator/quote/LF/CR); `.all` = QUOTE_ALL including header names and index labels; internal quotes double in both; `CSVLine.parse` reads either mode identically. Round-trip `parse(format(f, q)) == f` holds for both modes.
8. **Streaming equivalence.** `rows(url:)` yields exactly the data rows of a full read (RFC-4180, quoted newlines, CRLF, short-row padding to `columnCount`); `dimensions(url:)` matches a full parse's `(rowCount, columnCount)` without parsing a cell.
9. **`estimatedBytes`** is specified within ±20% of measured allocations for representative string/double/int frames (model documented on the property; bound asserted in `EstimatedBytesTests`).

## 4. What the package explicitly does NOT own

- **Keys/taxonomy** — `FrameKey.tags` content is engine data (kind/integration/jobId/templateId are engine concepts).
- **Pin policy** — which kinds pin, and the session analytics store's pinned-from-splash set, are engine decisions.
- **Publish seams** — the package provides `publish*`; *where* writers call them is engine integration semantics.
- **Parity gates** — a2a certification and byte-parity gating remain engine responsibilities; this document only supplies the guarantees they cite.
- **Column meaning** — dtype contracts (`columnTypes`) are engine knowledge; the package only enforces them.
