# Resident-memory server (`swiftpandas server`)

> Status — **shipped.** The full daemon (NWListener Unix-domain socket,
> background detach via re-exec + `setsid()`, pid-file management, signal
> handlers, atexit cleanup) lives in `main` and is covered by 60+ tests:
> Registry/Protocol/Handlers/Paths/PIDFile/Transport unit tests plus
> Foreground/Background/Server integration tests that spawn the actual binary.

## Why

The one-shot `swiftpandas` CLI reloads the CSV on every invocation. For
interactive exploration — `load`, then 10 different `pipe`s, then `save` —
that read/parse cost dominates wall time. The resident-memory daemon owns an
in-memory area where named DataFrames live for the lifetime of the server, so
follow-up commands operate on already-decoded columns.

## Concept

```
+-----------------------+        unix-domain socket        +-----------------------------+
| swiftpandas <subcmd>  | <-------- JSON request --------> | swiftpandas-server daemon   |
| (thin client process) |          JSON response             | actor DataFrameRegistry    |
+-----------------------+                                    | [name -> DataFrame slot]   |
                                                             | TransformRunner (existing) |
                                                             +-----------------------------+
```

- The same `swiftpandas` binary runs in both roles. `swiftpandas server start`
  spawns it in daemon mode; every other subcommand connects to the daemon's
  socket, sends one request, prints the reply, and exits.
- DataFrames are *value* types with copy-on-write buffers
  ([DataFrame.swift](../Sources/SwiftPandas/DataFrame/DataFrame.swift)), so
  storing them inside an `actor` and passing them across `await` boundaries
  is safe and cheap.
- A DataFrame command issued with **no server running** fails with exit
  code 2 and a clear message. There is no auto-launch: starting the daemon is
  an explicit, observable act.

## Intended workflow

```bash
swiftpandas server start                                       # spawns the daemon
swiftpandas load sales.csv --name sales                          # reads CSV once
swiftpandas pipe --from sales --name big -c "filter(revenue > 10000)"
swiftpandas pipe --from big   --name ranked -c "sort(revenue, desc) | head(20)"
swiftpandas list                                               # see resident DFs + sizes
swiftpandas show ranked --head 5                               # preview
swiftpandas save ranked /tmp/top20.csv                         # write a result
swiftpandas drop sales                                         # free memory
swiftpandas server stop                                        # shutdown, free everything
```

## CLI surface

| Subcommand | Args / flags | Notes |
|---|---|---|
| `swiftpandas server start` | `--foreground`, `--socket <path>`, `--pidfile <path>`, `--log <path>` | spawns daemon; idempotent if already running |
| `swiftpandas server stop` | `--socket <path>` | sends `shutdown`, frees registry |
| `swiftpandas server status` | `--socket <path>` | pid, uptime, dataframe count, total bytes |
| `swiftpandas load <csv>` | `--name <name>`, `--sep ,` | reads CSV in the daemon, binds under name |
| `swiftpandas pipe` | `--from <name>`, `--name <name>`, `-c <dsl>` \| `-f <json>` | runs `TransformRunner` server-side |
| `swiftpandas save <name> <csv>` | `--sep ,` | writes a resident DataFrame to CSV |
| `swiftpandas list` | — | dumps name × rows × cols × bytes × createdAt |
| `swiftpandas drop <name>` | — | unbinds and reports freed bytes |
| `swiftpandas show <name>` | `--head N` (default 10) | CSV preview, capped at 1 MiB |
| `swiftpandas run` (legacy) | existing one-shot flags | unchanged; remains the **default subcommand** so `swiftpandas -i a.csv -c "..."` still works |

### Exit-code contract

All client subcommands follow the same exit codes so scripts can branch
deterministically:

| Code | Meaning |
|------|---------|
| `0` | success |
| `2` | no server running (ENOENT / ECONNREFUSED on socket connect) |
| `3` | server returned `ok:false` (bad name, parse error, unknown column, …) |
| `4` | transport / timeout / protocol error |
| `5` | `server start` blocked by a live duplicate daemon |
| `6` | `server start` failed to spawn the daemon |
| `7` | Phase 1 only — server-start placeholder; removed in Phase 2 |

## Wire protocol (v1)

Newline-delimited JSON over a Unix domain socket. One request and one
response per frame; both are short enough that no length prefix is needed.

### Request

```json
{
  "v": 1,
  "id": "<uuid-v4>",
  "cmd": "load | pipe | save | list | drop | show | status | shutdown",
  "path": "...", "name": "...", "from": "...",
  "chain": "<dsl>", "json": "<json>", "sep": ",", "head": 10
}
```

Only fields relevant to the chosen `cmd` are required; the rest are
ignored. `name` is the single field every DataFrame-aware command uses to
identify what it operates on — for `load` and `pipe` it's the **target**
binding (where the result goes); for `save`, `drop`, and `show` it's the
**source** (the resident DataFrame to operate on).

### Response

