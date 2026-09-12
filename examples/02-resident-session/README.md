# 02 · Resident session — load once, analyze many times

When you want to run *many* pipelines against the *same* data, re-reading the
CSV every time is waste. The SwiftPandas daemon holds the DataFrame in memory so
each subsequent operation is a sub-15ms round trip — the shell equivalent of a
warm notebook kernel.

## Run it

```bash
./run.sh
```

The script uses a **private socket** in a temp directory and stops the daemon on
exit, so it never interferes with any other `swiftpandas` daemon you run.

## The session lifecycle

```bash
swiftpandas server start --socket "$SOCK"          # 1. boot the daemon
swiftpandas load sales.csv --name sales --socket … # 2. parse ONCE, keep resident
swiftpandas pipe --from sales --name hot -c "…"     # 3. analyze (repeat freely)
swiftpandas list --socket …                        # 4. what's in memory?
swiftpandas show hot --head 5 --socket …           # 5. peek
swiftpandas save hot out.csv --socket …            # 6. write a deliverable
swiftpandas server stop --socket …                 # 7. shut down
```

Every `pipe` reads from a named frame already in memory and writes a new named
frame, so you can build a chain of derived views (`sales → profitable`,
`sales → by_channel`, …) without ever touching disk again until you `save`.

## What to watch in the output

The timing lines make the pattern obvious:

- **`load`** pays the one-time CSV parse.
- **`pipe`** calls after it are each a fast round trip — no re-parse — even
  though they run real group-bys and multi-stage filters over 25,000 rows.

That gap between "the first read" and "every operation after it" is the whole
reason to hold a session instead of running one-shot commands in a loop.

## Omitting `--socket`

These examples pass `--socket` only to stay isolated. In normal use you omit it
entirely and the client/daemon share a default socket:

```bash
swiftpandas server start
swiftpandas load sales.csv --name sales
swiftpandas pipe --from sales --name hot -c "groupby(region) | agg(sum:revenue)"
swiftpandas server stop
```
