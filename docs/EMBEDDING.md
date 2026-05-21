# Embedding SwiftPandas as a binary in an Xcode project

This page documents the two paths for consuming the SwiftPandas **library** (not the CLI) inside another Apple project — an iOS app, a macOS app, a SwiftPM library, etc. Both produce identical functionality; pick the one that matches your project layout.

| Path | Best for | How long to integrate |
|---|---|---|
| **[A. SwiftPM binary dependency](#a-swiftpm-binary-dependency-package-manifest)** | Projects already using `Package.swift` | ~1 minute |
| **[B. Drag XCFramework into Xcode](#b-drag-xcframework-into-xcode-no-swiftpm)** | Pure-Xcode projects with no SwiftPM | ~2 minutes |

If you want the **`swiftpandas` CLI** as a binary (not the library), use `brew install kiraa-ai/tap/swiftpandas` instead — see [HOMEBREW.md](HOMEBREW.md).

---

## What you get either way

The XCFramework bundles three slices, signed for distribution:

| Slice | Use case |
|---|---|
| `macos-arm64_x86_64` | macOS apps (Apple Silicon + Intel) |
| `ios-arm64` | iOS device builds |
| `ios-arm64_x86_64-simulator` | iOS Simulator (Apple Silicon + Intel) |

You import `SwiftPandas` from Swift and use `DataFrame`, `Series`, `LazyDataFrame`, etc. — the full library surface. The XCFramework bundles its three vendored C dependencies (klib's `khash`, `skiplist`, UltraJSON) statically, so consumers don't pull in any system-level C libraries.

What you **don't** get from the binary: the `swiftpandas` CLI executable, the resident-memory daemon, the GUI, the side-by-side demo scripts. Those are CLI-shaped, not library-shaped. Use the Homebrew install for those.

---

## A. SwiftPM binary dependency (Package manifest)

The fast path for any project that already has a `Package.swift`.

### 1. Add the dependency

In your project's `Package.swift`, add SwiftPandas to `dependencies` and to the target that needs it:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyApp",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "MyApp", targets: ["MyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kiraa-ai/kiraa-swift-pandas.git", from: "0.6.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "SwiftPandas", package: "kiraa-swift-pandas"),
            ]
        ),
    ]
)
```

### 2. Switch to binary mode

By default the package builds from source — works on Linux, slower first build. To consume the pre-built XCFramework instead, set the env var when resolving and building:

```bash
export SWIFTPANDAS_USE_BINARY=1
swift package resolve   # pulls SwiftPandas.xcframework.zip from GitHub Releases
swift build
```

You can also bake this into your CI workflow:

```yaml
- name: Build with SwiftPandas binary
  env:
    SWIFTPANDAS_USE_BINARY: 1
  run: swift build
```

### 3. Use it

```swift
import SwiftPandas

let df = try DataFrame.readCSV(path: "/path/to/sales.csv")
let summary = df
    .lazy()
    .filter("revenue", >, 10_000)
    .groupBy("region")
    .sum()
    .collect()
print(summary)
```

### Pinning to a specific version

The XCFramework URL + checksum baked into Package.swift point at one **specific** release. Even if you resolve to a newer git tag, the binary you get is whatever was last uploaded under that URL.

To upgrade to a newer pre-built binary, the SwiftPandas maintainer needs to:
1. Re-run `scripts/build-xcframework.sh --release-tag v<NEW>` (uploads + auto-updates Package.swift).
2. Commit and push the bumped constants.
3. Tag the commit.

Then consumers can `swift package update` and `SWIFTPANDAS_USE_BINARY=1 swift build` to pick up the new binary.

---

## B. Drag XCFramework into Xcode (no SwiftPM)

For projects without a Package manifest — a pure-Xcode app, a workspace, or something with custom build phases SwiftPM can't model.

### 1. Download the XCFramework

```bash
# Latest stable XCFramework as of writing:
gh release download v0.5.0-beta \
  --repo kiraa-ai/kiraa-swift-pandas \
  --pattern 'SwiftPandas.xcframework.zip'
unzip SwiftPandas.xcframework.zip
# Produces SwiftPandas.xcframework/ in the current directory.
```

Or download from <https://github.com/kiraa-ai/kiraa-swift-pandas/releases> in the browser.

> **Note**: as of v0.6.1-beta the XCFramework asset is only attached to **v0.5.0-beta** (the most recent release with a published library binary). v0.6.1-beta only ships the CLI ZIP. The next library-binary refresh is tracked in [ROADMAP.md](ROADMAP.md). For now, consume v0.5.0-beta via this path; if you need a more recent binary, use **Path A** with `SWIFTPANDAS_USE_BINARY=1` against an updated tag.

Move the unzipped `SwiftPandas.xcframework` into your project — somewhere committed-or-not depending on your preference. A common layout:

```
MyApp/
├── MyApp.xcodeproj
├── MyApp/
│   └── … sources …
└── Frameworks/
    └── SwiftPandas.xcframework   ← here
