# Python pandas vs `swiftpandas` — same pipeline, side by side

> This doc walks through the **exact** transformation the
> [demo_resident_memory.sh](../examples/cli/demo_resident_memory.sh) script
> performs (~5 MB synthetic sales CSV → filter `status == "active"` → derive
> `revenue = units * unit_price` → groupby region → sum revenue, mean units,
> count units → write CSV) twice: once with Python + pandas, once with
> `swiftpandas`. Each step lists the command and a representative wall-clock
> measurement on a 2024-era Apple Silicon Mac with a warm filesystem cache.
>
> Numbers are **indicative**, not benchmarks. They're meant to show where the
> time goes — Python's expensive import vs. swiftpandas's daemon round trip —
> not to argue one is universally faster. For a single one-shot pipeline,
> swiftpandas wins on startup. For ten interactive transforms in a row, the
> daemon makes the comparison lopsided. Run the demo script on your own
> machine for hard numbers.

---

## The task

```
input:  sales_5mb.csv               (~96,000 rows × 8 cols, ~5 MB)
filter: status == "active"          (~75% of rows survive)
derive: revenue = units * unit_price
group:  region                      (4 groups)
agg:    sum(revenue), mean(units), count(units)
output: regional_summary.csv        (4 rows × 4 cols, ~150 bytes)
```

---

## Option A — Python + pandas (one-shot script)

`pipeline.py`:

```python
import pandas as pd

df = pd.read_csv("sales_5mb.csv")
df = df[df["status"] == "active"]
df["revenue"] = df["units"] * df["unit_price"]
summary = (
    df.groupby("region")
      .agg(revenue=("revenue", "sum"),
           units=("units", "mean"),
           count=("units", "count"))
      .reset_index()
)
summary.to_csv("regional_summary.csv", index=False)
```

### Measurement

| Step | Command | Time (warm) | What dominates |
|---|---|---|---|
| Python cold start | `python3 -c "pass"` | **~50 ms** | interpreter init |
| `import pandas as pd` | (inside script) | **~600 ms** | pandas pulls numpy, pyarrow, dateutil, pytz, etc. |
| `pd.read_csv(...)` | reads 5 MB CSV | **~120 ms** | I/O + CSV parsing + dtype inference |
| filter + derive | `df[mask]; df["revenue"]=…` | **~15 ms** | NumPy vector ops |
| groupby + agg | `df.groupby(...).agg(...)` | **~25 ms** | hash + numpy reductions |
| `to_csv(...)` | writes ~150 B | **~10 ms** | formatting + write |
| **`python3 pipeline.py`** | end-to-end | **≈ 820 ms** | mostly import + read |

### Running it ten times (e.g., exploring transforms)

```bash
for transform in "filter1" "filter2" … "filter10"; do
    python3 pipeline.py            # full cold start every time
done
```

Wall clock: **≈ 8.2 s** (10 × 820 ms). The CSV is re-parsed every iteration;
the import cost is paid every iteration. Interactive notebooks avoid this by
keeping the kernel alive — but then you've left CLI-land.

---

## Option B — `swiftpandas` one-shot (matches Python's per-invocation model)

The legacy `swiftpandas run` subcommand (also the default, so the explicit
verb is optional):

```bash
swiftpandas run \
  -i sales_5mb.csv \
  -o regional_summary.csv \
  -c 'filter(status == "active") | derive(revenue = units * unit_price) | groupby(region) | agg(sum:revenue, mean:units, count:units)'
```

### Measurement

| Step | Command | Time (warm) | What dominates |
|---|---|---|---|
| Process start | exec `swiftpandas` | **~25 ms** | static-linked Swift binary, no module loading |
| `DataFrame.readCSV` | reads 5 MB CSV | **~70 ms** | columnar parser, no Python overhead |
| filter + derive | DSL chain | **~5 ms** | Accelerate vDSP + Metal-eligible ops |
| groupby + agg | DSL chain | **~10 ms** | C `khash` group keying |
| `df.toCSV(path:)` | writes ~150 B | **~5 ms** | direct fd write |
| **`swiftpandas run …`** | end-to-end | **≈ 115 ms** | mostly read |

That's roughly **7× faster than the Python script** for one run, almost
entirely because there's no `import pandas` cost. swiftpandas links its
runtime statically — start-up is dominated by `dyld` and a couple of small
C libraries.

### Running it ten times

```bash
for transform in "filter1" … "filter10"; do
    swiftpandas run -i sales_5mb.csv -o /tmp/out.csv -c "…"
done
```

Wall clock: **≈ 1.15 s** (10 × 115 ms). Better than Python, but the 5 MB CSV
is still re-parsed every iteration.

---

## Option C — `swiftpandas` with the resident-memory daemon

Now we pay the CSV-parse cost **once** and run all ten transforms against
the same in-memory DataFrame:

