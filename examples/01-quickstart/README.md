# 01 · Quickstart — one-shot analytics

The simplest and fastest way to use SwiftPandas: a single command that reads a
CSV, runs a pipeline, and writes a CSV. The process starts, does the work, and
exits.

## Run it

```bash
./run.sh
```

## What it does

1. Generates a deterministic 2,000-row `sales.csv` (date, region, product,
   channel, revenue, cost, units).
2. Runs one pipeline and writes `by_region.csv`:

   ```bash
   swiftpandas run -i sales.csv -o by_region.csv \
     -c "derive(profit = revenue - cost) | groupby(region) | agg(sum:profit, mean:units) | sort(profit, desc) | round(units, 1)"
   ```

Read the pipeline left to right as a data flow:

| Stage | Effect |
|-------|--------|
| `derive(profit = revenue - cost)` | add a computed column |
| `groupby(region)` | one bucket per region |
| `agg(sum:profit, mean:units)` | sum profit, average units per bucket |
| `sort(profit_sum, desc)` | rank regions, most profitable first |
| `round(units, 1)` | tidy the averaged column |

Aggregated columns keep their source name — `agg(sum:profit, mean:units)`
yields columns still called `profit` and `units` — which is why later stages
reference `profit` and `units`. (Aggregating one column twice would therefore
collide; use each source column once per `agg`.)

## The point

The timing line printed by `run.sh` covers the **entire** job: process boot,
CSV parse, five pipeline stages, CSV write, and exit. There is no interpreter to
warm up and no `import` to pay for. This is why SwiftPandas is comfortable in
places a pandas script would be too heavy — pre-commit hooks, `make` targets,
per-request batch jobs, tight shell loops.

## Next

When you want to run *many* pipelines against the *same* data without re-reading
it each time, keep the data hot in a daemon — see
[../02-resident-session](../02-resident-session/).
