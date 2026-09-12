# Demo 1 — Quickstart · Live Run-of-Show

Presenter script for delivering the Quickstart demo. ~5 minutes. Pairs with
[`presentation.md`](presentation.md) and the example's [`run.sh`](../run.sh).

## Before you start (offstage)

```bash
# From the repo root, once — so there is no build lag on stage.
swift build
# Warm the terminal to the demo directory.
cd examples/01-quickstart
```

- Font size up (⌘+ a few times); dark terminal theme.
- Have `presentation.md` on screen 1, terminal on screen 2 (or split).
- Optional: to show a scripted, comment-free run, use `run.sh` as-is — it
  already narrates each step and prints timing.

## Run of show

| Time | Slide | You do / say | On screen |
|------|-------|--------------|-----------|
| 0:00 | 1 Title | Set up the "half-second tax" idea. | Title slide |
| 0:30 | 2 Hidden cost | Land the point: startup cost dominates *frequent* jobs. | Bar chart slide |
| 1:15 | 3 The demo | "Watch the clock at the bottom." Switch to terminal. | Pipeline slide → terminal |
| 1:20 | — | Run the demo (below). Let the timing line land. | `./run.sh` output |
| 1:45 | 4 What you saw | Return to slides. Reframe the timing number. | Inverted bar slide |
| 2:45 | 5 Where it unlocks | Placement story: hooks, make, cron, loops. | Icons slide |
| 3:45 | 6 Close | Tee up Demo 2 (sessions). | Close slide |

## The commands (screen 2)

**Primary — the narrated script (recommended):**

```bash
./run.sh
```

It generates the data, runs the pipeline, prints the timing line, and shows the
ranked output. Pause on the `↳ 0.0XXs` line — that is the whole talk.

**Manual variant (if you'd rather type it live):**

```bash
# 1. make a small dataset (borrow the example's generator)
source ../lib/common.sh
gen_sales_csv /tmp/sales.csv 2000

# 2. the one-shot job — point at the timing with `time`
time ../../.build/debug/swiftpandas run -i /tmp/sales.csv -o /tmp/by_region.csv \
  -c "derive(profit = revenue - cost) | groupby(region) | agg(sum:profit, mean:units) | sort(profit, desc) | round(units, 1)"

# 3. show the result
column -s, -t < /tmp/by_region.csv
```

**The money move — run it again to prove the cost is constant:**

```bash
time ../../.build/debug/swiftpandas run -i /tmp/sales.csv -o /dev/null \
  -c "filter(revenue > 10000) | sort(revenue, desc)"
```

> Say: "Same tiny number. There's no warm cache doing me a favor — the tiny
> cost *is* the whole cost, every time."

## Punchlines to hit

- "That number is the entire process being born and dying — not just the pipeline."
- "There's nothing running now. Nothing to warm up. Nothing imported."
- "Zero startup buys you *placement* — the fast tool in the fast places."

## If something goes wrong

- **`swiftpandas not found`** → you skipped `swift build`. Run it; `run.sh`
  auto-finds `.build/debug/swiftpandas`.
- **Column-not-found error** → remember aggregates keep their source name
  (`sum:profit` → `profit`), and each source column is aggregated once.
- **Timing looks high on first run** → the very first process launch can touch
  cold pages; run it twice and present the second. (It's still milliseconds.)
- **No `column` command** → drop the `| column -s, -t`; raw CSV is fine.
