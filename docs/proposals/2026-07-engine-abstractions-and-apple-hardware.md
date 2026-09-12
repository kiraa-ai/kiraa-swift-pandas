# Kiraa Engine — Abstraction & Apple-Hardware Proposals (engine-first, verified)

## Context

SwiftPandas v0.8.0-beta has a strong core (CoW columnar storage, lazy engine, vector columns + search, byte-deterministic SPB, CLI daemon), but the engine's real cost this quarter has been the **dataframe-build stage** — CPU string-churn on a single core while P+E cores idle. This document is the proposal set for the dev team, tiered by impact on the engine's headline numbers, with adoption/DX items on a decoupled track.

**All three load-bearing claims were verified against the v0.8.0-beta source:**
- Single-threaded data plane: zero hits for `concurrentPerform`/`DispatchQueue`/`TaskGroup`/`async let` anywhere in `Sources/SwiftPandas/`. All compute is one core + vDSP.
- SPB reader defeats mmap: `SPBCursor` copies the whole `.mappedIfSafe` file into `[UInt8]` (`Sources/SwiftPandas/IO/SPB/SPBFormat.swift:79`) and decodes U32/U64 with per-byte shift loops.
- Dead C targets: `Package.swift` compiles `CSkipList`/`CKHash`/`CUltraJSON` with `-O3` as dependencies of the library, but no Swift file in `Sources/` or `Tests/` imports any of them.

---

## Tier 1 — attacks the engine's real cost

### B1. Multicore data plane (morsel-driven parallelism) ⭐ highest value
One shared chunked-execution primitive (~64k-row morsels, `concurrentPerform`/`TaskGroup`, per-core partial state, deterministic merge), rolled out operator by operator:

1. **CSV parse first** (the source stage): parallel by byte-range with line-boundary fixup — directly targets dataframe-build string-churn.
2. Then **groupby** (per-core hash tables + ordered merge) and **merge probe**.
3. Then aggregations and brute-force vector search (partition candidates, merge top-K heaps).

Expected 4–8× on M-series for the hot paths, compounding with vDSP and with the tensor rail rather than competing with it.

**Real effort line — determinism:** the tensor certification regime (a2a identical verdicts, dict_mints census) assumes deterministic output. Every parallelized operator must produce **byte-identical results and ordering** to the serial path — per-morsel results merged in morsel order, no atomics-order-dependent accumulation, stable tie-breaking. Each operator rollout ships with a determinism proof and is a2a-certified at 1.78M rows like every other stage. Budget this as medium-plus per operator, not medium.

Hooks: `IO/CSV/CSVReader.swift` (byte-level FieldGrid parser), `DataFrame.swift` groupby (~L1748) / merge (~L1220) fast paths, `Vector/VectorSearch.swift`.

## Tier 2 — high value for the vector-DB workstream

### B2a. Heap/quickselect top-K in vector search — quick win, do now
`VectorSearch.swift` fully sorts all survivors then takes `prefix(topK)`. Replace with a bounded heap or the quickselect that already exists at `NativeArray.swift:884` — O(n log k) vs O(n log n), pure reuse, days of work.

### B2b. GEMM batch search backend — when profiles justify it
`similaritySearchBatch` runs queries sequentially with per-row `vDSP_dotpr`. Reformulate batch cosine/dot as `Q(k×d) × Vᵀ(d×n)` via `cblas_sgemm` (routes through the AMX matrix coprocessor on Apple silicon); `MPSMatrixMultiplication` for very large candidate sets. **Must land behind the existing `SearchBackend` enum with the per-row vDSP path kept as the bit-parity backend** — the determinism contract in `VectorOps.swift` is explicit and the enum was designed as exactly this seam. Sequence when vector search actually shows up in a profile.

### B4. Zero-copy SPB — quick win, do now
Fix the verified `[UInt8]` copy: operate directly on the mapped `Data` with `loadUnaligned`, materialize columns lazily on first touch. Instant open of multi-GB frames, lower RSS. Low risk — the reader is already bounds-checked and versioned. Matters at Kiraa's 1.78M-row ADF scale.

## Tier 3 — strategic / adoption track (decoupled from engine perf)

