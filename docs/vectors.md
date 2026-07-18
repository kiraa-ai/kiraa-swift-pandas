# Vector Columns & Similarity Search (v0.8.0)

SwiftPandas 0.8.0 adds first-class vector-database functionality: a Float32
vector column type, deterministic top-K similarity search (CPU + Metal), and
the byte-deterministic **SPB** binary format. The design spec lives in
[vector-spec.md](vector-spec.md); this page is the usage reference and the
home of the normative numeric contracts.

## Quick start

```swift
import SwiftPandas

// A vector collection is just a DataFrame: id + metadata + vector column.
let df = DataFrame(columns: [
    ("id", .fromInts([1, 2, 3])),
    ("title", .fromStrings(["intro", "setup", "faq"])),
    ("embedding", try .fromVectors(embeddings, dims: 1024)),  // [[Float]]
])

// CRUD stays the immutable idiom:
let inserted = DataFrame.concat([df, newRows])      // insert
let deleted  = df.filter(mask: keepMask)            // delete
                                                    // update = rebuild/merge

// Top-K search (CPU by default — the bit-stable path).
var options = SearchOptions()
options.topK = 10
options.threshold = 0.75                            // cosine: keep score >= 0.75
let result = try df.similaritySearch(on: "embedding", query: queryVector, options: options)
result.frame        // matching rows + "__score" column, ranked best-first
result.backendUsed  // "cpu-vdsp" | "metal" — never silent

// Durable IO (CSV/JSON reject vector frames; SPB is the vector format).
try df.writeSPB(to: url)
let restored = try DataFrame.readSPB(from: url)
```

## The vector column

- `Column.floatVector` stores one flat, contiguous, row-major Float32 plane
  (`count × dims`) plus a validity bitmap — never array-of-arrays. Null rows
  are zero-filled (normative: it makes SPB bytes deterministic).
- `dims` is part of the dtype identity: `df.dtypes` reports
  `floatVector(1024)`, and columns of different dims never compare equal.
- Construction: `Column.fromVectors(_:dims:)`,
  `Column.fromOptionalVectors(_:dims:)`, `Series(vectors:dims:name:)`.
  Mismatched element counts throw `VectorError.dimensionMismatch`.
- Access: `series.vectorDims` (nil probe), `series.vector(at:)`,
  `series.vectors()`, and zero-copy `series.withUnsafeVectorPlane { plane, dims in ... }`.
- **Storage always holds raw vectors.** `normalizedL2()` is the only
  normalizer and always returns a new series; construction, IO, and search
  never normalize implicitly.

### Ops matrix

Carried through correctly: `filter(mask:)`, `takeRows`, `iloc`, `select`,
`drop`, `rename`, `head`/`tail`, `concat` (same-named vector columns must
share dims), `merge` (vectors pass through as payload), `estimatedBytes`,
`describe` (count/nulls/dims only).

Rejected: CSV/JSON serialization of vector frames (throwing entry points
throw `VectorError.unsupportedOperation`; `select`/`drop` the vector column
first as the escape hatch), vector columns as merge join keys or groupBy
keys, and scalar aggregations (skipped exactly as string columns are).

## Similarity search

`SearchOptions`: `metric` (`.cosine` default, `.dot`, `.euclidean`), `topK`
(> 0), `threshold` (cosine/dot keep `score >= t`; euclidean keep
`distance <= t`), `mask` (candidate pre-filter, length = rowCount), `backend`.

Semantics (all backends):

- Null vector rows and mask-false rows are excluded **before** scoring.
- Ranking is fully deterministic: primary by score in metric direction,
  ties broken by source row index ascending. `topK` truncates after
  threshold filtering.
- `similaritySearchBatch` is semantically identical to N sequential calls.
- An empty result is a valid outcome, not an error; every *misuse* throws a
  typed `VectorError` (or `DataFrameError.columnNotFound` for a missing
  column name).

### The numeric contract (normative)

Consumers may pin **bit-identical** scores on the CPU backend
(`backendUsed == "cpu-vdsp"`). The pinned Float32 order:

- **cosine**:
  1. `dot = vDSP_dotpr(query, candidate)` (Float)
  2. `nQ = vDSP_dotpr(query, query)`; `nC` = the per-row squared-norm cache
     computed at construction (bit-identical to on-the-fly `vDSP_dotpr(v, v)`)
  3. `denom = sqrt(nQ) * sqrt(nC)` (Float sqrts, Float multiply)
  4. `denom == 0 → score = 0.0`; else `score = Double(dot / denom)`
     (Float divide, then widen)
- **dot**: `score = Double(vDSP_dotpr(q, c))`
- **euclidean** (pinned float-order): `score = Double(sqrt(vDSP_distancesq(q, c)))`
  — the sqrt is applied in Float32, then widened.

No Double accumulation, no fused rearrangement, no epsilon guards.

Notes on the pins:

- "Identical vectors score exactly 1.0" holds under this order when the
  squared norm has an exact Float sqrt (e.g. `[3, 4]` → 25 → 5). For general
  vectors, `sqrt(n)²` may round one ulp away (e.g. `[1, 2, 3]` scores
  0.99999994) — the pinned order deliberately does not fudge this back.
- The vDSP pin holds on Apple platforms (`ACCELERATE_AVAILABLE`). Non-Apple
  builds use in-order scalar Float32 fallbacks: deterministic per platform,
  but not bit-identical across platforms.

### Backends

- `.cpu` — always available; the documented primary and the only bit-stable
  path.
- `.metal` — GPU batch cosine (**cosine-only in v1**; `.dot`/`.euclidean`
  throw `metalUnsupportedMetric`). Throws `metalUnavailable` when the
  device/pipeline is unusable (including `SWIFTPANDAS_DISABLE_METAL=1`).
  **Never falls back silently.** GPU scores agree with CPU within 1e-5
  absolute with identical ranking on non-degenerate data; GPU fma
  accumulation order may differ at ulp level.
- `.auto(gpuThreshold: 16_384)` — metal iff post-mask candidate count exceeds
  the threshold AND the pipeline is available; else cpu. Observable via
  `SearchResultFrame.backendUsed`.

Threshold/topK/tie-break always run on the CPU after the GPU score pass, so
ranking semantics exist in exactly one place.

## SPB binary format

`writeSPB(to:)` / `readSPB(from:)` — little-endian, magic `"SPB1"`,
formatVersion 1. Layout and canonical-form rules are documented in
`Sources/SwiftPandas/IO/SPB/SPBFormat.swift`.

- **Byte-deterministic**: two writes of equal frames are byte-identical (no
  timestamps, columnNames-ordered, null slots zeroed). Read→write is also
  byte-stable.
- **No partial loads**: every validation failure (bad magic, truncation,
  length overflow, bitmap tail bits, non-canonical null slots) throws
  `VectorError.corrupt(reason:)` before a DataFrame exists; files newer than
  version 1 throw `versionUnsupported`.
- Lossless for all five dtypes including null patterns; a null string and an
  empty string are distinguished by the validity bitmap.

## Performance (Apple Silicon, 100K × 1024 Float32 ≈ 400 MB)

Measured by `BenchmarkTests.testVA_VectorSearch` (best-of-N, `-O`):

| Operation | Target (indicative) | Measured (M-series) |
|---|---|---|
| cosine topK=10, CPU | ≤ 150 ms | ~13 ms |
| cosine topK=10, Metal (incl. transfer) | ≤ 30 ms | ~42 ms |
| `fromVectors` | ≤ 500 ms | ~60 ms |
| `writeSPB` | ≤ 2 s | ~0.5 s |
| `readSPB` | ≤ 2 s | ~0.1 s |

The Metal path is dominated by the one-time ~400 MB plane upload per call
(shared-memory copy); at this scale the vDSP CPU path is faster, which is why
`.cpu` is the default and `.auto` only offloads above a candidate threshold.
Searches perform no hidden copies: scoring walks the stored plane via the
zero-copy accessor.

## Non-goals (v1)

ANN indexes (the `SearchBackend` enum and SPB's version field leave room),
CSV/JSON vector serialization, GPU dot/euclidean, Float64/Float16 storage,
ragged/sparse vectors, mutable row-level APIs.
