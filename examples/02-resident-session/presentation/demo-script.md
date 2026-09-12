# Demo 2 — Resident Session · Live Run-of-Show

Presenter script for the daemon/session demo. ~6 minutes. Pairs with
[`presentation.md`](presentation.md) and the example's [`run.sh`](../run.sh).

## Before you start (offstage)

```bash
swift build                      # from repo root, once
cd examples/02-resident-session
# Make sure no stray daemon is running on the default socket:
../../.build/debug/swiftpandas server stop >/dev/null 2>&1 || true
```

- The example uses a **private socket** in a temp dir, so it will not collide
  with any other daemon. Safe to run on a shared machine.
- Two screens/split: slides + terminal.

## Run of show

| Time | Slide | You do / say | On screen |
|------|-------|--------------|-----------|
| 0:00 | 1 Title | "Load once, ask many." | Title slide |
| 0:30 | 2 Warm kernel | Notebook = resident data, minus the UI. | Split slide |
| 1:15 | 3 Lifecycle | "Watch `load` timing vs each `pipe`." → terminal | Timeline slide → terminal |
| 1:20 | — | Run the demo (below). Narrate the timing gap live. | `./run.sh` output |
| 1:45 | 4 What you saw | Reframe: parse once, everything else free. | Timing-bars slide |
| 2:45 | 5 Why a daemon | Dashboard / triage / pipeline use cases. | Use-case cards |
| 3:45 | 6 Same grammar | It's the same DSL as Demo 1. | One-DSL slide |
| 4:30 | 7 Close | Tee up Demo 3 (batch artifacts). | Close slide |

## The commands (screen 2)

**Primary — the narrated script (recommended):**

```bash
./run.sh
```

It runs the full lifecycle on a private socket and tears the daemon down on
exit. Narrate these beats as they scroll:

- At **`load`**: "One parse. ~20ms for 25,000 rows. This is the only time we
  read the file."
- At each **`pipe`**: "~10ms — real group-by, no re-read."
- At **`list`**: "Everything we've built is resident and named."
- At **`server stop`**: "Session over. Memory freed. Nothing left behind."

**Manual variant (to type live and feel the interactivity):**

```bash
SP=../../.build/debug/swiftpandas
SOCK=/tmp/demo.sock
source ../lib/common.sh; gen_sales_csv /tmp/sales.csv 25000

$SP server start --socket $SOCK
$SP load /tmp/sales.csv --name sales --socket $SOCK          # the one parse

# Now ask questions — each returns instantly:
$SP pipe --from sales --name profitable \
  -c "derive(profit = revenue - cost) | filter(profit > 20000) | sort(profit, desc)" --socket $SOCK
$SP pipe --from sales --name by_channel \
  -c "groupby(channel) | agg(sum:revenue, mean:units) | round(units, 1)" --socket $SOCK

$SP list --socket $SOCK
$SP show profitable --head 5 --socket $SOCK
$SP save by_channel /tmp/by_channel.csv --socket $SOCK
$SP server stop --socket $SOCK
```

**The money move — ask a fresh question live, unscripted:**

> Take a suggestion from the room ("show me East-region Gizmos") and type it:

```bash
$SP pipe --from sales --name adhoc \
  -c "filter(region == East) | filter(product == Gizmo) | groupby(product) | agg(sum:revenue, mean:units)" --socket $SOCK
$SP show adhoc --socket $SOCK
```

> Say: "That's a brand-new question against 25,000 rows, and it came back before
> I finished the sentence. That's the session paying off."

## Punchlines to hit

- "The parse happened once. Everything after was a round trip to a process that
  already had the data."
- "We built a tree of derived frames without touching disk."
- "Same grammar as Demo 1 — one-shot or resident is just a choice of shape."

## If something goes wrong

- **`daemon already running` / stale socket** → `swiftpandas server stop` (or
  delete the socket file), then restart. The script's own socket is private, so
  this only bites the manual variant.
- **`pipe` says frame not found** → check `--from` matches a name from `list`;
  names are case-sensitive.
- **Column-not-found** → aggregates keep their source name; aggregate each
  column once (see Demo 1's note).
- **Cleanup** → if you ran the manual variant, `swiftpandas server stop
  --socket /tmp/demo.sock` and `rm -f /tmp/demo.sock`.
