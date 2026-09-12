# Startup Is Not a Tax

**5-Minute Demo Presentation — Demo 1: Quickstart**
*Kiraa AI / SwiftPandas*

> Companion to [`examples/01-quickstart`](../). Runs alongside `./run.sh`.
> Render to PPTX/PDF/HTML with Marp, or present straight from this file.

---

## SLIDE 1 — TITLE CARD

**Title:** Startup Is Not a Tax

**Subtitle:** A whole analytics job that starts, runs, and exits before pandas finishes `import`

**Visual:** Dark background. A single terminal prompt with a blinking cursor.

**Speaker Notes (0:00–0:30):**
> "Every pandas script you've ever run paid a toll before it read a single row: boot the interpreter, import pandas — half a second, sometimes more, gone every time. We've all just accepted it. In the next five minutes I'm going to show you a data engine where that toll is zero, and why that changes where you're willing to put analytics."

---

## SLIDE 2 — THE HIDDEN COST

**Title:** The Half-Second You Pay Every Single Time

**Bullets:**
- `python -c "import pandas"` — typically **0.5–0.8s** before line one of *your* code
- Fine for a notebook you open once
- Deadly for anything you run *often*: pre-commit hooks, `make` targets, cron jobs, per-request batch
- So teams avoid using their best tool in exactly those places

**Visual:** A bar: "pandas cold start" (long red) vs "actual work" (tiny). The tax dwarfs the task.

**Speaker Notes (0:30–1:15):**
> "Here's the thing about that half-second. If you run analysis once a day, who cares. But the moment you want analytics *inside* something — a git hook that checks a data file, a build step, a job that fires per request — that startup cost is now the whole story. You're paying it thousands of times. So people just... don't. They keep the fast, sharp tool out of the fast, sharp places. SwiftPandas is a compiled binary. There is nothing to boot."

---

## SLIDE 3 — THE DEMO

**Title:** One Command: CSV In, Report Out

**Bullets:**
- 2,000-row sales dataset
- One pipeline: `derive → groupby → agg → sort → round`
- Profit per region, ranked

**Visual:** The pipeline as a horizontal flow of five labelled boxes.

```bash
swiftpandas run -i sales.csv -o by_region.csv \
  -c "derive(profit = revenue - cost) | groupby(region) \
      | agg(sum:profit, mean:units) | sort(profit, desc) | round(units, 1)"
```

**Speaker Notes (1:15–1:45):**
> "Let me show you a real job — not a toy. Read a sales file, compute profit, group by region, aggregate, rank. Five stages. Watch the clock at the bottom of the screen when I run it. *[switch to terminal, run ./run.sh]*"

---

## SLIDE 4 — WHAT YOU JUST SAW

**Title:** The Whole Job Was the Number at the Bottom

**Bullets:**
- Process start **+** CSV parse **+** 5-stage pipeline **+** CSV write **+** process exit
- All of it — tens of milliseconds
- No daemon left running. No kernel to keep warm. Nothing imported.

**Visual:** The same bar from Slide 2, now inverted — work fills it, startup is a sliver.

**Speaker Notes (1:45–2:45):**
> "Everything just happened. The number you saw wasn't 'time to run the pipeline' — it was time for the entire process to be born, parse the file, do five stages of real work, write the output, and die. There's no server sitting in the background now. If I run it again, I pay the same tiny cost again, because the tiny cost is the *whole* cost. This is what 'own the hardware' feels like at the command line."

---

## SLIDE 5 — WHERE THIS UNLOCKS

**Title:** Now You Can Put Analytics Where It Was Too Heavy Before

**Bullets:**
- Pre-commit hook: validate a data file on every commit
- `Makefile` target: regenerate numbers as part of the build
- Cron / CI: hundreds of small jobs, none amortizing a runtime
- A shell loop over 500 files — and it still feels instant

**Visual:** Four small icons: git, make, clock, terminal.

**Speaker Notes (2:45–3:45):**
> "So what does zero startup actually buy you? It buys you *placement*. You can drop this into a pre-commit hook and every commit checks your data without anyone noticing the cost. You can make it a build target. You can fan it out across hundreds of files in a shell loop. All the places where 'just use pandas' quietly meant 'accept a half-second tax per invocation' — those are open now."

---

## SLIDE 6 — CLOSE

**Title:** The Fast Tool Belongs in the Fast Places

**Bullets:**
- Same DSL inline and resident (see Demo 2)
- Same grammar an LLM can emit (`docs/llm-grammar.md`)
- Compiled, Apple-silicon-native, no runtime to warm

**Visual:** SwiftPandas logo. "Demo 2: hold a session →"

**Speaker Notes (3:45–4:30):**
> "One command, no tax — that's the foundation. In the next demo I'll show you the other half: when you *do* want to keep data hot and ask it a hundred questions in a row, there's a session mode for that too. Same grammar, same speed, just resident. But it all starts here: the fast tool finally gets to live in the fast places."
