# SwiftPandas — Feature Roadmap

> **Positioning:** SwiftPandas is a Swift-native analytical dataframe engine for local, Apple-first, production analytics.

This document tracks the gap between what ships today and what "production analytics" honestly requires. It's a living document — items move from **Planned** → **In progress** → **Shipped** as they land. The numbered checklists are the source of truth for what's claimed; the [README](../README.md) and [docs/SERVER.md](SERVER.md) lag this file by a release.

Format for each item:
- **Status** — `Shipped`, `In progress`, `Planned`, `Deferred`, or `Out of scope`.
- **Why it matters** — how it backs (or fails to back) the positioning claim.
- **Scope / exit criteria** — what needs to be true for the box to be checked.
- **Pointers** — relevant file paths, prior plans, related PRs.

---

## Where we are today (v0.6.1-beta)

| Capability | Status |
|---|---|
| Pure-Swift DataFrame / Series / Index types | ✅ shipped |
| Vectorised numeric ops via Apple Accelerate (vDSP) | ✅ shipped |
| Metal GPU shaders for groupby + merge | ✅ shipped |
| Lazy evaluation engine with filter fusion + predicate pushdown + projection pushdown | ✅ shipped |
| CSV I/O (read + write, custom byte-level parser, default NA handling) | ✅ shipped |
| JSON I/O (records-oriented, read + write) | ✅ shipped |
| `swiftpandas` CLI — DSL parser + transform runner, JSON pipeline files, dry-run, verbose mode | ✅ shipped |
| Resident-memory daemon (`swiftpandas server start/stop/status` + `load`/`pipe`/`save`/`list`/`drop`/`show`/`info`) | ✅ shipped, see [SERVER.md](SERVER.md) |
| `swiftpandas info` — structured `df.info()` equivalent over the wire | ✅ shipped |
| CSV loader memory: mmap-backed read (`mappedIfSafe`) — Phase A | ✅ shipped (–30% peak RSS on 31 MB CSV) |
| XCFramework binary distribution for SwiftPM consumers | ✅ shipped |
| Signed + notarized universal CLI ZIP on every GitHub release | ✅ shipped, see [build-release.sh](../scripts/build-release.sh) |
| Homebrew tap (`kiraa-ai/tap`) with `brew services` integration | ✅ shipped, see [HOMEBREW.md](HOMEBREW.md) |
| 415 tests, all green; integration tests against the actual `swiftpandas` binary | ✅ shipped |

What that buys us today: a credible **"beta release for serious early adopters"** story. The remaining items below close the gap to a credible **"deployable to production"** story.

---

## Path to v1.0 (this iteration)

### 1. API stability commitment

- **Status:** Planned
- **Why it matters:** The README currently says *"APIs may change between releases."* That sentence alone disqualifies SwiftPandas from production use at any team with code-review discipline. A 1.0 release with an explicit deprecation policy is the single highest-leverage change for the positioning.
- **Scope:**
  - Walk every `public` symbol in the `SwiftPandas` library target ([Sources/SwiftPandas/](../Sources/SwiftPandas/)) and decide: stable, experimental, or internal.
  - Mark experimental APIs with `@_spi(Experimental)` so they're hidden from default imports.
  - Write `DEPRECATION.md` documenting the policy: minor versions add APIs and may mark old ones deprecated (warning); major versions remove deprecated APIs.
  - Add `CHANGELOG.md` (we have none today) with a documented `## Unreleased` section per Keep-a-Changelog conventions.
  - Cut `v1.0.0` (drop the `-beta` suffix) with a release-notes block calling out exactly which APIs are stable.
- **Exit criteria:**
  - Every `public` symbol either appears in `CHANGELOG.md` under "Stable as of v1.0.0" or is annotated `@_spi(Experimental)`.
  - The README's "BETA RELEASE" banner is replaced with a 1.0 banner and a link to `DEPRECATION.md`.
  - `SwiftPandasInfo.version == "1.0.0"` (no `-beta`).