```json
{
  "v": 1,
  "id": "<same uuid>",
  "ok": true,
  "data": { "kind": "load", "name": "df1", "rows": 100, "cols": 4, "bytes": 8192 },
  "warning": "overwrote existing df 'df1'"
}
```

```json
{
  "v": 1,
  "id": "<same uuid>",
  "ok": false,
  "error": { "code": "no_such_df", "message": "no dataframe bound to name 'ghost'" }
}
```

### Stable error codes

Clients should branch on `error.code`. Adding a new code is **not** a breaking
change; unknown codes should be treated as opaque strings.

| Code | When |
|------|------|
| `no_such_df` | `pipe --from`, `save`, `drop`, `show` referenced an unbound name |
| `name_required` | mandatory field (`as`, `from`, `name`, `path`) missing |
| `parse` | DSL or JSON transform failed to parse |
| `unknown_operation` | DSL named an op that does not exist |
| `unknown_column` | pipeline references a column not in the source DataFrame |
| `type_mismatch` | filter or cast got an incompatible type |
| `division_by_zero` | `derive` evaluated `x / 0` |
| `agg_without_groupby` | `agg(...)` did not follow `groupby(...)` |
| `empty_pipeline` | DSL string parsed to zero operations |
| `io` | file not found, CSV write failed, etc. |
| `protocol` | malformed frame |
| `internal` | unhandled error in the daemon (bug) |

## Memory accounting

Each DataFrame reports an estimated byte size via `DataFrame.estimatedBytes`
([DataFrame+Memory.swift](../Sources/SwiftPandas/DataFrame/DataFrame+Memory.swift))
that sums:

- every column's `Column.nbytes` (data buffer + validity bitmap)
- the UTF-8 byte counts of column names
- the UTF-8 byte counts of the index labels (only when non-default)

It is an estimate, not an exact measure: per-object Swift overhead and any
retained slices held outside the value are excluded. The number is intended
for **budgeting and reporting**, not memory-safety guarantees. `list` and
`drop` surface it; `status` aggregates it.

## Concurrency model

`DataFrameRegistry` is a Swift `actor`. The accept loop fans out one
`Task` per inbound frame, and each handler does:

1. `await registry.lookup(source)` — one actor hop
2. compute outside the actor (heavy work: CSV read, `TransformRunner.run`)
3. `await registry.bind(target, result)` — second actor hop

This keeps the registry hot — independent pipelines proceed in parallel,
serialised only at the registry boundary.

## Phasing

| Phase | Scope | Status |
|-------|-------|--------|
| 1 | Library types: `DataFrameRegistry`, `WireRequest`/`WireResponse`, `Handlers`, `DataFrame.estimatedBytes`. Subcommand surface + exit-code contract. | **shipped** |
| 2 | Transport: `NWListener` on `NWEndpoint.unix(path:)`, `NWConnection` client, `server start --foreground`. | **shipped** |
| 3 | Background detach via `Process` re-exec + `setsid()`, pid-file management, signal-driven graceful shutdown, `server stop` + `server status`. | **shipped** |
| 4 | Client subcommands `load`/`pipe`/`save`/`list`/`drop`/`show` wired to the daemon with `--socket` and `--timeout`. | **shipped** |
| 5 | Docs (this file, README, QUICKSTART, INSTALL, HOMEBREW), polish, end-to-end demo script. | **shipped** |
| 6 (follow-up) | Homebrew tap with `brew services` launchd integration. | planned |
| 7 (optional) | Linux POSIX-socket fallback behind `#if !canImport(Network)`. | deferred |

## Testing

| Test target | What it pins down |
|-------------|------------------|
| `DataFrameMemoryTests` | `estimatedBytes` grows with row count, column count, and column-name length; empty DF is 0. |
| `RegistryTests` | actor `bind/lookup/drop/list/clear/totalBytes` semantics, including overwrite-reporting and concurrent binds. |
| `ProtocolTests` | newline framing; JSON round-trip for every `WireCommand` and `WireData` case; snake_case key shape; stable error codes; `CLIError → WireError` mapping. |
| `HandlersTests` | end-to-end handler behaviour against an in-process registry: `load → pipe → save`, `pipe` against an unknown source maps to `no_such_df`, parse / unknown-column errors map to the right `WireErrorCode`. |
| `CLISubcommandTests` | black-box `swiftpandas …` invocations: legacy `-i/-c` still succeeds (default subcommand routing), Phase-1 stub subcommands exit 2 with `"no server running"`, root help advertises every subcommand. |

Run only the server-mode tests:

```bash
swift test --filter 'RegistryTests|ProtocolTests|HandlersTests|DataFrameMemoryTests|CLISubcommandTests'
```

## Open questions

Tracked in [scalable-kindling-otter.md](../../.claude/plans/scalable-kindling-otter.md):

- `NWListener` on `.unix(path:)` quirk on macOS 13.x (mitigation: keep a
  POSIX-socket client-side fallback)
- whether to support an implicit "last DF" alias for `pipe`
- `server stop --force` for unresponsive daemons
- streaming `save` for multi-GB DataFrames
- eviction policy when memory budget is exceeded
