# Hold a Session, Iterate at Conversational Speed

**6-Minute Demo Presentation — Demo 2: Resident Session**
*Kiraa AI / SwiftPandas*

> Companion to [`examples/02-resident-session`](../). Runs alongside `./run.sh`.
> Render to PPTX/PDF/HTML with Marp, or present straight from this file.

---

## SLIDE 1 — TITLE CARD

**Title:** Hold a Session, Iterate at Conversational Speed

**Subtitle:** Parse the data once. Ask it a hundred questions. Each answer in milliseconds.

**Visual:** Dark background. A glowing "resident" block in memory with several thin query arrows bouncing off it.

**Speaker Notes (0:00–0:30):**
> "Demo 1 was about jobs that start and stop. But sometimes you don't want to stop — you want to load a dataset once and then interrogate it, question after question, the way you would in a notebook. That's what this demo is. A resident session: the data stays hot in memory, and every question after the first is a round trip measured in milliseconds."

---

## SLIDE 2 — THE NOTEBOOK PATTERN, WITHOUT THE NOTEBOOK

**Title:** You Already Know This Pattern — It's the Warm Kernel

**Bullets:**
- In a notebook, the first `read_csv` is slow; everything after is fast because the frame is in memory
- The magic isn't the notebook UI — it's *keeping the data resident*
- SwiftPandas gives you that as plain shell commands
- A background daemon owns the frames; your commands are thin clients

**Visual:** Split: left, a Jupyter cell; right, the same idea as `load` / `pipe` / `save` shell lines.

**Speaker Notes (0:30–1:15):**
> "Here's the insight. When people say they love notebooks for exploration, what they actually love is that the data is already in memory — you're not re-reading a CSV every time you tweak a query. That warm-kernel feeling. SwiftPandas gives you exactly that, but as shell commands you can script, version, and automate. A daemon holds the dataframes; `load`, `pipe`, `show`, `save` are just thin clients talking to it."

---

## SLIDE 3 — THE LIFECYCLE

**Title:** Seven Commands, One Session

**Bullets:**
1. `server start` — boot the daemon
2. `load sales.csv --name sales` — **the only parse**
3. `pipe --from sales …` — analyze (repeat freely)
4. `list` — what's resident?
5. `show` — peek
6. `save` — write a deliverable
7. `server stop` — shut down

**Visual:** A vertical timeline; step 2 highlighted as "pay once", steps 3–6 tagged "≈10ms each".

**Speaker Notes (1:15–1:45):**
> "The whole session is seven commands. Start the daemon, load the file once — that's the only time we touch the CSV — then run as many pipelines as we want against the hot copy. List what's in memory, peek at a frame, save the ones we care about, and shut it down. Let me run it. Keep your eye on the timing next to `load` versus the timing next to each `pipe`. *[switch to terminal]*"

---

## SLIDE 4 — WHAT YOU JUST SAW

**Title:** The Parse Happened Once. Everything Else Was Free.

**Bullets:**
- `load` — 25,000 rows parsed, ~20ms, **once**
- Each `pipe` — group-bys and multi-filter chains — **~10ms**, no re-read
- Derived frames stack up in memory: `sales → profitable → by_channel → …`
- `save` only when you want an artifact on disk

**Visual:** Two columns of timing bars — `load` a single tall bar, `pipe`s a row of tiny equal bars.

**Speaker Notes (1:45–2:45):**
> "Look at the gap. Loading 25,000 rows took about twenty milliseconds — once. After that, every pipeline, including real group-bys and stacked filters, came back in about ten. Not because the work is trivial, but because the data never left memory. And notice we built a little tree of derived frames — profitable, by-channel, west-widgets — all resident, all named, none of them touching disk until we explicitly saved one."

---

## SLIDE 5 — WHY A DAEMON, NOT A LIBRARY CALL

**Title:** Resident Memory Is a Superpower for Automation

**Bullets:**
- A dashboard backend: load once at boot, serve queries per request at ~10ms
- An interactive triage session: keep a big extract hot while you dig
- A pipeline stage: hand frames between steps by name, not by re-serializing
- Isolated by socket — many independent sessions, no collisions

**Visual:** Three use-case cards: "dashboard", "triage", "pipeline".

**Speaker Notes (2:45–3:45):**
> "Why does resident memory matter beyond feeling fast? Because it changes what you can build. A dashboard backend loads its data once at startup and answers every user request in milliseconds. An analyst keeps a multi-gigabyte extract hot and explores it interactively. A multi-stage pipeline passes dataframes between steps by name instead of re-serializing to disk each time. And because sessions are isolated by socket, you can run many at once without them stepping on each other."

---

## SLIDE 6 — THE SAME GRAMMAR, EVERYWHERE

**Title:** Inline or Resident — It's One DSL

**Bullets:**
- Demo 1's `-c "filter(...) | groupby(...)"` is the *same* grammar as `pipe -c`
- Learn it once; use it one-shot or in a session
- The same grammar an LLM emits from natural language
- No second API to keep in your head

**Visual:** One DSL string in the center, arrows to "one-shot" and "resident".

**Speaker Notes (3:45–4:30):**
> "And to be clear — this isn't a different product from Demo 1. The pipeline grammar is identical whether you run it one-shot or inside a session. `filter`, `groupby`, `agg`, `derive` — you learn it once. It's also the grammar our LLM tooling emits from plain English. One mental model, two execution modes."

---

## SLIDE 7 — CLOSE

**Title:** Load Once. Ask Everything. Stay Fast.

**Bullets:**
- First read: pay once
- Every question after: conversational speed
- Notebook ergonomics, shell-scriptable, Apple-silicon-native

**Visual:** SwiftPandas logo. "Demo 3: batch reports as artifacts →"

**Speaker Notes (4:30–5:15):**
> "So: one-shot when you want a job that starts and stops, resident when you want to hold a dataset and iterate. Same grammar, same speed, your choice of shape. In the last demo I'll show the third face of this — turning a raw extract into a set of report artifacts a scheduler can build every night, unattended."
