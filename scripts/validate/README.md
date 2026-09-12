# `scripts/validate/` — engine validation harnesses

Validation for the engine-first proposal (`docs/proposals/2026-07-engine-abstractions-and-apple-hardware.md`). Each script prints a `PASS`/`FAIL` line so CI and the a2a cert pipeline can gate on it.

## Shipped now (validate the quick-win landings)

| Script | Proposal | What it checks |
|--------|----------|----------------|
| `no_dead_targets.sh` | B6a | No C `.target` in `Package.swift` is compiled without being imported. |
| `run_validation.sh` | B6a, B2a, B4 | One entry point: dead-target guard + the in-suite parity/fuzz tests. |

The B2a (heap top-K) and B4 (zero-copy SPB) correctness proofs live in the test suite, driven here via `swift test`:

- `Tests/SwiftPandasTests/TopKSelectionTests.swift` — the top-K result is exactly the K-prefix of the full ranking, across seeds, metrics, K edge cases, threshold, mask, and ties.
- `Tests/SwiftPandasTests/SPBZeroCopyTests.swift` — unaligned numeric/vector payloads round-trip, every truncation throws a typed error, 4000 random byte-flips never crash and only ever yield an equal-or-rejected frame.

Run everything:

```bash
bash scripts/validate/run_validation.sh
```

## Pending (land with their proposals)

These are specified in the proposal but require work that is not built yet, so they are intentionally absent rather than stubbed:

| Script | Blocked on | Purpose |
|--------|-----------|---------|
| `determinism_harness.sh` | B1 morsel primitive | 20× per-thread-count SPB-hash identity — the a2a cert gate each parallel operator must pass at 1.78M rows. |
| `scaling_curve.py` | B1 | Per-operator throughput at 1/2/4/8/max threads; fails if max speedup < 2×. |
| `topk_bench.py` | B2b GEMM backend | full-sort vs heap vs GEMM timing at 10k/100k/1M candidates; cross-checks result row-sets. |
| `spb_probe.sh` | B4 large-file profiling | open-to-first-query wall clock + peak RSS on 100MB/1GB/4GB files (needs an SPB CLI surface, not yet exposed). |
| `parity_vs_pandas.py` | B1 rollout | re-runs the `benchmarks/` pandas suite after each operator to confirm parallelism changed no observable output. |