- **A1. Typed rows** — `DataFrame(rows: [Employee])` / `df.rows(as:)` via Codable (MVP) then a `@Tabular` macro; KeyPath-typed `col(\.salary)` for the lazy DSL. Best DX item, compile-time column safety; zero benchmark movement. Hooks: `Lazy/Predicate.swift`, `DataFrame.init(records:)`.
- **A3 + B3. `VectorCollection` + CoreML/ANE embeddings** — typed vector-store facade (upsert/delete/search over a DataFrame, SPB persistence) with a pluggable `EmbeddingProvider` (NLContextualEmbedding, user CoreML models on `.all` compute units → ANE). The on-device-RAG flagship demo. Do after the vector DB stabilizes.
- **A2. Unified expression layer** — one AST shared by eager API, lazy engine, and CLI pipe-DSL (currently a separate parser in `SwiftPandasCLI/DSL/Parser.swift`); daemon gets pushdown/`explain()` for free; strengthens the `docs/llm-grammar.md` LLM story and enables an MCP server over the existing wire protocol. Correct long-term architecture, large refactor, no near-term engine payoff — sequence late.
- **A4. Async streaming** (`AsyncSequence` row-batches over CSV/SPB, finishes CSV Phase B), **A5. SwiftUI kit** (Table/Charts bridging, `Transferable` SPB), **A6. datetime dtype** (int64 epoch-micros logical type; correctness/parity feature for 1.0, not engine value).

## Tier 4 — cheap hygiene, do opportunistically

- **B6a. Remove the three dead C targets** — trivial; smaller binary, faster builds, less audit surface.
- **B6b. Float32 vDSP overloads** — only `Double` gets vDSP today; small, helps if/when Float32 columns are hot outside vector search.

## Deprioritized

- **B5. Metal modernization** (async dispatch, fixing Float32 atomic groupby accumulation, lowering the 10M-row/100k-group thresholds): the GPU path barely fires on real workloads; making the CPU path multicore dominates. Revisit after B1/B2.

---

## Recommended engine-first sequence

1. **Days, low risk:** B6a dead C targets → B2a heap top-K → B4 zero-copy SPB.
2. **Core effort:** B1 morsel primitive → CSV parse → groupby → merge probe, each with a determinism/parity proof and a2a certification at 1.78M rows.
3. **As vector DB matures:** B2b GEMM backend, then A3/B3.
4. **Adoption track (parallel, decoupled):** A1 → A5 → A2 → A4/A6.

## Verification / proof points (summary)

- Extend `Tests/SwiftPandasTests/BenchmarkTests.swift` + `benchmarks/` pandas suite: per-operator multicore scaling curves; serial-vs-parallel **byte-identity** assertions for every B1 operator; GEMM vs vDSP-loop at 10k/100k/1M candidates; SPB open time on multi-GB files before/after B4.
- Bit-parity guard: CPU vDSP search stays byte-identical (existing `VectorOpsMatrixTests` contract); all new backends additive behind `SearchBackend`.
- Headline metric: dataframe-build wall clock at 1.78M rows (currently ~279s post-Track A) before/after B1 CSV-parse rollout.

The detailed test, documentation, and validation-script plan follows.

---

## Test plan (per proposal)

Conventions: new test files live in `Tests/SwiftPandasTests/`; all data generation uses the existing deterministic LCG generators (mirroring `benchmarks/gen_data.py` / the Swift benchmark tests) so runs are reproducible; determinism assertions compare **SPB bytes** (`writeSPB` output hashed with SHA-256), since SPB is already byte-deterministic — equal frames ⇒ equal hashes.

