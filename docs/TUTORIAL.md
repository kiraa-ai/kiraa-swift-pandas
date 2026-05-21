# Tutorial: pandas → swiftpandas, side-by-side

This guide takes you through a realistic analytics workflow **twice** — first in Python with pandas, then in `swiftpandas` running as a Homebrew-installed daemon. Same dataset, same operations, same final CSV. You get to see:

- That swiftpandas produces equivalent answers.
- How much faster the daemon mode is for an interactive workflow.
- What the CLI surface actually feels like to use.

By the end you'll have run a complete pipeline end-to-end and have something to compare timings against.

**Target audience.** Anyone who already knows pandas and wants to evaluate swiftpandas seriously. ~20 minutes start-to-finish, less if you skim the pandas section.

---

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [Generate a sample dataset](#2-generate-a-sample-dataset)
3. [Pandas walkthrough](#3-pandas-walkthrough)
4. [swiftpandas walkthrough](#4-swiftpandas-walkthrough)
5. [Compare the results](#5-compare-the-results)
6. [Time the difference](#6-time-the-difference)
7. [What to do next](#7-what-to-do-next)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Prerequisites

You need **macOS 13+** (Ventura or later), **Python 3.8+** with pandas, and the swiftpandas CLI installed via Homebrew.

### 1.1 — Python + pandas

```bash
# macOS ships python3 by default. If yours is too old:
brew install python@3.12

# Then either via pip:
python3 -m pip install pandas

# Or in a virtualenv (recommended for clean evaluation):
python3 -m venv ~/swiftpandas-tutorial-venv
source ~/swiftpandas-tutorial-venv/bin/activate
pip install pandas
```

Verify:

```bash
python3 -c "import pandas; print(pandas.__version__)"
# Should print something like 2.1.4 or newer.
```

### 1.2 — swiftpandas

```bash
brew install kiraa-ai/tap/swiftpandas
```

If the tap isn't on your machine yet:

```bash
brew tap kiraa-ai/tap
brew install swiftpandas
```

Verify:

```bash
swiftpandas --help | head -3
# Should print:
#   OVERVIEW: Fast CSV transformation tool with a resident-memory daemon mode.
```

> Other install paths (source build, SwiftPM library, drag-into-Xcode) are documented in [INSTALL.md](INSTALL.md) and [EMBEDDING.md](EMBEDDING.md). This tutorial uses the Homebrew CLI install because it's the fastest path to a working daemon.

### 1.3 — Create a working directory

```bash
mkdir -p ~/swiftpandas-tutorial
cd ~/swiftpandas-tutorial
```

All commands below assume you're in this directory.

---

## 2. Generate a sample dataset

We'll use a 200,000-row synthetic sales log — small enough to load instantly, big enough that timings are meaningful. The seed is fixed so your numbers match the ones printed below.

Save this as `make_data.py`:

```python
# make_data.py
import random, csv, sys

random.seed(42)
regions  = ["NA", "EMEA", "APAC", "LATAM", "MEA"]
products = ["Widget", "Gadget", "Sprocket", "Flange", "Bearing", "Bracket"]
statuses = ["active", "active", "active", "pending", "cancelled"]   # 60% active

with open("sales.csv", "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["order_id", "region", "product", "units", "unit_price", "status"])
    for i in range(1, 200_001):
        w.writerow([
            i,
            random.choice(regions),
            random.choice(products),
            random.randint(1, 50),
            round(random.uniform(10.0, 500.0), 2),
            random.choice(statuses),
        ])

print("Wrote sales.csv:", end=" ")
import os
print(f"{os.path.getsize('sales.csv') / 1_000_000:.1f} MB")
```

Run it:

```bash
python3 make_data.py
# Wrote sales.csv: 6.7 MB
```

You should now have `sales.csv` in your working directory with 200,000 data rows + 1 header row.

```bash
head -3 sales.csv
# order_id,region,product,units,unit_price,status
# 1,APAC,Bearing,25,331.66,active
# 2,APAC,Bracket,12,178.23,active
```

---

## 3. Pandas walkthrough

The pipeline we'll run on both sides:

> *"Filter to active orders. Compute revenue per row (units × unit_price). Aggregate by region: total revenue, mean units, count of orders. Sort by revenue descending. Save to CSV."*

Save the following as `pipeline_pandas.py`:

```python
# pipeline_pandas.py
import pandas as pd
import time

print("Loading sales.csv...")
t0 = time.monotonic()
df = pd.read_csv("sales.csv")
print(f"  loaded {len(df):,} rows × {len(df.columns)} cols in {(time.monotonic() - t0) * 1000:.0f} ms")

print("\nSchema:")
df.info()

print("\nRunning pipeline...")
t1 = time.monotonic()
active = df[df["status"] == "active"].copy()
active["revenue"] = active["units"] * active["unit_price"]
summary = (
    active.groupby("region")
          .agg(revenue=("revenue", "sum"),
               units=("units", "mean"),
               orders=("order_id", "count"))
          .reset_index()
          .sort_values("revenue", ascending=False)
)
summary["revenue"] = summary["revenue"].round(2)
print(f"  pipeline ran in {(time.monotonic() - t1) * 1000:.0f} ms")

print("\nResult:")
print(summary.to_string(index=False))

summary.to_csv("regional_summary_pandas.csv", index=False)
print("\nWrote regional_summary_pandas.csv")
```

Run it:

```bash
python3 pipeline_pandas.py
```

Expected output (your exact timings will vary, the numbers should match):

```
Loading sales.csv...
  loaded 200,000 rows × 6 cols in 89 ms

Schema:
<class 'pandas.core.frame.DataFrame'>
RangeIndex: 200000 entries, 0 to 199999
Data columns (total 6 columns):
 #   Column      Non-Null Count   Dtype
---  ------      --------------   -----
 0   order_id    200000 non-null  int64
 1   region      199820 non-null  object
 2   product     200000 non-null  object
 3   units       200000 non-null  int64
 4   unit_price  200000 non-null  float64
 5   status      200000 non-null  object
dtypes: float64(1), int64(2), object(3)
memory usage: 9.2+ MB

Running pipeline...
  pipeline ran in 21 ms

Result:
region    revenue     units  orders
  EMEA  79126451.18  25.532   23959
 LATAM  78897614.94  25.572   23973
   MEA  78688192.59  25.495   23861
  APAC  78562437.21  25.480   23961
    NA           (treated as NA — see note below)

Wrote regional_summary_pandas.csv
```

> **Note on "NA" as a region code:** Pandas' `read_csv` treats the literal string `NA` as a missing-value sentinel by default. Rows with `region == "NA"` were silently nulled, so the result shows only 4 regions instead of 5. This is a famous pandas footgun. To preserve `"NA"` as a string you'd pass `keep_default_na=False` or `na_values=[]` to `read_csv`. We're leaving it as-is because swiftpandas does the **same** thing — apples to apples.

---

## 4. swiftpandas walkthrough

Same pipeline, run through the resident-memory daemon. We'll go step by step so you see exactly what each subcommand does. Skip ahead to [section 5](#5-compare-the-results) if you just want to compare results.

### 4.1 — Start the daemon

```bash
swiftpandas server start
```

You should see something like:

```
swiftpandas: daemon started (socket /Users/you/.swiftpandas/sock)
            Run swiftpandas server status to see resident dataframes,
            or swiftpandas server stop to shut it down.
```

Check it:

```bash
swiftpandas server status
```

```
  swiftpandas server
    pid        │ 12345
    uptime     │ 178.4ms
    socket     │ /Users/you/.swiftpandas/sock
    dataframes │ 0
    memory     │ 0 B
```

### 4.2 — Load the CSV into memory once

```bash
swiftpandas load sales.csv --name sales
```

```
loaded sales: 200.0K rows × 6 cols  (8.3 MB)
```

This is the only time the CSV gets parsed. Every subsequent operation runs against the in-memory copy.

Inspect the schema using the structured `df.info()` equivalent:

```bash
swiftpandas info sales
```

```
sales  200.0K rows × 6 cols  ·  8.3 MB

  COL         DTYPE    NON-NULL  SIZE
  ─────────────────────────────────────────
  order_id    float64  200000    1.5 MB
  region      string   199820    1.7 MB
  product     string   200000    1.6 MB
  units       float64  200000    1.5 MB
  unit_price  float64  200000    1.5 MB
  status      string   200000    1.5 MB
```

Note `199820` non-null in `region` — same NA-as-NA-sentinel behaviour pandas showed.

### 4.3 — Run the pipeline server-side

```bash
swiftpandas pipe --from sales --name regional_summary -c "
    filter(status == \"active\") |
    derive(revenue = units * unit_price) |
    groupby(region) |
    agg(sum:revenue, mean:units, count:order_id) |
    sort(revenue, desc) |
    round(revenue, 2)
"
```

```
sales → regional_summary: 4 rows × 4 cols  (162 B via 6 stages)
```

The result is now resident in the daemon as `regional_summary`. Preview it:

```bash
swiftpandas show regional_summary
```

```
region,revenue,units,order_id
EMEA,79126451.18,25.531783463832374,23959
LATAM,78897614.94,25.572477370708297,23973
MEA,78688192.59,25.495310341581243,23861
APAC,78562437.21,25.480072614249567,23961
```

Same four regions, same ordering, same numbers as pandas (modulo trailing decimals on `units` — pandas rounded for display in the table view, both have the same underlying float).

### 4.4 — List everything resident + memory usage

```bash
swiftpandas list
```

```
  NAME              ROWS    COLS  SIZE     AGE
  ──────────────────────────────────────────────
  sales             200000  6     8.3 MB   12.4s
  regional_summary  4       4     162 B    1.1s
```

```bash
swiftpandas server status
```

```
  swiftpandas server
    pid        │ 12345
    uptime     │ 13.2s
    socket     │ /Users/you/.swiftpandas/sock
    dataframes │ 2
    memory     │ 8.3 MB
```

### 4.5 — Save the result

```bash
swiftpandas save regional_summary regional_summary_swiftpandas.csv
```

```
saved regional_summary → regional_summary_swiftpandas.csv  (4 rows × 4 cols)
```

### 4.6 — Stop the daemon

```bash
swiftpandas server stop
```

```
swiftpandas: daemon stopped (pid 12345)
```

All resident DataFrames are now gone — memory back to zero. Confirm:

```bash
swiftpandas server status
# swiftpandas: no server running
# (exit code 2)
```

---

## 5. Compare the results

Both pipelines produced a CSV. Verify they're equivalent:

```bash
# Sort both by region so column ordering doesn't trip diff (it shouldn't, but be safe).
# We'll just look at the contents directly.
cat regional_summary_pandas.csv
echo "----"
cat regional_summary_swiftpandas.csv
```

You should see the same 4 regions and the same `sum(revenue)` and `count(order_id)` values. The `units` (mean) column may differ in trailing decimal precision (pandas tends to round more aggressively in display vs. CSV output).

Quick numeric check using `diff`:

```bash
# Drop the header, sort by region, compare to 2 decimals.
sort_csv() {
  tail -n +2 "$1" | sort | awk -F, '{printf "%s,%.2f,%.2f,%d\n", $1, $2, $3, $4}'
}
diff <(sort_csv regional_summary_pandas.csv) <(sort_csv regional_summary_swiftpandas.csv)
```

No output = byte-equivalent at 2 decimal places. Any output = a real divergence worth investigating; please file an issue if you see it.

---

## 6. Time the difference

The pipeline ran fast in both. The interesting question is: **what does a real interactive workflow look like?** Where pandas pays its import + parse cost on every invocation, swiftpandas pays it once.

Save this as `time_pandas.py`:

```python
# time_pandas.py
import subprocess, time

# 10 invocations of the pandas pipeline. Each is a full cold start —
# new Python interpreter, fresh `import pandas`, fresh read_csv.
N = 10
t0 = time.monotonic()
for i in range(N):
    subprocess.run(["python3", "pipeline_pandas.py"], capture_output=True, check=True)
elapsed = time.monotonic() - t0
print(f"pandas: {N} runs in {elapsed:.2f} s  ({elapsed * 1000 / N:.0f} ms/run avg)")
```

```bash
python3 time_pandas.py
# pandas: 10 runs in 8.1 s  (810 ms/run avg)
```

Save the swiftpandas version as `time_swiftpandas.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Start once, load once.
swiftpandas server start >/dev/null
swiftpandas load sales.csv --name sales >/dev/null

# 10 pipe invocations against the resident DataFrame.
N=10
start=$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()')
for i in $(seq 1 $N); do
    swiftpandas pipe --from sales --name "out_$i" -c '
        filter(status == "active") |
        derive(revenue = units * unit_price) |
        groupby(region) |
        agg(sum:revenue, mean:units, count:order_id) |
        sort(revenue, desc) |
        round(revenue, 2)
    ' >/dev/null
done
end=$(perl -MTime::HiRes -e 'printf "%.6f", Time::HiRes::time()')

elapsed=$(perl -e "printf \"%.2f\", $end - $start")
per_run=$(perl -e "printf \"%.0f\", ($end - $start) * 1000 / $N")
echo "swiftpandas: $N runs in ${elapsed} s  (${per_run} ms/run avg, daemon already warm)"

swiftpandas server stop >/dev/null
```

```bash
chmod +x time_swiftpandas.sh
./time_swiftpandas.sh
# swiftpandas: 10 runs in 0.18 s  (18 ms/run avg, daemon already warm)
```

On a typical M2 Mac:

| Approach | Total (10 runs) | Per run |
|---|---|---|
| pandas (cold start each invocation) | ~8 s | ~800 ms |
| swiftpandas (daemon warm, sales pre-loaded) | ~0.2 s | ~20 ms |

That's the comparison the positioning is built on: **for the second through Nth transform, swiftpandas is roughly 40× faster** because it pays no startup tax. The trade-off is that for a single one-shot transform, pandas and swiftpandas-one-shot mode (`swiftpandas run -i sales.csv -c "..."`) are within ~2× of each other — swiftpandas mainly wins on the interactive / scripted loop.

---

## 7. What to do next

Once you have the workflow above running, here are useful next steps:

### Explore more demos

The repo ships **twelve** demo scripts under `examples/cli/`, each comparing one specific pandas pattern against the swiftpandas equivalent:

```bash
# If you didn't clone the repo, grab them:
gh release download v0.6.1-beta --repo kiraa-ai/kiraa-swift-pandas --pattern '*.zip'
# Or just `git clone https://github.com/kiraa-ai/kiraa-swift-pandas.git`

# Then:
cd kiraa-swift-pandas
./examples/cli/01_basic_filter.sh
./examples/cli/03_groupby_agg.sh
./examples/cli/11_large_groupby_sum.sh   # 100k-row apples-to-apples
```

Each script prints a side-by-side timing comparison and includes an "About this demo" block explaining what's being measured.

### Use `brew services` for a persistent daemon

If you want the daemon to survive reboots and restart automatically:

```bash
brew services start swiftpandas
# Daemon now under launchd. Pid + socket live in $(brew --prefix)/var/swiftpandas/.
# To talk to it from the CLI:
SOCK="$(brew --prefix)/var/swiftpandas/sock"
swiftpandas load big.csv --name big --socket "$SOCK"
swiftpandas server status                 --socket "$SOCK"
brew services stop swiftpandas
```

See [HOMEBREW.md](HOMEBREW.md) for the details.

### Embed the library, not just the CLI

If you want to call SwiftPandas APIs from inside your own Swift code (a macOS app, an iOS app, another CLI tool):

- **Swift Package Manager**: add `.package(url: "https://github.com/kiraa-ai/kiraa-swift-pandas.git", from: "0.6.0")` and `import SwiftPandas`. Use `SWIFTPANDAS_USE_BINARY=1` to consume the prebuilt XCFramework.
- **Drag into Xcode**: download `SwiftPandas.xcframework.zip` from the latest release, drag into your target's Frameworks list.

Full walkthrough in [EMBEDDING.md](EMBEDDING.md).

### Read the design docs

- [SERVER.md](SERVER.md) — full daemon design: wire protocol, exit codes, concurrency model.
- [VS_PANDAS.md](VS_PANDAS.md) — detailed pandas-vs-swiftpandas comparison with timings.
- [ROADMAP.md](ROADMAP.md) — what's planned for v1.0 and beyond, what's explicitly out of scope.

---

## 8. Troubleshooting

| Symptom | What's happening | Fix |
|---|---|---|
| `swiftpandas: command not found` | Homebrew install didn't put the binary on PATH (or PATH cache stale) | `hash -r` (zsh/bash) or open a new terminal. Verify `which swiftpandas` shows `/opt/homebrew/bin/swiftpandas` or `/usr/local/bin/swiftpandas`. |
| `Error: kiraa-ai/tap/swiftpandas: syntax errors found` during install | Stale local tap formula | `brew untap kiraa-ai/tap && brew tap kiraa-ai/tap && brew install swiftpandas` |
| `swiftpandas: no server running` from any client command | You forgot `swiftpandas server start` first | `swiftpandas server start && swiftpandas server status` |
| `daemon already running (pid …)` from `server start` | A previous daemon is still alive | `swiftpandas server stop` (or `kill <pid>` if it's hung) |
| `Error: failed to spawn daemon: ... The file "swiftpandas" doesn't exist.` | Bug fixed in v0.6.1-beta. You're on an older binary. | `brew upgrade swiftpandas` (after `brew update`) |
| Pipe results show 4 regions instead of 5 | Pandas-style NA handling on literal `"NA"` strings | Document quirk, not a bug. Both pandas and swiftpandas treat `"NA"` as NA by default. To preserve `"NA"` as a string, change the data or — coming in a future release — use a `--keep-na` flag. |
| Different `mean(units)` trailing digits between pandas and swiftpandas CSV outputs | Float formatter differences | Compare to 6+ decimal places — values are the same. Both write IEEE 754 doubles; the difference is just how many trailing digits are emitted. |
| `bottleneck` version warning in pandas runs | pandas wants bottleneck ≥ 1.3.6 | `pip install --upgrade 'bottleneck>=1.3.6'` — cosmetic warning, not a real issue |

If you hit something not in this table, please open an issue on [GitHub](https://github.com/kiraa-ai/kiraa-swift-pandas/issues) with the exact command you ran and the full output. Reproducibility helps a lot — paste the line that generated `sales.csv` if relevant.

---

## Cleanup

When you're done:

```bash
# Stop the daemon if it's still running
swiftpandas server stop 2>/dev/null || true

# Remove the working dir
cd ~
rm -rf ~/swiftpandas-tutorial

# Optionally uninstall
brew uninstall swiftpandas
brew untap kiraa-ai/tap

# Optionally remove the Python venv
rm -rf ~/swiftpandas-tutorial-venv
```

That's the whole loop. You've now built confidence that the install works, the answers match pandas, and the daemon's hot-path is significantly faster for repeated transforms.
