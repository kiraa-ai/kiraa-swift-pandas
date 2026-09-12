# Demo 3 — Sales Report · Live Run-of-Show

Presenter script for the batch-report demo. ~6 minutes. Pairs with
[`presentation.md`](presentation.md) and the example's [`run.sh`](../run.sh).

## Before you start (offstage)

```bash
swift build                  # from repo root, once
cd examples/03-sales-report
rm -rf out                   # start with an empty output folder for effect
```

- This demo writes real artifacts to `./out/` (git-ignored). Showing the folder
  before (empty) and after (three files) is part of the story.
- Two screens/split: slides + terminal. A file browser on the `out/` folder is a
  nice third panel if you have room.

## Run of show

| Time | Slide | You do / say | On screen |
|------|-------|--------------|-----------|
| 0:00 | 1 Title | "Raw in, artifacts out, unattended." | Title slide |
| 0:30 | 2 The job everyone has | The nightly "build the numbers" job. | Pipeline slide |
| 1:15 | 3 The report | Introduce the three sections. → terminal | Three-strips slide → terminal |
| 1:20 | — | `ls out/` (empty), then run the demo (below). | terminal |
| 1:45 | 4 What you saw | Call out chained derive, multi-key groupby, top-N. | `out/` folder slide |
| 2:45 | 5 Why this shape wins | No runtime, no state, deterministic, cron-ready. | cron-line slide |
| 3:45 | 6 Scale & compose | Fan out to a reporting fleet; compose with Demos 1–2. | grid slide |
| 4:30 | 7 Close | Tie the three demos into one arc. | Close slide |

## The commands (screen 2)

**Set the stage — show there's nothing there yet:**

```bash
ls -la out/ 2>/dev/null || echo "(no out/ folder yet)"
```

**Primary — the narrated script (recommended):**

```bash
./run.sh
```

It generates a 50,000-row extract, runs all three report sections with timing,
prints a preview of each, and lists the artifacts. Narrate:

- Section **A**: "Chained derive — profit, then margin percent *from* profit —
  grouped by two columns, ranked."
- Section **B**: "One aggregation per column; revenue, profit, average units per
  channel."
- Section **C**: "Projection plus top-N — the ten biggest individual deals."

**Then show the deliverable — the actual point:**

```bash
ls -la out/
echo "--- channel summary ---"
column -s, -t < out/b_channel_summary.csv
```

**The money move — prove determinism:**

```bash
# Run it again into a second folder and diff the report bytes.
OUT_A=$(shasum out/*.csv)
./run.sh >/dev/null
OUT_B=$(shasum out/*.csv)
[ "$OUT_A" = "$OUT_B" ] && echo "IDENTICAL — same input, same bytes" || echo "changed"
```

> Say: "Same extract, byte-for-byte the same reports. That's what lets your CI
> assert 'the numbers didn't move' and lets an auditor trust the pipeline."

*(Note: the sample data generator is deterministically seeded, so the extract —
and therefore every report — is identical across runs.)*

## Punchlines to hit

- "The value is three clean CSVs in a folder. Everything else is overhead we removed."
- "There's no resident state, so this file *is* the job — point cron at it and walk away."
- "Deterministic output turns 'did the numbers change?' into a one-line CI check."

## If something goes wrong

- **`out/` not appearing** → you're in the wrong directory; `cd
  examples/03-sales-report` first. `run.sh` writes `./out` relative to itself.
- **Column-not-found** → aggregates keep their source column's name; aggregate
  each source column at most once per `agg` (Section B was written to obey this).
- **`column` missing** → drop the `| column -s, -t`; raw CSV still reads fine.
- **Determinism check prints "changed"** → confirm you didn't edit the generator
  seed in `../lib/common.sh` (`srand(42)`).
