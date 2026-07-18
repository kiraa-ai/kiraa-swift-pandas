# SwiftPandas Vector Functionality — Design Specification

**Status:** Draft for implementation
**Date:** 2026-07-18
**Responds to:** Kiraa Engine "Vector Database Functionality — Requirements Specification" (R1–R8, A1–A6)
**Target release:** **0.8.0** — *not* 0.7.0 as the request assumes. `SwiftPandasInfo.version` is already `0.7.0-beta` (commit `27c3f2c`, the hot-cache release). The requirements doc was written against 0.6.0-beta; the version target is the only clause we cannot honor as written. Everything else below is spec'd to satisfy the request normatively.

---

## 0. Design stance

Three principles drive every decision here (per our design review discipline):

1. **One deep module per design decision.** Vector storage layout lives only in `VectorArray`; candidate selection lives only in the search engine; byte layout lives only in the SPB reader/writer. No other file may know these decisions.
2. **Reuse the existing machinery, don't parallel it.** SwiftPandas already has a validity bitmap (`BitVector`), CoW contiguous storage (`NativeArray`/`ArrayBuffer`), a Metal runtime-compile pipeline (`MetalShaders` + `MetalContext`), and row materialization (`takeRows`). Every requirement below maps onto one of these rather than introducing a sibling mechanism.
3. **Define errors out of existence where semantics allow; throw typed errors where the contract demands it.** The request's no-silent-fallback rule (backend policy, ops matrix) is normative — those paths throw `VectorError`, never degrade quietly.

Module inventory (new files):

```
Sources/SwiftPandas/Vector/VectorArray.swift      // storage (R1)
Sources/SwiftPandas/Vector/VectorError.swift      // error model (R7)
Sources/SwiftPandas/Vector/VectorOps.swift        // norms/normalize, Series accessors (R1.3, R2)
Sources/SwiftPandas/Vector/VectorSearch.swift     // options/backend/result + CPU engine (R3)
Sources/SwiftPandas/Metal/MetalVectorSearch.swift // GPU dispatch (R5)
Sources/SwiftPandas/IO/SPB/SPBFormat.swift        // layout constants, tags, cursor
Sources/SwiftPandas/IO/SPB/SPBWriter.swift        // (R6)
Sources/SwiftPandas/IO/SPB/SPBReader.swift        // (R6)
```

plus edits to the existing switch sites enumerated in §7 (the A6 audit list).

---

## 1. R1 — `VectorArray` and the `Column` case

### 1.1 Storage design

**Design it twice.** Two candidate representations were considered:

- *(a)* `NullableArray<[Float]>` — reuses the generic container wholesale. Rejected: element type `[Float]` is heap-boxed per row (array-of-arrays by the back door), violates the flat-plane requirement, and `NullableArray`'s vDSP fast paths are meaningless for it.
- *(b)* A purpose-built struct composing the two primitives that already encode our storage decisions: `NativeArray<Float>` for the plane (CoW via `ArrayBuffer`), `BitVector` for validity. **Chosen.** This *is* "reusing the NullableArray bitmap machinery" — `BitVector` is that machinery; `NullableArray` is merely one composition of it.

```swift
/// Fixed-dims Float32 vector storage: a flat row-major plane + validity bitmap.
/// Immutable after construction; all row ops return new values (CoW on the plane).
public struct VectorArray: Sendable, Equatable {
    internal var plane: NativeArray<Float>   // count * dims, row-major
    internal var validity: BitVector         // 1 = valid; null rows zero-filled in plane
    public let dims: Int                     // >= 1, fixed for the array's lifetime

    /// Cached vDSP_dotpr(v, v) per row, computed once at construction.
    /// §3.2 bit-parity allows this: vDSP_dotpr on the same bytes is
    /// bit-identical whenever computed. Sliced (not recomputed) by take/copy.
    internal var squaredNorms: NativeArray<Float>

    public var count: Int { plane.count / dims }
    public var nbytes: Int   // plane + validity + squaredNorms
}
```

