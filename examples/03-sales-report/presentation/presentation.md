# Batch Analytics as Artifacts

**6-Minute Demo Presentation — Demo 3: Sales Report**
*Kiraa AI / SwiftPandas*

> Companion to [`examples/03-sales-report`](../). Runs alongside `./run.sh`.
> Render to PPTX/PDF/HTML with Marp, or present straight from this file.

---

## SLIDE 1 — TITLE CARD

**Title:** Batch Analytics as Artifacts

**Subtitle:** One raw extract in. A folder of report deliverables out. Cron-ready, no state to manage.

**Visual:** Dark background. A single CSV icon fanning out into three labelled report files.

**Speaker Notes (0:00–0:30):**
> "The first two demos were about speed and interactivity. This one's about the boring, essential thing every data team actually lives on: turning a raw extract into deliverables, on a schedule, without a human in the loop. I'll show you a nightly report job that's nothing more than a shell file — and why that's exactly what you want."

---

## SLIDE 2 — THE JOB EVERYONE HAS

**Title:** Every Team Has a "Build the Numbers" Job

**Bullets:**
- Raw data lands (export, dump, extract)
- Someone needs the same cuts every day: leaderboards, summaries, top-N
- Today: a Python script, a runtime, a scheduler, and a prayer about dependencies
- The output is what matters — a few clean CSVs someone downstream consumes

**Visual:** A pipeline: "raw.csv → [job] → a.csv, b.csv, c.csv".

**Speaker Notes (0:30–1:15):**
> "Everybody has this job. Raw data shows up, and every morning someone needs the same set of cuts — the margin leaderboard, the channel summary, the top transactions. Usually that's a Python script with a pinned environment, a scheduler, and some anxiety about whether the runtime still works. But strip it down: the *value* is just a few clean CSV files that a dashboard or a stakeholder consumes. Everything else is overhead."

---

## SLIDE 3 — THE REPORT

**Title:** Three Sections, Three Pipelines, One File

**Bullets:**
- **A — Margin leaderboard:** profit & avg margin % by region × product, ranked
- **B — Channel summary:** revenue, profit, avg units per channel
- **C — Top 10 transactions:** the highest-profit individual rows
- Each section is a single, readable pipeline over 50,000 rows

**Visual:** Three stacked pipeline strips, one per section.

**Speaker Notes (1:15–1:45):**
> "Here's a realistic report — three sections. A margin leaderboard grouped by region and product. A channel performance summary. And the ten biggest individual transactions. Each one is a single pipeline you can read top to bottom. Fifty thousand rows. Let me run the whole thing. *[switch to terminal, run ./run.sh]*"

---

## SLIDE 4 — WHAT YOU JUST SAW

**Title:** Three Real Reports, Each a Self-Contained Process

**Bullets:**
- Chained `derive` — build `profit`, then `margin_pct` from it
- Multi-key `groupby(region, product)`
- `select → sort → head` to surface notable individual rows
- Three CSV artifacts written to `out/` — the actual deliverable

**Visual:** The `out/` folder with three files and their row counts.

**Speaker Notes (1:45–2:45):**
> "Three reports, done. Notice what's in there: chained derivations — I compute profit, then compute margin percent *from* profit a stage later. Multi-column group-bys. A projection-and-top-N to pull out the biggest deals. These aren't toy operations; it's the real vocabulary of analytics. And the output is exactly three CSV files sitting in a folder, ready for whatever consumes them next."

---

## SLIDE 5 — WHY THIS SHAPE WINS

**Title:** No Runtime, No State — Just a File a Scheduler Runs

**Bullets:**
- The job **is** the shell file — point cron or CI at it, done
- Nothing resident between runs: no memory to leak, no server to babysit
- Deterministic: same input → same bytes out (great for diffing & auditing)
- One self-contained binary as the only dependency

**Visual:** A cron line `0 6 * * *  ./run.sh` above the three output files.

**Speaker Notes (2:45–3:45):**
> "Now the payoff. Because there's no resident state, this file *is* the job. You point cron at it, or a CI step, and you're finished — there's nothing running between executions to leak memory or fall over. It's deterministic: the same extract produces byte-for-byte the same reports, which is a gift when you're diffing yesterday's numbers against today's or handing them to an auditor. And the only dependency is a single binary. No environment to pin."

---

## SLIDE 6 — SCALE & COMPOSE

**Title:** From One Report to a Reporting Fleet

**Bullets:**
- Fan out: a loop over 100 regional extracts, each its own report folder
- Compose with Demo 1 & 2: one-shot sections here, resident sessions for interactive drill-down
- Deterministic output makes CI assertions trivial ("did the numbers change?")
- Same DSL an analyst reads and an LLM writes

**Visual:** One report file multiplying into a grid of report folders.

**Speaker Notes (3:45–4:30):**
> "And it scales the way shell scales. Wrap it in a loop and you've got a reporting fleet — one report folder per regional extract, per client, per day. Because output is deterministic, your CI can literally assert the numbers didn't unexpectedly move. It composes with the other two modes: batch sections like these for the scheduled work, a resident session when a human needs to drill in. Same grammar throughout."

---

## SLIDE 7 — CLOSE

**Title:** The Deliverable Is the Point. Everything Else Gets Out of the Way.

**Bullets:**
- Raw in → artifacts out, unattended
- No runtime, no state, deterministic, one binary
- The same engine behind Demo 1's speed and Demo 2's sessions

**Visual:** SwiftPandas logo. The three demos as one arc: "fast · resident · scheduled".

**Speaker Notes (4:30–5:15):**
> "That's the trilogy. Demo 1: startup is free, so put analytics anywhere. Demo 2: hold a session and iterate at conversational speed. Demo 3: turn raw data into deliverables on a schedule, with nothing to babysit. Three shapes, one engine, one grammar — all of it compiled and native to the hardware in your laptop. The deliverable is the point; SwiftPandas just gets out of the way."