### B1 — Multicore data plane
New file `ParallelParityTests.swift` (grows one section per operator as it lands):
- **Serial/parallel byte-identity** — for each operator (CSV parse, groupby, merge probe, aggregations, vector search): run with `SWIFTPANDAS_MORSEL_THREADS=1` and `=N` (env override on the morsel primitive, mirroring the existing `SWIFTPANDAS_DISABLE_METAL` pattern in `MetalDispatch.swift`), write both results to SPB, assert identical SHA-256. Sweep N ∈ {1, 2, 4, 8, cores}.
- **Repeat-run determinism** — same input, same thread count, 20 consecutive runs ⇒ one unique hash. Catches scheduling-order bugs that a single A/B comparison misses.
- **Morsel-boundary edge cases (CSV)** — quoted fields containing newlines that straddle a chunk boundary; CRLF split across chunks; a row exactly at/one byte past a boundary; final chunk with no trailing newline; empty morsels (rows < morsel size); files smaller than one morsel. Each asserts equality with the serial parser's `FieldGrid`.
- **Merge-order determinism (groupby)** — inputs crafted so ≥2 morsels contain the same group keys with NaN/NA mixtures; assert group ordering and NA propagation match serial exactly. Include the stable tie-breaking cases (equal sort keys across morsels).
- **Accumulation-order guard** — sums over values with large magnitude spread (1e16 + 1.0 patterns); parallel result must equal serial bit-for-bit, proving per-morsel partials are combined in morsel order, not thread-completion order.
- **Cancellation/exception safety** — a morsel that throws (e.g. CSV parse failure mid-file) must surface the same typed error as serial, with no partial DataFrame constructed.

