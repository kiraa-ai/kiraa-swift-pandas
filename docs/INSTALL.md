# Installing `swiftpandas`

Four install paths, all producing a binary with identical daemon behaviour.
Pick the one that matches your environment.

| Path | Toolchain needed | Speed | Auto-start daemon | Audience |
|---|---|---|---|---|
| [Source build](#source-build) | Swift 5.9+ / Xcode CLT | ~30 s | No | Contributors, embedded use |
| [SwiftPM library import](#swiftpm-library-import) | Swift 5.9+ | n/a | n/a | App developers embedding the library |
| [GitHub Releases ZIP](#github-releases-zip) | None | <5 s | No (manual `server start`) | Power users, scripts, CI |
| [Homebrew tap](#homebrew-tap) (planned) | Homebrew | ~10 s | Yes, via `brew services start` | Mac users who use Homebrew |

All four paths produce a binary that:
- Builds a universal Mach-O on macOS (`arm64` + `x86_64`).
- Targets macOS 13+ / iOS 16+ (`Package.swift` baseline; the library import works on iOS too).
- Bundles Metal GPU shaders and Apple Accelerate vDSP for groupby + merge.
- Is signed with Developer ID `ERROL J BRANDT (VVH38B9225)` and Apple-notarized when distributed via the GitHub Releases ZIP or the Homebrew tap.

---

## Source build

For contributors, embedded use, or anyone who wants the head of the repo:

```bash
git clone https://github.com/kiraa-ai/kiraa-swift-pandas.git
cd kiraa-swift-pandas
swift build -c release
sudo cp .build/release/swiftpandas /usr/local/bin/
swiftpandas --help
```

Verify with the full test suite (~400 tests):

```bash
swift test
```

---

## SwiftPM library import

To embed the SwiftPandas library in your own Swift package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/kiraa-ai/kiraa-swift-pandas.git", from: "0.6.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "SwiftPandas", package: "kiraa-swift-pandas")]
    ),
]
```

For faster CI builds you can opt into the prebuilt XCFramework:

```bash
SWIFTPANDAS_USE_BINARY=1 swift build
```

This consumes [`SwiftPandas.xcframework.zip`](https://github.com/kiraa-ai/kiraa-swift-pandas/releases/latest)
attached to the matching tagged release. See [Package.swift](../Package.swift) line 52 for the toggle.

> The library import gives you `DataFrame`, `Series`, `LazyDataFrame`, etc. for
> embedded use. The daemon (`swiftpandas server start`) is part of the CLI
> executable target, not the library — embed the library if you want
> SwiftPandas types in your own process; install the binary if you want a
> standalone server.

### Embedding the binary in an Xcode project (no SwiftPM)

If your project doesn't use a `Package.swift` — pure-Xcode apps, workspaces, build-script-heavy targets — you can drag `SwiftPandas.xcframework` straight into Xcode's **Frameworks, Libraries, and Embedded Content**. Full step-by-step walkthrough in **[docs/EMBEDDING.md → Path B](EMBEDDING.md#b-drag-xcframework-into-xcode-no-swiftpm)**.

The same doc covers Path A (the SwiftPM binary route above) in more depth and explains how maintainers re-issue the XCFramework on each release via `scripts/build-xcframework.sh --release-tag <TAG> --update-package-swift`.

---

## GitHub Releases ZIP

For users who want the signed + notarized prebuilt CLI without a Swift toolchain:

```bash
gh release download v0.6.0 --repo kiraa-ai/kiraa-swift-pandas \
  --pattern 'swiftpandas-*-macos*-universal.zip'
unzip swiftpandas-*-macos*-universal.zip
sudo cp swiftpandas /usr/local/bin/
swiftpandas --help
```

Verify the binary's signature and notarization:

```bash
codesign -dv --verbose=2 /usr/local/bin/swiftpandas
spctl -a -vv /usr/local/bin/swiftpandas        # should report "accepted"
shasum -a 256 /usr/local/bin/swiftpandas       # match the release notes hash
```

Daemon control is manual under this path:

```bash
swiftpandas server start                       # spawns daemon
swiftpandas load sales.csv --name sales
swiftpandas server stop                        # shuts it down
```

For auto-restart on login under this path, write your own LaunchAgent plist
or use a process manager like `tmux`/`screen`/`pm2`. The Homebrew path below
handles this automatically.

---

## Homebrew tap

> **Planned** — the tap and `Formula/swiftpandas.rb` will live at
> `github.com/kiraa-ai/homebrew-tap` and ship together with the v0.6.0 release.
> See [docs/HOMEBREW.md](HOMEBREW.md) for the full spec.

Once it lands:

```bash
brew install kiraa-ai/tap/swiftpandas
brew services start swiftpandas                # daemon up now + at login
swiftpandas load sales.csv --name sales
swiftpandas pipe --from sales --name big -c "filter(revenue > 10000)"
swiftpandas server status                      # pid, uptime, dataframes, memory
brew services stop swiftpandas
```

The formula declares a `service do ... end` block that Homebrew translates
into a LaunchAgent plist, so the daemon survives reboots and restarts on
crash. Pid + socket files live under `$(brew --prefix)/var/swiftpandas/`
(not `~/.swiftpandas/`) when running under brew services, so the same binary
can also be driven manually with `swiftpandas server start` against the
default `~/.swiftpandas/` path without collisions.

---

## Uninstalling

```bash
# Stop daemon first (works for all install paths)
swiftpandas server stop                        # exit 0 if running, 2 if not

# Source build / GitHub Releases:
sudo rm /usr/local/bin/swiftpandas

# Homebrew:
brew services stop swiftpandas
brew uninstall swiftpandas
brew untap kiraa-ai/tap                        # optional
```

The daemon stores no data on disk between sessions — only the runtime files
under `~/.swiftpandas/` (or `$(brew --prefix)/var/swiftpandas/`), which the
daemon unlinks on clean shutdown. Remove them manually if a daemon crashed
mid-flight:

```bash
rm -rf ~/.swiftpandas/
```