```

If you want git not to track binary artifacts, add to `.gitignore`:

```
Frameworks/*.xcframework
Frameworks/*.xcframework.zip
```

…and document for collaborators how to re-fetch.

### 2. Add it to your Xcode target

1. Open `MyApp.xcodeproj` in Xcode.
2. In the **Project Navigator** (left sidebar), select your project at the top.
3. In the editor that opens, select your **app target** (not the project — the target row beneath it).
4. Click the **General** tab.
5. Scroll down to **Frameworks, Libraries, and Embedded Content**.
6. Click the **+** button.
7. In the picker that appears, click **Add Other...** → **Add Files...**.
8. Navigate to `Frameworks/SwiftPandas.xcframework`, select it, click **Open**.
9. Back in the **Frameworks, Libraries, and Embedded Content** list, find the new `SwiftPandas.xcframework` row.
10. In the **Embed** dropdown for that row, choose:
    - **Embed & Sign** — for app targets (the framework is bundled into your `.app` and re-signed with your team's identity).
    - **Do Not Embed** — for library targets that don't ship the framework themselves (the dependent app target will).

### 3. Import and use

```swift
import SwiftPandas

func analyseSales() throws {
    let df = try DataFrame.readCSV(path: Bundle.main.path(forResource: "sales", ofType: "csv")!)
    print(df.head())
}
```

### Troubleshooting

| Symptom | Fix |
|---|---|
| `No such module 'SwiftPandas'` at build time | The framework wasn't added to the **target's** "Frameworks, Libraries, and Embedded Content" — only to the project. Re-check step 3. |
| `Library not loaded: @rpath/SwiftPandas.framework/…` at runtime | The Embed setting is "Do Not Embed" on an app target. Change it to "Embed & Sign". |
| Build succeeds but archive fails App Store validation | The XCFramework's signature is from the SwiftPandas maintainer's Developer ID. App Store distribution requires re-signing with your team's identity. Xcode does this automatically when you Embed & Sign — but if you copied the framework via a build script that bypassed Xcode's signing, you may need to add a manual `codesign --force --sign $(EXPANDED_CODE_SIGN_IDENTITY)` step. |
| Simulator builds fail with "incompatible architecture" | You're probably building for `iphonesimulator-x86_64` (Intel Mac running iOS Simulator). The XCFramework includes that slice; if Xcode picks the wrong one, do **Product → Clean Build Folder** and try again. |

---

## Comparing the two paths

| Concern | A. SwiftPM | B. Drag-into-Xcode |
|---|---|---|
| **Setup time** | Edit one file + one env var | 10 clicks in the Xcode UI |
| **Version locking** | Pinned via `Package.resolved` | Whatever XCFramework happens to be on disk |
| **CI integration** | `swift build` in a workflow | Need to commit the framework or fetch it as a pre-step |
| **Reproducible builds** | Yes (Package.resolved) | Only if you commit the framework (large binary in git) or fetch it deterministically |
| **Sandbox-friendly** | Yes | Yes |
| **iOS / macOS only?** | macOS + iOS only when binary; source build supports Linux too | macOS + iOS only |

Use **A** if you have any choice. **B** exists for the cases where SwiftPM isn't a fit.

---

## Re-issuing the XCFramework (maintainer workflow)

This section is for SwiftPandas maintainers, not consumers. Skip it unless you're cutting a release.

Each library-binary release requires running `scripts/build-xcframework.sh`. The script builds the three slices, signs each with the Developer ID, zips them together, and computes the SwiftPM checksum.

```bash
# 1. Make sure you're on the tag you want to publish.
git checkout v0.6.1-beta

# 2. Build, upload to the matching GitHub release, and auto-update
#    Package.swift's url+checksum constants in one shot.
scripts/build-xcframework.sh --release-tag v0.6.1-beta --update-package-swift

# 3. Commit and push the Package.swift bump.
git add Package.swift
git commit -m "v0.6.1-beta: refresh XCFramework binary"
git push origin main

# 4. Verify binary mode resolves cleanly:
SWIFTPANDAS_USE_BINARY=1 swift package resolve
```

If you run the script with no flags (the old behaviour), it prints the manual upload command and the Package.swift snippet — useful for one-off rebuilds outside the release flow.

---

## Where to get help

- API questions or bugs in the library itself → [GitHub Issues](https://github.com/kiraa-ai/kiraa-swift-pandas/issues) on this repo.
- Xcode integration questions → check the Troubleshooting table above; if not covered, open an issue with the exact error message and your `xcodebuild -showBuildSettings` output for the failing target.

Other install options (source build, GitHub Releases ZIP, Homebrew tap) are catalogued in [INSTALL.md](INSTALL.md).
