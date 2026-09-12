# Changelog

All notable changes to SwiftPandas are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims for
semantic versioning once the public API is frozen for 1.0.

Entries marked **(behavior-invariant)** change performance or internals only —
byte-for-byte output is unchanged and covered by parity tests.

## [Unreleased]

### Changed
- **CSV writing is now byte-level and parallel — ~50× faster on large mixed
  frames.** (behavior-invariant; one deliberate exception under Fixed)
  `CSVWriter` previously decided per-cell quoting with `String.contains` and
  assembled output through per-cell `String` allocations, single-threaded —
  a sampled production write of a 6.7M×43 frame spent 100% of its stacks in
  that search. The writer now scans UTF-8 bytes directly for the separator,
  `"`, LF, and CR, formats numerics straight into the output byte buffer,
  reads column storage through borrowed buffer pointers (zero refcount
  traffic in the row loops, so chunked formatting scales across cores), and
  writes files without materializing an intermediate `String`. Output is
  byte-identical to the previous writer — pinned by `CSVWriterGoldenTests`
  (edge-case corpus × option matrix, hand-pinned goldens, seeded fuzz, and a
  parallel-chunk parity test). Multi-byte separators keep the legacy path.
  Measured 54× on 1M rows × 5 mixed columns (1.89s → 0.035s); at the AC10
  fixture shape (6.7M × 43, 26 numeric + 17 string, 1.88 GB of CSV) the
  parallel write-to-file takes ≈ 2 s (~1 GB/s) vs ≈ 65 s for the legacy
  writer — 30×, against a ≤ 15 s target. Upstream deliverable D1 of the
  kiraa-engine I/O acceleration request.
- **CSV parsing is now parallel in both stages on large inputs.**
  (behavior-invariant)
  *Stage 1 — field grid:* files ≥ 4 MiB are split at newline candidates
  and each chunk runs the exact serial state machine speculatively
  (assuming it starts at a row boundary outside quotes), then chunks merge
  by disjoint parallel memcpy. Speculation is provably safe: the first
  quoted newline / unterminated quote / overflow row in a file always
  lands in a chunk whose start state was correct, so that chunk flags it
  and the whole parse falls back to the serial scanner — pinned (parity,
  every fallback trigger, and a fuzz sweep over separators/ragged rows/
  CRLF) by `CSVGridParallelTests` against the serial oracle.
  *Stage 2 — columns:* each column's type inference / declared-dtype parse
  depends only on its own column's bytes, so past the gate (4096 rows,
  2^18 cells) columns parse concurrently on both the inference and
  strict/declared paths, including per-column failure reports, with
  slot-ordered deterministic assembly — pinned by `CSVColumnParallelTests`
  (a column parsed alone is the serial oracle for the same column of a
  full-width parallel parse).
  At the AC10 fixture shape the grid pass drops 3.8 s → 0.5 s and the full
  `readCSV` drops 5.7 s → 3.3 s (~570 MB/s). Upstream deliverable D4 of
  the kiraa-engine I/O acceleration request.
- **Vector search top-K is now O(n log k) instead of O(n log n).** (behavior-invariant)
  The engine selects the K best candidates with a bounded heap and sorts only
  those, replacing a full sort of every survivor. Output is byte-identical to
  the previous full-sort-then-`prefix(K)` — the survivor ranking is a strict
  total order (unique source rows), so the top-K set and its ordering are
  uniquely determined. Verified by `TopKParityTests` (oracle = the engine's own
  full-sort path) across seeds, metrics, K edge cases, thresholds, masks, and
  ties. Proposal B2a.
- **SPB reads no longer copy the whole file.** (behavior-invariant)
  `SPBReader` parses directly over the memory-mapped buffer (`loadUnaligned`
  for multi-byte integers, bulk `copyMemory` for fixed-width payloads) instead
  of first copying the mapping into a `[UInt8]`. Lower peak memory and instant
  open for large frames; the bounds-checked, canonical-form-enforcing contract
  is unchanged. Verified by `SPBZeroCopyTests` (unaligned round-trip,
  exhaustive truncation, 4000-iteration byte-flip fuzz). Proposal B4.

### Fixed
- **CSV fields whose special characters hid inside a grapheme cluster were
  written unquoted — malformed CSV.** Swift's `String.contains` is
  grapheme-cluster based, so a cell containing `"\r\n"` (a single cluster
  that matches neither `"\n"` nor `"\r"`), or a separator/quote followed by
  a combining mark, passed the legacy quoting check and was emitted raw.
  The byte-level writer scans UTF-8 bytes and quotes/escapes these
  correctly. The divergence (including the legacy defect, for the record)
  is pinned by `testDivergence_graphemeClusteredSpecials`.
- **`BitVector` equality ignored a cache flag, so equal masks could compare
  unequal.** The synthesized `Equatable` included `_knownAllValid`, a one-way
  optimization latch, so an all-valid column built via `init(repeating:true)`
  compared unequal to a bit-identical mask built via `init([Bool])` (e.g. one
  produced by the SPB reader). This surfaced as a `.floatVector` column failing
  round-trip equality even though its bits matched. Equality now compares only
  `bitCount` and `words`. This tightens the frame-equality guarantee the
  determinism/certification checks depend on.

### Removed
- **Three vendored C targets — `CSkipList`, `CKHash`, `CUltraJSON` — deleted.**
  They were compiled (with `-O3`) into every build but imported by no Swift
  file; JSON I/O uses Foundation and GroupBy hashing is a Swift FNV-1a table.
  Smaller binary, faster builds, less audit surface. `Package.swift` and
  `project.yml` (the XcodeGen source of truth) updated; a new
  `scripts/validate/no_dead_targets.sh` CI guard prevents regressions.
  Proposal B6a.

### Added
- **Zero-copy columnar access (D3).** `DataFrame.withUnsafeDoubleBuffer` /
  `withUnsafeInt64Buffer` / `withUnsafeBoolBuffer` borrow a column's
  contiguous storage plus its packed validity bitmap (`ColumnValidity` —
  LSB-first `UInt64` words, set bit = valid, the Arrow validity
  convention; `nil` when the column has no NAs), and `withStringColumn`
  borrows a string column's backing `[String?]`. In the other direction,
  `Column(takingDoubles:validity:)` (+ int64/bool/string analogues) wrap
  prebuilt arrays in at most one bulk copy — no per-element append path.
  Together these let hosts bridge frames to Arrow/parquet/GPU codecs
  without per-cell boxing. `ColumnarAccessTests` pins the borrow contract,
  bitmap semantics across word boundaries, and borrow→rebuild round-trips.
- **Declared-schema CSV reads (D5).** `ParseMode.declared(_:)`,
  `CSVReader.declared(columnTypes:...)`, and
  `DataFrame.readCSV(path:dtypes:...)`: columns named in the contract
  parse to their declared dtype with strict-mode failure reporting (an
  all-digit cell in a declared `.string` column stays a string — postcode
  `"0800"` never becomes `800`), while **undeclared columns keep the
  historical inference byte-for-byte** (they share the extracted
  `inferColumn` with the plain inference path). This retires the
  consumer-side "never use readCSV on string IDs" rule for adopting
  callers. Pinned by `CSVDeclaredModeTests`.
- `scripts/validate/` — engine validation harnesses (`no_dead_targets.sh`,
  `run_validation.sh`) plus a README mapping each proposal to its check.
- `examples/` — runnable sample projects (one-shot analytics and resident-session
  workflows) with narrated bash scripts and per-project READMEs.
