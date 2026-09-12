# SwiftPandas examples

Runnable sample projects that show the shape of real work with SwiftPandas — and,
above all, **how little time you spend waiting**. Python + pandas pays a
cold-start tax on every invocation (interpreter boot + `import pandas` is
typically ~0.5–0.8s before a single row is read). SwiftPandas is a compiled
binary: a whole analytics job starts, runs, and exits in the time pandas is
still importing.

Each example is self-contained, generates its own data, cleans up after itself,
and prints wall-clock timing so you can see it for yourself.

## The binary

Every script looks for the `swiftpandas` CLI in this order:

1. `$SWIFTPANDAS` if you set it,
2. a debug build at `.build/debug/swiftpandas` (run `swift build` at the repo root),
3. `swiftpandas` on your `PATH` (e.g. installed via Homebrew).

```bash
# from the repo root, once:
swift build
```

## The examples

| # | Project | What it shows | Time to run |
|---|---------|---------------|-------------|
| [01-quickstart](01-quickstart/) | One-shot analytics | The fastest path: `input → pipeline → output` in a single command that boots and exits in milliseconds. | ~1s |
| [02-resident-session](02-resident-session/) | Daemon workflow | Load once, run many pipelines against memory-resident data, save, shut down — the "interactive session" pattern without per-command startup cost. | ~2s |
| [03-sales-report](03-sales-report/) | Batch report | A realistic multi-stage analytics report (derive → filter → group → rank) written as one narrated pipeline, producing a CSV deliverable. | ~1s |

## Presenting these

Each demo ships a companion slide deck (as editable markdown **and** built
`.pptx` / `.html`) plus a live run-of-show, so you can present it, not just run
it:

| Demo | Deck source | Built slides | Presenter script |
|------|-------------|--------------|------------------|
| 01 · *Startup Is Not a Tax* | [presentation.md](01-quickstart/presentation/presentation.md) | [.pptx](01-quickstart/presentation/presentation.pptx) · [.html](01-quickstart/presentation/presentation.html) | [demo-script.md](01-quickstart/presentation/demo-script.md) |
| 02 · *Hold a Session…* | [presentation.md](02-resident-session/presentation/presentation.md) | [.pptx](02-resident-session/presentation/presentation.pptx) · [.html](02-resident-session/presentation/presentation.html) | [demo-script.md](02-resident-session/presentation/demo-script.md) |
| 03 · *Batch Analytics as Artifacts* | [presentation.md](03-sales-report/presentation/presentation.md) | [.pptx](03-sales-report/presentation/presentation.pptx) · [.html](03-sales-report/presentation/presentation.html) | [demo-script.md](03-sales-report/presentation/demo-script.md) |

The markdown follows the house style of [`docs/PRESENTATION.md`](../docs/PRESENTATION.md)
(slides + speaker notes with timing). It is the single source of truth: the
`.pptx` (16:9, speaker notes in the notes pane) and the self-contained `.html`
deck (open in any browser — arrow keys navigate, **N** toggles speaker notes,
**F** fullscreen) are generated from it. Rebuild after editing any
`presentation.md`:

```bash
python3.13 examples/lib/build_decks.py     # needs: pip install python-pptx
```

Each presenter script maps slide cues to the exact terminal commands, calls out
the punchlines, and lists recovery steps if something misbehaves on stage.
Together the three form one arc: **fast** (one-shot) → **resident** (sessions) →
**scheduled** (batch).

Run any of them:

```bash
cd examples/01-quickstart && ./run.sh
```

Or run all of them end-to-end:

```bash
examples/run-all.sh
```

## The story these tell

- **Startup is not a tax.** A one-shot job is a process that lives for
  milliseconds. You can put `swiftpandas` in a `Makefile`, a git hook, a cron
  job, or a hot loop without amortizing an interpreter.
- **Sessions are for when you mean it.** When you *do* want to keep data hot
  across many operations, `server start` holds it in memory and every
  subsequent `pipe`/`show`/`save` is a sub-15ms round trip to the daemon.
- **The DSL is the whole API.** `filter | sort | groupby | agg | derive | …`
  is the same grammar inline (`-c`) and resident (`pipe -c`), and it's the same
  grammar an LLM can emit (see [docs/llm-grammar.md](../docs/llm-grammar.md)).
