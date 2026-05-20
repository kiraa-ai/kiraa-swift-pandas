# SwiftPandas CLI — Quickstart Guide

## Install

### Option A: Download the binary (recommended)

```bash
# Download the latest CLI binary release
gh release download --repo kiraa-ai/kiraa-swift-pandas --pattern 'swiftpandas-*-macos*.zip'

# Extract and install
unzip swiftpandas-*-macos*.zip
sudo cp swiftpandas /usr/local/bin/

# Verify
swiftpandas --help
```

> The pattern excludes `SwiftPandas.xcframework.zip`, which is the prebuilt **library** for SwiftPM consumers — see the main README's *Installation → Option B* for that workflow.

### Option B: Build from source

```bash
git clone https://github.com/kiraa-ai/kiraa-swift-pandas.git
cd kiraa-swift-pandas
swift build -c release
sudo cp .build/release/swiftpandas /usr/local/bin/
```

## Your first pipeline

Create a sample CSV file:

```bash
cat > sales.csv << 'EOF'
region,product,revenue,cost,units
North,Widget,45000,32000,150
South,Widget,38000,28000,120
North,Gadget,62000,41000,95
South,Gadget,51000,35000,88
East,Widget,29000,21000,100
East,Gadget,73000,48000,110
West,Widget,41000,30000,130
West,Gadget,55000,37000,105
EOF
```

### Filter + sort

```bash
swiftpandas -i sales.csv -c "filter(revenue > 50000) | sort(revenue, desc)"
```

Output:
```
  region  product  revenue  cost   units
  East    Gadget   73000    48000  110
  North   Gadget   62000    41000  95
  West    Gadget   55000    37000  105
  South   Gadget   51000    35000  88
```

### Compute a new column

```bash
swiftpandas -i sales.csv -c "derive(profit = revenue - cost) | sort(profit, desc) | select(region, product, profit)"
```

### GroupBy + aggregate

```bash
swiftpandas -i sales.csv -c "groupby(region) | agg(sum:revenue, sum:cost, sum:units)"
```

### Write to a file

```bash
swiftpandas -i sales.csv -o summary.csv -c "groupby(product) | agg(sum:revenue, mean:cost)"
```

### Chain many operations

```bash
swiftpandas -i sales.csv -c "
  derive(profit = revenue - cost)   |
  filter(profit > 15000)            |
  groupby(region)                   |
  agg(sum:profit, sum:units)        |
  sort(profit, desc)                |
  rename(profit -> total_profit)    |
  round(total_profit, 0)
"
```

## JSON transform files

For reusable pipelines, create a JSON file:

```bash
cat > pipeline.json << 'EOF'
{
  "description": "Regional profit summary",
  "operations": [
    { "op": "derive",  "args": { "name": "profit", "expression": "revenue - cost" } },
    { "op": "filter",  "args": { "column": "profit", "operator": ">", "value": 10000 } },
    { "op": "groupby", "args": { "columns": ["region"] } },
    { "op": "agg",     "args": { "specs": [{"fn": "sum", "col": "profit"}, {"fn": "sum", "col": "units"}] } },
    { "op": "sort",    "args": { "columns": [{"column": "profit", "direction": "desc"}] } }
  ]
}
EOF

swiftpandas -i sales.csv -f pipeline.json
```

## Verbose mode

See every step with timing:

```bash
swiftpandas -i sales.csv --verbose --quiet -c "filter(revenue > 40000) | sort(revenue, desc)"
```

```
  swiftpandas — CSV transformation pipeline
  ────────────────────────────────────────────────────────
  ✓ args    │ input: sales.csv
            │ chain: filter(revenue > 40000) | sort(revenue…
            │ sep: ","  dry-run: false  quiet: true
  ✓ read    │ sales.csv
            │ 8 rows × 5 cols  0.3ms
  ✓ parse   │ 2 operations from inline DSL  0.1ms
  ✓ validate │ all column references valid
  ────────────────────────────────────────────────────────
  Pipeline  │ executing 2 stages…
   1. filter  │ revenue > 40000
           │ → 5 rows × 5 cols  0.1ms
   2. sort    │ revenue desc
           │ → 5 rows × 5 cols  0.0ms
  ────────────────────────────────────────────────────────
  – output  │ suppressed (--quiet)
  ════════════════════════════════════════════════════════
  ✓ Success │ 8 → 5 rows  │  read 0.3ms  pipeline 0.2ms  write 0µs
            │ total 0.9ms
```