Decisions folded into this one type (information hiding — no other file may depend on them):

- **Row-major flat plane, zero-filled null slots.** Zero-fill happens at construction and is an invariant, giving SPB byte-determinism for free (§5) and letting the GPU upload the plane pointer directly.
- **Eager norm cache.** Cosine needs `‖candidate‖²` per row; computing it lazily would require interior mutability on a `Sendable` struct. One extra vDSP pass at construction (≈ the cost of a single search) buys a halved per-search cost forever, and stays inside the `fromVectors` ≤ 500 ms budget. `take`/`copy` slice the cache alongside the plane — never recompute (recompute would also be bit-identical, but slicing is cheaper and obviously correct).
- **`dims >= 1` and `plane.count == count * dims == validity.bitCount * dims` are construction-time invariants**, checked once (`VectorError.invalidArgument` / `.dimensionMismatch`), so every downstream consumer can assume them (errors defined out of existence past the constructor).

Row ops mirror the existing `Column` needs — hand-written like the `.bool` case (a `[Float]` row is not `ExpressibleByIntegerLiteral`, so the generic `NullableArray.take` path is unavailable; this is established precedent, see `Column.swift:333–388`):

```swift
extension VectorArray {
    func take(indices: [Int]) -> VectorArray          // gathers dims-wide slices + bitmap bits + norms
    func take(mask: [Bool], trueCount: Int) -> VectorArray
    func copy() -> VectorArray
    static func concat(_ arrays: [VectorArray]) throws -> VectorArray  // dims must match: .dimensionMismatch
}
```

### 1.2 `Column` and `DTypeEnum`