### B2a — Heap/quickselect top-K
Extend `VectorSearchTests.swift`:
- **Oracle parity** — property-style tests (seeded RNG): random candidate sets (n ∈ {0, 1, k−1, k, k+1, 10k}), random k; heap result must equal full-sort result exactly, including tie handling (equal scores ⇒ same deterministic row order as today's `sort` + `prefix`).
- **Threshold + mask interaction** — top-K with `threshold` eliminating some/all survivors, with candidate `mask` set; parity vs full sort in every combination.
- **`SearchResultFrame` invariants** — `__score` column ordering, `backendUsed` unchanged.

### B2b — GEMM batch backend
Extend `VectorSearchTests.swift` + new `GEMMBackendTests.swift`:
- **Rank-agreement, not bit-parity** — GEMM reorders float ops, so scores may differ in ulps. Assert: top-K **row sets** match the vDSP backend for well-separated data; scores within 1e-5 relative tolerance; ties documented as backend-dependent.
- **Bit-parity fence** — explicit test that `.cpu` backend output is unchanged by the GEMM code's existence (regression guard on the `VectorOps.swift` contract).
- **`backendUsed` observability** — `.auto` routing reports which backend ran; GEMM failures throw rather than silently fall back (same policy as Metal today).

### B4 — Zero-copy SPB
Extend the SPB tests:
- **Byte-identity round trip** — read-with-copy (old path, kept temporarily behind a flag for the test) vs zero-copy read of the same file ⇒ identical DataFrame ⇒ identical re-serialized SPB hash. Cover all five dtypes, null patterns, and vector columns.
- **Truncation/corruption fuzz** — for a valid file of B bytes: truncate at every header boundary and at random payload offsets (seeded); flip bytes in lengths/magic/version fields. Every case must throw `VectorError.corrupt` — never crash, never return a partial frame. (The bounds-checked cursor contract, preserved under `loadUnaligned`.)
- **Unaligned access** — files whose payload sections start at odd offsets (guaranteed by string columns of odd byte length) to prove `loadUnaligned` is used everywhere a plain `load` would trap.
- **Lazy materialization semantics** — if lazy column loading ships: mutate/delete the underlying file after open and before first column touch; behavior must be defined and tested (either eager validation at open, or a documented error on touch).

### B6a — Dead C targets
- CI assertion (see validation scripts): full `swift build && swift test` on macOS + Linux after removal; grep-guard that no `import CKHash|CSkipList|CUltraJSON` ever reappears without the target existing.

### Tier 3 (when scheduled)
- **A1 typed rows**: round-trip `[Struct] → DataFrame → [Struct]` across all dtypes incl. optionals/NA; mismatched-schema error tests; KeyPath `col(\.x)` produces the same plan as `col("x")` (compare `explainRaw()` output).
- **A3 VectorCollection**: CRUD invariants (upsert idempotence, delete-then-search excludes row); persistence round trip through SPB; embedding-provider mock for deterministic tests, real `NLEmbedding` behind a platform-gated integration test.
- **A2 unified AST**: golden tests — every documented pipe-DSL statement in `docs/llm-grammar.md` parses to an AST whose execution matches the current CLI runner's output on a fixture frame (this doubles as the migration safety net).

---

## Benchmark & validation scripts

New directory `scripts/validate/` (shell + Python, following the existing `benchmarks/run_all.py` / `demo/compare.sh` style). Each script prints a PASS/FAIL line and machine-readable JSON to stdout so CI and the a2a cert pipeline can consume them.

- **`scripts/validate/determinism_harness.sh`** — the B1 cert gate. Args: operator, input file, row count, runs (default 20), thread counts (default `1 2 4 8 max`). Runs the operator via the `swiftpandas` CLI for every (threads × run) combination, SHA-256s the SPB output, and fails unless exactly one hash is observed. This is the script each B1 operator rollout must pass at 1.78M rows before a2a certification.
- **`scripts/validate/scaling_curve.py`** — per-operator throughput at 1/2/4/8/max threads on generated data at 100k/1M/1.78M/10M rows; emits JSON `{operator, rows, threads, wall_s, speedup}` and a Markdown table for the PR description. Fails if max-thread speedup < 2× (regression tripwire, threshold configurable).
- **`scripts/validate/topk_bench.py`** — B2a/B2b: batch search timing at 10k/100k/1M candidates × dims {384, 768, 1024} × k {10, 100}, comparing full-sort vs heap vs GEMM (and numpy as external reference via the existing pandas-benchmark harness). Also cross-checks result row-sets between backends.
- **`scripts/validate/spb_probe.sh`** — B4: generates 100MB/1GB/4GB SPB files, measures open-to-first-query wall clock and peak RSS (`/usr/bin/time -l` on macOS) for old vs new reader; fails if zero-copy RSS ≥ copy-path RSS.
- **`scripts/validate/spb_fuzz.py`** — B4: seeded truncation/bit-flip fuzzer driving the CLI `load`; any exit that isn't a clean typed-error report is a failure. Run nightly with a larger iteration budget than the in-suite fuzz tests.
- **`scripts/validate/no_dead_targets.sh`** — B6a: asserts every C target declared in `Package.swift` is imported somewhere in `Sources/`; add to CI so dead weight can't accumulate again.
- **`scripts/validate/parity_vs_pandas.py`** — extends the existing `benchmarks/` suite: after each B1 operator lands, re-runs the 30 numbered comparison scripts and diffs numeric outputs against pandas within existing tolerances, confirming parallelism changed nothing observable.

CI wiring: `no_dead_targets.sh` + in-suite tests on every PR; `determinism_harness.sh` (small inputs) on every PR touching `Sources/SwiftPandas/`; full-scale harness + `scaling_curve.py` + `spb_probe.sh` as a nightly/manual "cert" job on Apple-silicon runners.

---

## Documentation deliverables

- **`docs/parallelism.md`** (new, ships with B1) — the morsel execution model: morsel size and how to tune it, `SWIFTPANDAS_MORSEL_THREADS` env override, the determinism guarantee ("parallel output is byte-identical to serial; certified per operator"), which operators are parallelized (a table updated per rollout), and interaction with the Metal thresholds.
- **`docs/determinism.md`** (new) — consolidate the currently scattered contracts (vDSP bit-parity in `VectorOps.swift`, SPB byte-determinism, serial/parallel identity) into one normative page the cert regime can reference; each guarantee links to the test that enforces it.
- **`docs/vectors.md` + `docs/vector-spec.md`** — update for B2a (top-K selection algorithm and tie-breaking made normative) and B2b (new `SearchBackend` case, rank-agreement-not-bit-parity caveat, when `.auto` picks GEMM).
- **`docs/vector-spec.md` SPB section** — B4: note the zero-copy reader, lazy-materialization semantics, and the unchanged on-disk format (no `formatVersion` bump).
- **`README.md`** — refresh the benchmark section with scaling curves once B1 lands (single-core vs multicore vs pandas); document the new env vars alongside `SWIFTPANDAS_DISABLE_METAL`.
- **`CHANGELOG.md`** — start it now (it's already a Road-to-1.0 item): every proposal above gets an entry under its release, marking behavior-invariant changes ("byte-identical output, faster") explicitly.
- **`docs/llm-grammar.md`** — no change until A2; when A2 lands it becomes the single grammar for CLI + lazy engine and must be regenerated from the golden-test fixtures rather than hand-maintained.
- **Tier 3 docs (when scheduled)** — `docs/typed-rows.md` (A1), a `VectorCollection` + on-device-embeddings tutorial chapter in `docs/TUTORIAL.md` (A3/B3), and an MCP/daemon page extending `docs/SERVER.md` (A2).
