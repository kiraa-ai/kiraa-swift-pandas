import ArgumentParser
import Foundation
import SwiftPandas

/// Root command for the `swiftpandas` executable.
///
/// The CLI exposes two complementary modes:
///
/// 1. **One-shot mode** (`swiftpandas run`, also the default) — load a CSV,
///    apply a DSL pipeline, write the result. No persistent state. This is
///    the legacy behavior and is preserved exactly via the `Run` subcommand
///    plus `defaultSubcommand: Run.self`, so existing scripts
///    `swiftpandas -i in.csv -c "..."` continue to work.
///
/// 2. **Resident-memory mode** (`swiftpandas server start` + `load`, `pipe`,
///    `save`, `list`, `drop`, `show`) — a long-lived daemon owns an in-memory
///    area where DataFrames live across CLI invocations. Phase 1 ships the
///    subcommand surface, library types, registry actor, wire protocol, and
///    handler logic; Phase 2 wires them to a Unix-domain socket. See
///    [docs/SERVER.md](../../docs/SERVER.md) for the full design.
@main
struct SwiftPandas: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftpandas",
        abstract: "Fast CSV transformation tool with a resident-memory daemon mode.",
        discussion: """
        TWO MODES

          • One-shot (default):
              swiftpandas -i data.csv -o out.csv -c "filter(revenue > 10000) | sort(revenue, desc)"
            or equivalently:
              swiftpandas run -i data.csv -o out.csv -c "..."

          • Resident-memory (Phase 2 — subcommand surface is live today):
              swiftpandas server start
              swiftpandas load sales.csv --name sales
              swiftpandas pipe --from sales --name big -c "filter(revenue > 10000)"
              swiftpandas save big out.csv
              swiftpandas server stop

        Run `swiftpandas run --help-ops` for the DSL operation reference.
        """,
        subcommands: [
            Run.self,
            Server.self,
            Load.self,
            Pipe.self,
            Save.self,
            List.self,
            Drop.self,
            Show.self,
            Info.self,
        ],
        defaultSubcommand: Run.self
    )
}
