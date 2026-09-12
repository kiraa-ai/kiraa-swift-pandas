# 03 · Sales report — a batch analytics deliverable

What a nightly "build the numbers" job looks like: one raw extract in, three
report sections out, each a single narrated pipeline. No session, no notebook —
deterministic commands that emit CSV artifacts a scheduler can run unattended.

## Run it

```bash
./run.sh
```

Outputs land in `./out/`:

| File | Contents |
|------|----------|
| `a_margin_leaderboard.csv` | Profit, average margin %, and units by region × product, ranked. |
| `b_channel_summary.csv` | Revenue, profit, and avg units per channel. |
| `c_top_transactions.csv` | The 10 highest-profit individual transactions. |

## Techniques on show

- **Chained `derive`** — compute `profit`, then compute `margin_pct` from it in
  a later stage. Derived columns are visible to everything downstream.
- **Multi-key `groupby(region, product)`** — group by more than one column.
- **Aggregate naming** — aggregated columns keep their source name, so
  `agg(sum:profit, mean:margin_pct)` yields `profit` and `margin_pct`;
  downstream `sort`/`round` reference those. Aggregate each source column at
  most once per `agg`, or the outputs collide on the shared name.
- **`select` + `sort` + `head`** — a projection-and-top-N to pull out notable
  individual rows, not just aggregates.

## The point

Each section is an independent process over 50,000 rows that starts, computes a
real multi-stage report, writes its artifact, and exits — fast enough that
running all three back to back still feels instant. Because there is no resident
state, this file *is* the job: point cron or a CI step at it and you are done.
