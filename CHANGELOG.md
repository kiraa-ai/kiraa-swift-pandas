# Changelog

All notable changes to SwiftPandas are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project aims for
semantic versioning once the public API is frozen for 1.0.

## [Unreleased]

### Changed
- CSV writer rewritten at the UTF-8 byte level with parallel row-chunk formatting: ~30× faster at 6.7M×43 (≈2 s vs ≈65 s); output contract pinned by `CSVWriterTests`.
- CSV parsing parallelized in both stages (chunked field grid with serial fallback on quoted newlines; per-column type/typed parsing): `readCSV` 5.7 s → 3.3 s at 6.7M×43. Pinned by `CSVGridParallelTests` / `CSVColumnParallelTests`.
- Vector search top-K selection is O(n log k) via bounded heap; the returned ranking is unchanged (`TopKSelectionTests`).
- SPB reads parse directly over the memory-mapped file — no whole-file copy (`SPBZeroCopyTests`).

### Fixed
- CSV cells containing `"\r\n"` or a separator/quote followed by a combining mark are now quoted correctly; they were emitted unquoted (malformed CSV) because grapheme-based `String.contains` missed them.
- `BitVector` equality no longer compares the `_knownAllValid` cache flag, so bit-identical masks always compare equal.

### Removed
- Dead vendored C targets (`CSkipList`, `CKHash`, `CUltraJSON`); `scripts/validate/no_dead_targets.sh` guards against regressions.

### Added
- Zero-copy columnar access: `withUnsafeDouble/Int64/BoolBuffer` + packed `ColumnValidity` (Arrow validity layout), `withStringColumn`, and bulk `Column(taking…)` initializers (`ColumnarAccessTests`).
- Declared-schema CSV reads: `ParseMode.declared`, `CSVReader.declared(columnTypes:)`, `DataFrame.readCSV(path:dtypes:)` — declared columns parse typed with failure reports, undeclared columns keep inference (`CSVDeclaredModeTests`).
- `scripts/validate/` validation harness and runnable `examples/` projects.