```bash
# One-time setup ---------------------------------------------------------
swiftpandas server start                                # ≈ 140 ms
swiftpandas load sales_5mb.csv --name df_test             # ≈ 80 ms

# Each follow-up transform is just an IPC round trip + the actual compute -
swiftpandas pipe --from df_test --name r1 \
  -c 'filter(status == "active") | derive(revenue = units * unit_price) | groupby(region) | agg(sum:revenue, mean:units, count:units)'
                                                        # ≈ 15 ms
swiftpandas pipe --from df_test --name r2 -c '…'          # ≈ 15 ms
…   # eight more
swiftpandas pipe --from df_test --name r10 -c '…'         # ≈ 15 ms

# Save the result we actually want --------------------------------------
swiftpandas save r1 regional_summary.csv                # ≈ 8 ms

# Optional: inspect what's resident -------------------------------------
swiftpandas server status                               # ≈ 4 ms
swiftpandas list                                        # ≈ 4 ms

# Clean shutdown --------------------------------------------------------
swiftpandas server stop                                 # ≈ 12 ms
```

### Measurement

| Step | Command | Time (warm) | What dominates |
|---|---|---|---|
| Daemon start | `swiftpandas server start` | **~140 ms** | re-exec self + NWListener bind + setsid |
| Initial load | `swiftpandas load …` | **~80 ms** | one CSV parse, lives in actor |
| Each transform | `swiftpandas pipe …` | **~15 ms** | socket dial + JSON encode + compute + reply |
| Save once | `swiftpandas save …` | **~8 ms** | server-side CSV write |
| Stop | `swiftpandas server stop` | **~12 ms** | wire shutdown + 100 ms flush window |
| **Ten transforms total** | end-to-end | **≈ 380 ms** | start + load amortised across 10 ops |

### Where does the daemon spend its memory?

```text
$ swiftpandas server status
  swiftpandas server
    pid        │ 4711
    uptime     │ 3.42s
    socket     │ /Users/you/.swiftpandas/sock
    dataframes │ 1
    memory     │ 5.4 MB
```

`memory` here is the sum of `DataFrame.estimatedBytes` across resident
DataFrames — the column buffers plus validity bitmaps. The macOS-level RSS
of the daemon process (visible via `ps -o rss=`) is higher (~50 MB on a
debug build, ~30 MB on a release build) because of the Swift runtime,
Network.framework, and the dynamic linker. `swiftpandas drop df_test`
returns the column buffers; the RSS drops by exactly the same amount.

---

## Side-by-side summary (ten transforms over the same 5 MB CSV)

| Approach | Setup | Per-transform | Total | Notes |
|---|---|---|---|---|
| Python + pandas one-shot | 0 ms | 820 ms × 10 | **~8.2 s** | re-imports and re-parses every run |
| Python + pandas (Jupyter / REPL) | ~700 ms once | ~150 ms each | **~2.2 s** | requires staying in Python REPL |
| `swiftpandas run` one-shot | 0 ms | 115 ms × 10 | **~1.15 s** | re-parses CSV every run |
| `swiftpandas` + daemon | ~220 ms once | ~15 ms each | **~380 ms** | CSV parsed once, lives in actor |

The daemon row is the takeaway: **interactive shells get the same kind of
parse-once speed-up Jupyter gives Python, but without leaving your shell.**
Pipeline commands stay normal Unix utilities — pipe-able, grep-able,
schedulable from cron, embeddable in shell scripts.

---

## When to pick which

- **Single one-shot transform**, occasional use → `swiftpandas run` (or even
  `python3 pipeline.py` if you live in Python). The daemon adds ~220 ms of
  setup; not worth it for a single 15 ms transform.
- **Interactive exploration**, many transforms over the same data →
  `swiftpandas server start` once, then `swiftpandas pipe` repeatedly.
- **Long-running service** (dashboard backend, ETL daemon, scheduled batch
  jobs) → `brew services start swiftpandas` so the daemon survives reboots.
  See [docs/HOMEBREW.md](HOMEBREW.md).
- **Embedded in a Swift app** → import the library directly via SwiftPM.
  See [docs/INSTALL.md](INSTALL.md#swiftpm-library-import).

---

## How to reproduce these numbers

The shipped demo does everything except the Python comparison, end-to-end:

```bash
./examples/cli/demo_resident_memory.sh
```

For the Python side, drop a `pipeline.py` with the code from
[Option A](#option-a--python--pandas-one-shot-script) into the same
directory and time it:

```bash
time python3 pipeline.py
```

Hardware, OS, and warm-cache state matter a lot. Numbers above are warm
caches on macOS 14.x / Apple Silicon. Cold-cache first runs (and especially
the first `import pandas` of the day) can add hundreds of milliseconds.