- **Pointers:** [SwiftPandas.swift:43](../Sources/SwiftPandas/SwiftPandas.swift#L43) for the version constant; testVersion is at [SwiftPandasTests.swift:46](../Tests/SwiftPandasTests/SwiftPandasTests.swift#L46) (update too).

### 2. CSV streaming reader — Phase B

- **Status:** Planned
- **Why it matters:** Phase A (shipped) saved ~30% of peak RSS by mmaping the file. Phase B saves another ~30% by never materialising the full FieldGrid. Together they take a 1 GB CSV from ~5.5 GB peak to ~1.5–2 GB. "Production analytics on multi-GB CSVs" isn't real without it.
- **Scope:**
  - Refactor [readFromBytes()](../Sources/SwiftPandas/IO/CSV/CSVReader.swift#L253) so the tokeniser feeds each row directly into per-column writers (`NullableArray<Double>` builders for numeric, `[String?]` for string) rather than building the offset grid first.
  - Bounded type-inference window: scan first N rows (configurable, default 10k), commit to dtypes, then stream-parse the rest with those types fixed. A non-numeric value in a column already classified as `Double` becomes an NA, with a warning.
  - Add `DataFrame.readCSV(path:dtypeSample:)` to override the sample size.
  - Memory regression test: `peak_rss_bytes_for_loading(path)` asserted to be ≤ `2 × file_size` on a synthetic 200 MB CSV.
- **Exit criteria:**
  - 1 GB synthetic CSV loads in ≤ 2 GB peak RSS (measured via `/usr/bin/time -l`).
  - Existing CSV tests still pass.
  - `DataFrame.readCSV` produces byte-identical output to v0.6.1 for the existing fixtures (regression-tested in CI).
- **Pointers:** Full audit lived in the [docs/INSTALL.md ↦ load-efficiency conversation summary](#); concrete starting line is [CSVReader.swift:289-359](../Sources/SwiftPandas/IO/CSV/CSVReader.swift#L289-L359). Don't change the byte-level state machine; only the column-materialisation path.

### 3. Correctness baseline against pandas

- **Status:** Planned
- **Why it matters:** Engineers migrating from pandas need confidence the answers are identical. Today we have unit tests but no golden-file comparison.
- **Scope:**
  - Pick one well-known dataset (NYC taxi rides — 1 month, ~1.5M rows, mixed-type columns) and check it into `Tests/Fixtures/golden/` (or download on first test run if too big).
  - Write a Python script in `scripts/regenerate-golden-csvs.sh` that uses pandas to compute the expected output of 12 representative pipelines (filter, groupby+agg, derive, sort, merge, etc.), one CSV per pipeline.
  - Write `GoldenSuiteTests.swift` that runs the same pipelines through SwiftPandas and asserts byte-equivalent (or float-tolerance-equivalent for aggregates) output against the goldens.
- **Exit criteria:**
  - 12 pipelines pass byte- or 1e-9-tolerance-equivalent.
  - Golden regeneration is a single `make goldens` away when pandas behaviour changes.
- **Pointers:** Existing demo scripts ([examples/cli/01–12](../examples/cli/)) already encode the canonical pipelines — reuse the DSL strings.

---

## Post-1.0 (next iteration)

### 4. Parquet I/O (read first, write second)

- **Status:** Planned
- **Why it matters:** Apple-first analytics users routinely hit Parquet from S3, BigQuery exports, Spark jobs, dbt outputs. CSV-only is a discoverable gap.
- **Scope (read):**
  - Add `SwiftPandas/IO/Parquet/` target. Use Apache Arrow Swift bindings (`swift-arrow`) or wrap libparquet directly via SwiftPM C target (similar to CSkipList / CKHash / CUltraJSON).
  - `DataFrame.readParquet(path:)` / `(url:)` / `(data:)`. Type mapping: `INT64`→`.int64`, `DOUBLE`→`.double`, `BYTE_ARRAY` (UTF-8)→`.string`, `BOOLEAN`→`.bool`. Skip complex types (list, struct) initially with a clear error.
- **Scope (write — separate later sub-task):**
  - `df.toParquet(path:)` with a default compression (`SNAPPY`).
- **Exit criteria:**
  - Parquet read round-trips with pandas-generated files for the four primary dtypes.
  - Documented in [INSTALL.md](INSTALL.md) Parquet section.

### 5. Daemon persistence (snapshot / restore)

- **Status:** Planned
- **Why it matters:** Today a `server stop` or crash loses every resident DataFrame. Production analysts who load a 200 MB dataset and run 30 transforms against it can't tolerate "we restarted the daemon" → lose everything. This was Phase 3 in the original [Phase 2 design plan](#).
- **Scope:**
  - On `server stop` (graceful path only — not signals), serialise every resident DataFrame to `${SWIFTPANDAS_RUNTIME_DIR}/snapshot/<name>.bin` using a forward-compatible columnar format (probably a thin custom format — Arrow IPC if we already pull Arrow in for Parquet).
  - On `server start`, if `snapshot/` exists, load every file into the registry under its original name. Print one-line warning if any file fails to deserialise.
  - Add `swiftpandas server snapshot` subcommand to force a snapshot mid-flight (for cron-driven backup).
  - Add `SWIFTPANDAS_DISABLE_SNAPSHOT=1` env to opt out (for ephemeral CI use).
- **Exit criteria:**
  - Integration test: load CSV → `server stop` → `server start` → DataFrames are back with identical shape + checksum.
  - Documented in [SERVER.md](SERVER.md).

### 6. Docs site (DocC + prose)

- **Status:** Planned
- **Why it matters:** Today docs are a folder of Markdown files in the repo. Production tools have proper docs. The library has dense Swift doc comments that DocC can render for free.
- **Scope:**
  - Run `swift package generate-documentation --target SwiftPandas` to produce a DocC catalog.
  - GitHub Actions workflow that builds DocC + copies `docs/*.md` into a static site, deploys to `gh-pages` (or hosts via the repo's GitHub Pages).
  - Domain decision: `kiraa-ai.github.io/swift-pandas` is free and immediate; a custom domain (`swift-pandas.kiraa.ai`) needs DNS coordination.
- **Exit criteria:**
  - Public docs site at the chosen URL.
  - DocC API reference for `DataFrame`, `Series`, `LazyDataFrame`, `Column` is browseable.
  - README points at the docs site as the primary entry point.

### 7. Real benchmarks page

- **Status:** Planned
- **Why it matters:** [VS_PANDAS.md](VS_PANDAS.md) lists *indicative* timings. The "Apple-first" claim wants *measured* numbers on M-series silicon for a published benchmark suite.
- **Scope:**
  - Pick 6 standard ops: `read_csv`, `filter`, `groupby + sum`, `groupby + multi-agg`, `merge`, `sort`. Run each at 1M, 10M, and 100M rows.
  - Compare against pandas (cold + warm) and polars (eager + lazy).
  - Output: a single `docs/BENCHMARKS.md` with a table per operation + a small chart per scenario.
  - Reproducibility script: `scripts/run-benchmarks.sh` that regenerates everything in ≤ 30 minutes on an M2/M3 Pro Mac.
- **Exit criteria:**
  - All numbers reproducible from the script.
  - At least one operation where SwiftPandas leads polars on Apple Silicon (currently expected: any operation that benefits from Metal GPU shaders, like multi-key groupby).

---

## Production hardening (before claiming "production" without an asterisk)

### 8. Observability on the daemon

- **Status:** Planned
- **Why it matters:** When a production daemon misbehaves at 3 AM you need to debug it. Today the daemon logs one line to stderr on startup and is otherwise silent.
- **Scope:**
  - Structured JSON logging mode (`SWIFTPANDAS_LOG_FORMAT=json`) emitting one line per request: timestamp, request id, cmd, source DF, latency ms, ok/error, error code.
  - `swiftpandas server status --json` for machine-readable status output.
  - Optional Prometheus `/metrics` endpoint over the same socket (text format): `swiftpandas_requests_total{cmd="pipe"}`, `swiftpandas_dataframes_resident`, `swiftpandas_memory_bytes`.
- **Exit criteria:**
  - `swiftpandas server status --json | jq .` works.
  - Documented in [SERVER.md](SERVER.md).

### 9. Fuzzing CSV + DSL parsers

- **Status:** Planned
- **Why it matters:** Both parsers ingest untrusted user-supplied input. CSV from anywhere, DSL strings from anywhere. Fuzzing finds the crashy edge cases before users do.
- **Scope:**
  - Add SwiftPM fuzz targets: one for CSV (bytes in → DataFrame or graceful error), one for the DSL (string in → `[Operation]` or graceful error).
  - Run via libFuzzer locally (`swift build --sanitize=address`) and as a daily GitHub Actions job.
  - Triage findings into `Tests/Regressions/Fuzz/<id>.{csv,dsl}` so each fix has a regression test.
- **Exit criteria:**
  - 24 hours of continuous fuzzing produces zero crashes.
  - The fuzz job is green in CI for two consecutive weeks before claiming "production-grade input handling".

### 10. Multi-user daemon — decide and document

- **Status:** Planned (decision needed first)
- **Why it matters:** Today the daemon is single-uid (socket mode 0600). Three scenarios this fails: shared dev machines, CI runners with multiple test users, multi-tenant analytics servers. Either we explicitly support it (auth + per-user state) or we explicitly document it as out of scope.
- **Scope of the decision:**
  - Option A — "single-user only, explicitly out of scope": one-paragraph note in [SERVER.md](SERVER.md). Stop. Most analytics workstations are single-user, so this is defensible.
  - Option B — "support multi-user": per-uid socket path (`/tmp/swiftpandas-${UID}/sock`), token-based auth on the wire (optional), `swiftpandas server start --user <name>` flag. Significant work; revisit only if real demand surfaces.
- **Exit criteria:**
  - A decision is documented in [SERVER.md](SERVER.md). Either A or B. Not "TBD".

---

## Out of scope (intentionally, today)

- **Linux feature parity.** The positioning is "Apple-first". Linux source builds will continue to work with reduced functionality (no Accelerate, no Metal, no Network.framework for the daemon — POSIX-socket fallback is a Phase 5 line item from the original plan, kept deferred). If a future contributor wants to land it, great; we won't block them, but we won't promise it on Apple-first roadmap.
- **GUI improvements.** The existing SwiftUI GUI (`swiftpandas --gui`) is a useful demo, not a product surface. We won't grow it.
- **Cloud / network mode.** "Local" is in the positioning. No `swiftpandas server listen --host 0.0.0.0`. Deliberate.
- **Streaming joins, window functions, time-series ops.** These are reasonable future work but they're "more of an engine" rather than "more of a production engine". Pending real user demand.
- **Plugin system / user-defined functions.** Same: pending demand. The current DSL is intentionally closed.

---

## Decision log

When trade-offs are made on roadmap items, record them here briefly so future contributors don't re-litigate.

- **2026-05-21 — Phase A CSV loader (mmap)** — chose `Data(contentsOf:options:.mappedIfSafe)` over `FileHandle`-based streaming because the byte-level parser already requires a contiguous buffer. Phase B will revisit if/when streaming becomes necessary.
- **2026-05-21 — Homebrew tap auto-update via PAT** — chose a fine-grained PAT scoped to just `kiraa-ai/homebrew-tap` over a deploy key because cross-repo writes via deploy keys require committer identity faff; the PAT is cleaner.
- **2026-05-21 — Daemon self-exec via `Bundle.main.executablePath`** — chose this over `CommandLine.arguments[0]` after the latter was found to break when the binary was invoked from PATH (e.g. via Homebrew install). See [Daemon.swift spawnBackground](../Sources/SwiftPandasCLI/Server/Daemon.swift) and PR #6.

---

## How to update this file

When you ship a roadmap item:

1. Move it from its phase section into the "Where we are today" table at the top.
2. Mark the linked line with the date and PR number.
3. If shipping revealed a follow-up gap, add it to the appropriate phase below.

When you decide a trade-off:

1. Add a one-line entry to the **Decision log** with the date, the choice, and a one-line justification.
2. Don't bury reasoning inside commit messages alone.