- `Column` gains `case floatVector(VectorArray)` in `Core/Array/Column.swift`.
- `DTypeEnum` gains `case floatVector(dims: Int)` in `Core/DType/DType.swift`. **Associated value, deliberately**: dims is part of the type identity (Arrow's `FixedSizeList<Float32>[1024]` precedent) — two vector columns of different dims must not compare dtype-equal, `concat`/SPB validation get dims equality for free from `==`, and `description` renders `"floatVector(1024)"` as required. Hashable/Equatable synthesis still works; `isNumeric`/`isInteger`/`isFloat` return `false` (vector columns are explicitly non-numeric-scalar; every numeric fast-path gates on `asDouble()`, which returns `nil` — see §4).
- Making both enums grow a case is *intentionally source-breaking inside the library* — that is the A6 enforcement mechanism (§7).

### 1.3 Construction and access

Exactly as the request specifies (signatures normative):

```swift
extension Column {
    public static func fromVectors(_ vectors: [[Float]], dims: Int) throws -> Column
    public static func fromOptionalVectors(_ vectors: [[Float]?], dims: Int) throws -> Column
}
public extension Series {
    init(vectors: [[Float]], dims: Int, name: String) throws
}
extension Series {
    public var vectorDims: Int? { get }            // nil unless .floatVector
    public func vector(at row: Int) -> [Float]?    // nil for null rows; copies
    public func vectors() -> [[Float]?]            // copies
    public func withUnsafeVectorPlane<R>(
        _ body: (UnsafeBufferPointer<Float>, _ dims: Int) throws -> R) rethrows -> R
}
```

- `withUnsafeVectorPlane` delegates to `NativeArray.withUnsafeBufferPointer` — the zero-copy path already exists; we expose it, we don't build it. Calling it on a non-vector series throws `VectorError.unsupportedOperation` (as do `vector(at:)`/`vectors()` — the request marks the whole access group "only valid on floatVector series"; only `vectorDims` is the safe probe, returning `nil`).
- `DataFrame.init(columns:)` (`DataFrame.swift:279`) needs **no signature change**; row-count consistency checks already operate on `Column.count`, which the new case implements.
- `fromVectors` performance: single `reserveCapacity(count*dims)` + per-row `memcpy`-style append; no intermediate `[[Float]]` restructuring. Dimension check per element before copy (`.dimensionMismatch(expected:got:)`).

---

## 2. R2 — Vector ops

```swift
public enum DistanceMetric: String, Sendable, Codable, CaseIterable {
    case cosine, dot, euclidean
}
extension Series {
    public func l2Norms() throws -> [Float]        // sqrt of cached squaredNorms; null rows -> 0
    public func normalizedL2() throws -> Series    // new series; zero-norm rows stay zero
}
```

- Both throw `unsupportedOperation` on non-vector series.
- **Raw-storage invariant** (normative, from the request): no code path — constructor, IO, search — may normalize in place. `normalizedL2()` is the only normalizer and always returns a new value. This is documented on `VectorArray` itself as a cross-module invariant, because it is the premise of the §3.2 bit-parity contract.
- `l2Norms` reads the cached `squaredNorms` (`sqrt` per element via vDSP) — consistent by construction with what search uses.

---

## 3. R3 — Similarity search

### 3.1 Module decomposition

**Design it twice.** *(a)* Put scoring logic directly in the `DataFrame` extension. Rejected: `similaritySearch`, `similaritySearchBatch`, and the Metal path would each re-derive candidate filtering and selection — information leakage across three sites. *(b)* **Chosen:** an internal engine with one narrow entry point; the public `DataFrame` API is a thin, obvious facade.

```swift
// VectorSearch.swift (internal)
enum VectorSearchEngine {
    struct Hits { let rowIndices: [Int]; let scores: [Double]; let backendUsed: String }
    /// The single implementation of: candidate compaction → scoring → threshold → top-K → tie-break.
    static func search(_ array: VectorArray, query: [Float], options: SearchOptions) throws -> Hits
}

extension DataFrame {
    public func similaritySearch(on column: String, query: [Float],
                                 options: SearchOptions = .init()) throws -> SearchResultFrame {
        // 1. resolve column (.floatVector or throw), validate query dims / topK / mask length
        // 2. let hits = try VectorSearchEngine.search(...)
        // 3. frame = takeRows(hits.rowIndices) + append "__score" Double column
    }
}
```

Row materialization reuses `takeRows(_:)` (`DataFrame.swift:611`) — search owns *which* rows, never *how* rows are copied. `SearchOptions`, `SearchBackend`, `SearchResultFrame` are exactly as the request defines them (defaults included); `SearchOptions.init()` keeps the common call `df.similaritySearch(on: "embedding", query: q)` one line — rare knobs (mask, backend, threshold) never tax the common path.

### 3.2 Engine pipeline (single ordering of decisions)

1. **Compact candidates once**: `candidateRows: [Int32]` = rows that are bitmap-valid AND mask-true (mask length pre-validated → `.maskLengthMismatch`). Both CPU and GPU paths consume this one list; the GPU path additionally gathers a compacted plane for upload (§6). Null/mask exclusion therefore *cannot* diverge between backends.
2. **Score** per backend (below).
3. **Threshold filter** in metric direction (`>=` for cosine/dot, `<=` for euclidean).
4. **Top-K select** with the comparator `(better score, then lower source row index)` — a bounded max-heap of size K over the surviving candidates (O(n log K)), fully deterministic. `topK <= 0` was already rejected at validation (`.invalidArgument`).
5. Emit `Hits` best-first.

Steps 3–5 are backend-independent CPU code — the GPU produces raw scores only, so ranking semantics exist in exactly one place.

**Batch**: v1 executes queries sequentially in order — semantic identity with N single calls is then true by construction, not by testing. (The request permits internal parallelism; that is a pure optimization behind the same contract and is deferred until profiling demands it.)

### 3.3 Normative numeric contract (bit-parity, CPU backend)

Pinned exactly as requested; this is the clause Kiraa re-pins on their side, so it is reproduced in the code as an interface comment on the CPU scorer and must never be "optimized":

- **cosine**, per candidate, all Float32:
  1. `dot = vDSP_dotpr(query, candidate)`
  2. `nQ = vDSP_dotpr(query, query)` (once per query); `nC` = the cached `squaredNorms[row]` (bit-identical to on-the-fly per the request's own allowance)
  3. `denom = sqrt(nQ) * sqrt(nC)` (Float sqrts, Float multiply)
  4. `denom == 0 → score = 0.0`; else `score = Double(dot / denom)` (Float divide, then widen)
- **dot**: `score = Double(vDSP_dotpr(q, c))`
- **euclidean** (pinned float-order, to be echoed in the public docs): `d2 = vDSP_distancesq(q, c)` (Float); `score = Double(sqrt(d2))` — `sqrt` applied in Float32, then widened.

No Double accumulation, no FMA rearrangement, no epsilon guards. The scorer walks the plane via `withUnsafeVectorPlane` — no per-row `[Float]` materialization (the R8 no-hidden-copies clause).

---

## 4. R4 — Ops matrix

The mechanical rule: everything that routes through `Column.take`/`copy`/`nbytes`/`count` works automatically once `VectorArray` implements those (**filter(mask:), takeRows, iloc, select, drop, rename, head/tail** — zero per-op code). The rest is explicit:

| Op | Behavior | Where |
|---|---|---|
| `concat` | dims equality across frames' same-named vector columns, else `.dimensionMismatch`; `VectorArray.concat` (BitVector already has `append(contentsOf:)`/`concat`) | `DataFrame.swift:1097–1127` |
| `merge` payload | pass-through via `take` on the join result indices | `DataFrame.swift:1206` |
| `merge` join key / `joinKeyText` | `unsupportedOperation(op: "merge(on:)", dtype: "floatVector(d)")` | `DataFrame.swift`, `DataFrame+JoinIndex.swift:102` |
| `describe` | count / nulls / dims only | `Series.swift` describe path |
| `estimatedBytes` / `nbytes` | `VectorArray.nbytes` (keeps HotStore's `FrameCache` budgeting correct) | automatic |
| `sortValues` by vector col | `unsupportedOperation` | `DataFrame.swift:702–809` SortKey extraction, `Series.sortValues` |
| Series arithmetic / comparisons / `apply` numeric / `cumsum` etc. | `unsupportedOperation` | `Series.swift` (these currently `guard case .double`-degrade; vector case made an explicit throw where the API can throw, `fatalError`-precondition where the existing operator API cannot — matching the codebase's operator convention) |
| `toCSV` with any vector column present | `unsupportedOperation` (checked up front, before any bytes are written) | `CSVReader.swift:1112` writer |
| `readCSV` | cannot produce vectors (inference emits only double/string — unchanged); strict-contract targets do not add a vector target in v1 | — |
| JSON writer | vector columns rejected with `unsupportedOperation` (its `value(at:)`-driven path would otherwise silently emit arrays — an untested serialization surface; SPB is the durable format) | `JSONReader.swift` |

**One interpretation decision (flagged for Kiraa sign-off):** whole-frame numeric reductions (`df.mean()`, `df.describe()` over all columns, groupBy over "all numeric columns") today *silently skip* string/bool columns. For consistency, vector columns are skipped by those implicit all-numeric sweeps exactly as strings are; the required `unsupportedOperation` throw applies when a vector column is **explicitly named** in an aggregation (e.g. `series.sum()`, groupBy agg on that column). Throwing on implicit sweeps would make `df.describe()` unusable on any mixed frame, which contradicts R4's own "describe MUST work" row. If Kiraa needs the stricter reading, it is a two-line change at the sweep sites.

---

## 5. R6 — SPB binary format

### 5.1 Placement and shape

`IO/SPB/` beside `IO/CSV/` and `IO/JSON/`. Public surface exactly:

```swift
extension DataFrame {
    public func writeSPB(to url: URL) throws
    public static func readSPB(from url: URL) throws -> DataFrame
}
```

Layout is byte-for-byte the table in the request (magic `SPB1`, version 1, little-endian, per-column: name / dtype tag 0–4 / dims (tag 4 only) / LSB-first validity bitmap ⌈rows/8⌉ / payload).

### 5.2 Determinism (normative)

- Column iteration order = `columnNames` (the frame's declared order — the codebase's dual `columnNames: [String]` + `columns: [String: Column]` storage means the array, never the dictionary, drives serialization; this is *the* map-iteration-order hazard in this codebase and is called out in the writer's interface comment).
- Bitmap serialization: `BitVector` stores packed `UInt64` words; the writer emits exactly `⌈rows/8⌉` bytes, LSB-first within each byte, tail bits of the final byte zero. This byte-level definition (not the in-memory word layout) is the format — `BitVector`'s internal representation stays hidden.
- Null payload slots: doubles/int64 write 8 zero bytes, bool writes `0`, string writes len `0`, vector rows are already zero-filled in the plane (the §1.1 invariant pays off here — the writer streams the plane verbatim, no masking pass). Note: a valid empty string and a null string both write len 0; the bitmap disambiguates.
- No timestamps, no padding, no alignment sections. Two writes of equal frames are byte-identical (A4 pins this).

### 5.3 Reading — one validation mechanism, not scattered checks

All reads go through an internal bounds-checked cursor:

```swift
struct SPBCursor {          // SPBFormat.swift
    mutating func readU32() throws -> UInt32   // every primitive read validates remaining
    mutating func readBytes(_ n: Int) throws -> ...
    // overrun/overflow anywhere → VectorError.corrupt(reason: "...")
}
```

so truncation/corruption is impossible to mishandle at call sites — the reader body is straight-line layout code with no inline bounds arithmetic (complexity pulled down into the cursor). Validation order: magic → version (`> 1` → `.versionUnsupported(found:supported:)`) → column count/row count sanity (length arithmetic in `Int` with overflow checks) → per-column tag validity, dims ≥ 1, bitmap tail-bit zeroing, payload length consistency. Any failure throws before a `DataFrame` is constructed — **no partial loads** by construction. String cells: bitmap-invalid ⇒ cell forced null regardless of payload len (len must be 0 or the file is `.corrupt`).

Version 1 readers reject version 2 files loudly (`versionUnsupported`) — the version field is the seam for a future ANN-sidecar section, per the request's non-goals.

### 5.4 Performance

Writer: single pre-sized `Data` buffer (size computed exactly from `nbytes`-style accounting), `append` of raw plane bytes via `withUnsafeBufferPointer` — no per-row loops for fixed-width payloads. Reader: `Data(contentsOf:options:.mappedIfSafe)`, plane loaded with one `memcpy` into the `NativeArray`. Both fit the ≤ 2 s / 400 MB target with an order of magnitude of headroom.

---

## 6. R5 — Metal backend

Follows the existing Metal layer's conventions exactly (consistency over novelty):

- **Shader**: MSL string `vectorSearchShaders` appended to `MetalShaders.allSource` (SPM runtime-compile path) *and* a `Shaders/VectorSearchShaders.metal` file for the Xcode/metallib path — same dual-mode arrangement as groupBy/merge. Kernel name `swiftpandas_vector_batch_cosine` (library-unique per the request; note it deviates from the layer's bare `snake_case` names deliberately, at the requester's instruction). One thread per candidate row, `if (tid >= n) return;` bounds check, buffers `(query, plane, results, dims, count)`, `.storageModeShared`.
- **Pipeline**: one more eagerly-created cached `MTLComputePipelineState` in `MetalContext` (matching the existing seven).
- **Dispatch**: `MetalVectorSearch.swift`, an internal `score(candidates:query:) -> [Float]?` used by the engine. When a mask/nulls exclude rows, the engine gathers a **compacted plane** (candidate rows only) before upload and keeps the `candidateRows` index map — mask-false rows never reach the GPU. When all rows are candidates, the `VectorArray` plane buffer is handed to Metal directly with no copy.
- **Policy** (in the engine, not in the Metal file — backend *selection* is a search-semantics decision):
  - `.cpu` — always; the bit-stable documented primary.
  - `.metal` — `MetalContext.shared == nil` or `SWIFTPANDAS_DISABLE_METAL` ⇒ `throw VectorError.metalUnavailable(reason)`; metric ≠ cosine ⇒ `throw .metalUnsupportedMetric(metric)`. Never a silent fallback. (Note: this is a deliberate departure from the groupBy/merge layer's silent-CPU-fallback philosophy — the request's no-silent-fallback rule is normative for search, and `backendUsed` makes every decision observable.)
  - `.auto(gpuThreshold:)` — metal iff post-compaction candidate count > threshold AND pipeline available; else cpu. No throw either way; `backendUsed` reports the outcome.
- GPU emits raw Float cosine scores only; threshold/top-K/tie-break run on the shared CPU steps (§3.2 steps 3–5). Parity contract: ≤ 1e-5 absolute score delta, identical ranking on non-degenerate data; docs state that GPU accumulation order may differ at ulp level and that bit-stability requires `.cpu`.

---

## 7. R7 / A6 — Error model, concurrency, and the switch audit

**`VectorError`** exactly as requested (all eight cases, `CustomStringConvertible`, `Sendable`), in `Vector/VectorError.swift`. Boundary with the existing error enum: *frame-shape* problems keep throwing `DataFrameError` (`similaritySearch(on: "missing")` → `DataFrameError.columnNotFound`, consistent with every other column-resolving API); *vector-semantics* problems throw `VectorError`. One sentence in each public doc comment states which enum can surface.

**Concurrency**: `VectorArray` is a value type over CoW `NativeArray` + `BitVector`, both already `Sendable`; every new public type is `Sendable` by composition, no `@unchecked` anywhere new (the only `@unchecked` stays where it already is, in `ArrayBuffer`/`MetalContext`). `DataFrame`/`Series`/`Column` remain immutable value types; CRUD stays `concat`/`filter`/rebuild.

**A6 audit — the exhaustive edit list** (from a sweep of every `switch`/`guard case` over `Column`/`DTypeEnum`; each site handles `.floatVector` explicitly, no `default:`):

| File | Sites |
|---|---|
| `Core/Array/Column.swift` | `count, dtype, isNumeric, validCount, naCount, isNA, nbytes, formattedValue, value(at:), asDouble (→ nil), take(indices:), take(mask:), copy, sum/mean/std/min/max (→ throw path), description, ==` |
| `Series/Series.swift` | arithmetic/comparison ops, `apply/map/cumsum/unique/nUnique/valueCounts/median/quantile/describe/sortValues`, printing |
| `DataFrame/DataFrame.swift` | `sortValues` SortKey (702), `concat` (1097), `merge` typed join + payload (1206), groupBy `fastAggregate`/key coding (1527), row description (1897) |
| `DataFrame/DataFrame+JoinIndex.swift` | `joinKeyText` (102) |
| `IO/CSV/CSVReader.swift` | writer (1130); `CSVReaderStrict` targets untouched (no vector contract target in v1) |
| `IO/JSON/JSONReader.swift` | writer pre-check (reject vector columns) |
| `Metal/MetalGroupBy.swift` | `factorizeGroupColumns` (352) → `unsupportedOperation` as a group key |
| `Lazy/Predicate.swift` | predicate evaluation → `unsupportedOperation` |

Enforcement: where a `switch` is currently exhaustive without `default`, the compiler *is* the audit — adding the case breaks the build until every site chooses a behavior. For the handful of `guard case .double` fast-path sites, the PR checklist item is a `grep -n 'case .double' Sources | review` pass recorded in the PR description. A CI grep asserting no `default:` appears in any `switch` over `Column` is added to `scripts/`.

---

## 8. Testing & acceptance mapping

XCTest (house convention; no swift-testing). New files under `Tests/SwiftPandasTests/`:

| File | Covers |
|---|---|
| `VectorColumnTests.swift` | R1: construction, dims validation, nulls/zero-fill invariant, accessors, `withUnsafeVectorPlane` zero-copy (pointer-identity assertion), dtype string `"floatVector(1024)"` |
| `VectorOpsMatrixTests.swift` | **A5**: every MUST-work op on a mixed scalar+vector frame; every MUST-throw op asserted to throw `unsupportedOperation`. **A1** norm/normalize edge cases (zero vectors) |
| `VectorSearchTests.swift` | **A1** numeric pins (identical → exactly 1.0, orthogonal → 0.0, opposite → −1.0, zero-norm → 0.0; per-metric threshold direction); **A2** determinism (repeated searches byte-equal via `[Double]` bit patterns; tie-break with deliberately duplicated vectors); batch ≡ sequential; mask/null exclusion; empty-result correctness (0 survivors is a valid, non-error outcome) |
| `SPBTests.swift` | **A4**: round-trip losslessness all 5 dtypes × null patterns (incl. empty string vs null string), double-write byte-identity (`Data ==`), corrupt/truncated/tail-bit/oversized-length/future-version files each throwing with a readable reason |
| `MetalVectorSearchTests.swift` | **A3**: CPU↔GPU ≤ 1e-5 / identical ranking on seeded 10K × 512; `.metal` without a device asserts the **throw** (via `SWIFTPANDAS_DISABLE_METAL=1`, so the assertion runs even on GPU hosts — never a silent skip); `.auto` threshold crossover observable via `backendUsed` |
| `BenchmarkTests.swift` (extended) | R8 indicative targets: 100K × 1024 cosine CPU/Metal, `fromVectors`, SPB write/read — LCG-seeded, min-of-3, matching the existing benchmark harness |

Determinism tests compare `score.bitPattern`, not `==`, so `-0.0`/NaN drift cannot pass silently.

---

## 9. Delivery plan

Milestones are abstractions, each independently shippable and reviewable:

1. **M1 — storage**: `VectorArray`, `Column.floatVector`, `DTypeEnum.floatVector(dims:)`, the full A6 switch sweep, ops matrix (§4), `VectorColumnTests` + `VectorOpsMatrixTests`. *(The breaking sweep lands first and alone — every later milestone is additive.)*
2. **M2 — CPU search**: `VectorOps`, engine + public API, bit-parity scorer, A1/A2 tests.
3. **M3 — SPB**: format/writer/reader/cursor, A4 tests.
4. **M4 — Metal**: kernel, pipeline, `.metal`/`.auto` policy, A3 tests.
5. **M5 — release**: benchmarks vs R8 targets, docs (README + a `docs/vectors.md` usage page pinning the euclidean float-order and the bit-stability statement), `SwiftPandasInfo.version = "0.8.0"`, tag, XCFramework rebuild (the `Package.swift` binary pin is stale at v0.6.1-beta and must be bumped regardless).

### Deviations from the request (for Kiraa sign-off)

1. **Version: 0.8.0, not 0.7.0** — 0.7.0-beta already shipped as the hot-cache release.
2. **Implicit all-numeric sweeps skip vector columns** (like strings today); the `unsupportedOperation` throw fires on explicit aggregation of a vector column (§4).
3. **JSON writer rejects vector frames** (the request is silent on JSON; leaving the generic path would serialize vectors through an unspecified, untested text format).
4. **`similaritySearch` on a missing column throws `DataFrameError.columnNotFound`**, not a `VectorError` — consistency with every existing column-resolving API.

Everything else — bit-parity order, SPB byte layout, no-silent-fallback backend policy, error cases, Sendable surface, non-goals — is implemented exactly as written in the request.