## Dry run

Preview what a pipeline will do without running it:

```bash
swiftpandas -i sales.csv --dry-run -c "filter(revenue > 50000) | groupby(region) | agg(sum:revenue)"
```

## GUI mode

Launch the interactive interface:

```bash
swiftpandas --gui
```

This opens a SwiftUI window where you can browse for CSV files, build pipelines visually, and export results.

## All operations

| Operation | Example | Description |
|---|---|---|
| `filter` | `filter(revenue > 10000)` | Keep rows matching condition |
| `sort` | `sort(revenue, desc)` | Sort by column |
| `select` | `select(region, revenue)` | Keep only these columns |
| `drop` | `drop(cost, units)` | Remove these columns |
| `rename` | `rename(revenue -> sales)` | Rename a column |
| `head` | `head(10)` | First N rows |
| `tail` | `tail(5)` | Last N rows |
| `groupby` | `groupby(region)` | Group (must be followed by `agg`) |
| `agg` | `agg(sum:revenue, mean:cost)` | Aggregate: `sum`, `mean`, `count`, `min`, `max` |
| `derive` | `derive(profit = revenue - cost)` | Computed column (`+` `-` `*` `/`) |
| `round` | `round(margin, 2)` | Round to N decimal places |
| `cast` | `cast(units, Int)` | Type conversion: `Int`, `Double`, `String` |

## All CLI flags

```
-i, --input <file>    Input CSV file (required in CLI mode)
-o, --output <file>   Output CSV file (stdout if omitted)
-c, --chain <dsl>     Inline DSL transform chain
-f, --file <json>     JSON transform file
--sep <char>          Column delimiter (default: ,)
--dry-run             Preview schema and pipeline, no output
--verbose             Step-by-step logging with timing
-q, --quiet           Suppress CSV output
--help-ops            Show all operation schemas
--gui                 Launch interactive GUI
```

## Resident-memory server

`swiftpandas` ships a second mode alongside the one-shot CLI: a long-lived
background daemon that holds named DataFrames in memory across CLI calls.
The same binary runs in both roles — `server start` detaches it as a
background daemon and waits until it's accept-ready before returning.

```bash
swiftpandas server start                                       # spawn daemon
swiftpandas load sales.csv --name sales                          # read CSV once
swiftpandas pipe --from sales --name big -c "filter(revenue > 50000)"
swiftpandas pipe --from big   --name top -c "sort(revenue, desc) | head(5)"
swiftpandas list                                               # name × rows × cols × bytes
swiftpandas show top --head 5                                  # preview
swiftpandas save top top.csv                                   # write a result
swiftpandas drop sales                                         # free memory
swiftpandas server status                                      # pid, uptime, memory
swiftpandas server stop                                        # shut down
```

Every client subcommand accepts `--socket <path>` and `--timeout <s>` for
overrides. Running a DataFrame command without a daemon exits with code 2
and a clear `no server running` message — there is no auto-launch.

The legacy one-shot CLI (`swiftpandas -i ... -c "..."`) is unaffected — it
is the default subcommand under the new name `run`. Everything above this
section continues to work as before.

A worked end-to-end example (synthetic 5 MB CSV → load → transform → save →
shutdown, with memory snapshots before/during/after) lives at
[examples/cli/demo_resident_memory.sh](examples/cli/demo_resident_memory.sh).

Full design notes, wire-protocol schema, exit-code table, and concurrency
model are in [docs/SERVER.md](docs/SERVER.md); install options (source
build, SwiftPM library, GitHub Releases ZIP, Homebrew tap) are in
[docs/INSTALL.md](docs/INSTALL.md).

## Uninstall

```bash
sudo rm /usr/local/bin/swiftpandas
```
