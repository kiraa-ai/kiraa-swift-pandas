# Homebrew distribution plan

> **Status — planned, not shipped yet.** Phase 2–5 of the daemon (NWListener
> accept loop, background detach, full client subcommands, polish) is live on
> `main`. The Homebrew tap and the GitHub Actions workflow that updates it
> ship in PR 6 once a v0.6.0 release exists. This document captures the full
> spec so PR 6 is a focused execution session, not a design exercise.

## Why a custom tap (and not homebrew-core)?

- **Speed**: pushing to our own tap is instant. homebrew-core has a strict
  review queue (notable popularity, stable releases, no funky tooling) that's
  premature for a beta library.
- **Control**: we update the formula automatically from the same release
  workflow that builds and notarizes the binary. No third-party maintainer.
- **Migration path**: nothing stops us from submitting `swiftpandas` to
  homebrew-core once it's stable and has user traction. The formula in our
  tap is a near-drop-in for what homebrew-core would accept.

## Repository layout

```
github.com/kiraa-ai/homebrew-tap
├── Formula/
│   └── swiftpandas.rb
└── README.md
```

Tap repos must be named `homebrew-<tap>` (Homebrew strips the prefix).
Users install with the short form:

```bash
brew install kiraa-ai/tap/swiftpandas
```

or the two-step:

```bash
brew tap kiraa-ai/tap
brew install swiftpandas
```

## The formula

The formula consumes the **existing GitHub Releases ZIP** that
`scripts/build-release.sh` already produces. No Ruby build logic, no Swift
toolchain on the user's machine.

```ruby
# Formula/swiftpandas.rb
class Swiftpandas < Formula
  desc "Fast CSV transformation tool with resident-memory daemon"
  homepage "https://github.com/kiraa-ai/kiraa-swift-pandas"
  url     "https://github.com/kiraa-ai/kiraa-swift-pandas/releases/download/v0.6.0/swiftpandas-v0.6.0-macos15-universal.zip"
  sha256  "<sha256-of-zip>"
  license "Apache-2.0"
  version "0.6.0"

  depends_on macos: :ventura   # matches Package.swift platforms = .macOS(.v13)

  def install
    bin.install "swiftpandas"
    # Defensive: signed + notarized binaries shouldn't carry quarantine after
    # a Homebrew copy, but strip it just in case.
    system "xattr", "-dr", "com.apple.quarantine", bin/"swiftpandas"
  end

  service do
    run [opt_bin/"swiftpandas", "server", "start", "--foreground"]
    keep_alive true
    working_dir var
    log_path        var/"log/swiftpandas.log"
    error_log_path  var/"log/swiftpandas.err"
    environment_variables(
      SWIFTPANDAS_RUNTIME_DIR: var/"swiftpandas",
    )
  end

  test do
    assert_match "swiftpandas", shell_output("#{bin}/swiftpandas --help")
    assert_match "server",      shell_output("#{bin}/swiftpandas --help")
  end
end
```

Notable choices:

- **No `bottle do { ... }` block** — the universal Mach-O is a single artifact;
  the `url` + `sha256` pair is the cleanest way to deliver it.
- **`SWIFTPANDAS_RUNTIME_DIR`** in the service block keeps the brew-managed
  daemon's pid + socket under `$(brew --prefix)/var/swiftpandas/` so it
  doesn't collide with users running the same binary manually against the
  default `~/.swiftpandas/`.
- **`xattr -dr`** as belt-and-suspenders against quarantine, even though
  Apple-notarized binaries don't normally need it.
- **`depends_on macos: :ventura`** matches the SPM platform constraint at
  [Package.swift:141](../Package.swift#L141).

## User workflow

```bash
brew install kiraa-ai/tap/swiftpandas    # one-time

brew services start swiftpandas          # daemon up; restarts on login + crash
brew services list                       # see status: "started   user   <path-to-plist>"

swiftpandas load sales.csv --name sales
swiftpandas pipe --from sales --name big -c "filter(revenue > 10000) | sort(revenue, desc)"
swiftpandas server status                # pid, uptime, df count, memory
swiftpandas save big out.csv

brew services stop  swiftpandas          # also unloads the LaunchAgent
```

## Release workflow (`.github/workflows/release.yml`)

Triggers on a GitHub release being **published**, not on tag push — that way
the signed + notarized binary is already attached when CI runs.

```yaml
name: release-tap-update

on:
  release:
    types: [published]

jobs:
  update-tap-formula:
    runs-on: macos-14
    permissions:
      contents: read
    steps:
      - name: Download release asset
        run: |
          gh release download "${{ github.event.release.tag_name }}" \
            --repo "${{ github.repository }}" \
            --pattern 'swiftpandas-*-macos*-universal.zip'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Compute checksum
        id: sha
        run: |
          ZIP=$(ls swiftpandas-*-macos*-universal.zip | head -1)
          echo "zip=$ZIP" >> "$GITHUB_OUTPUT"
          echo "sha256=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" >> "$GITHUB_OUTPUT"

      - name: Update tap formula
        env:
          GH_TOKEN: ${{ secrets.TAP_REPO_TOKEN }}      # PAT with contents:write on the tap
          ZIP:    ${{ steps.sha.outputs.zip }}
          SHA256: ${{ steps.sha.outputs.sha256 }}
          TAG:    ${{ github.event.release.tag_name }}
        run: |
          VERSION="${TAG#v}"
          URL="https://github.com/${{ github.repository }}/releases/download/${TAG}/${ZIP}"
          cat > /tmp/swiftpandas.rb <<EOF
          class Swiftpandas < Formula
            desc "Fast CSV transformation tool with resident-memory daemon"
            homepage "https://github.com/${{ github.repository }}"
            url     "${URL}"
            sha256  "${SHA256}"
            license "Apache-2.0"
            version "${VERSION}"
            depends_on macos: :ventura

            def install
              bin.install "swiftpandas"
              system "xattr", "-dr", "com.apple.quarantine", bin/"swiftpandas"
            end

            service do
              run [opt_bin/"swiftpandas", "server", "start", "--foreground"]
              keep_alive true
              working_dir var
              log_path        var/"log/swiftpandas.log"
              error_log_path  var/"log/swiftpandas.err"
              environment_variables(SWIFTPANDAS_RUNTIME_DIR: var/"swiftpandas")
            end

            test do
              assert_match "swiftpandas", shell_output("#{bin}/swiftpandas --help")
            end
          end
          EOF
          # Push the regenerated formula to the tap repo on default branch.
          gh api -X PUT \
            -H "Accept: application/vnd.github.v3+json" \
            "/repos/kiraa-ai/homebrew-tap/contents/Formula/swiftpandas.rb" \
            -f message="swiftpandas ${VERSION}" \
            -f content="$(base64 -i /tmp/swiftpandas.rb)" \
            -f sha="$(gh api /repos/kiraa-ai/homebrew-tap/contents/Formula/swiftpandas.rb --jq .sha 2>/dev/null || echo '')"
```

`TAP_REPO_TOKEN` is a PAT scoped to `contents:write` on `kiraa-ai/homebrew-tap`,
stored as a repo secret on `kiraa-ai/kiraa-swift-pandas`.

The build + signing + notarization stays local (Apple Developer ID credentials
live in the maintainer's keychain). The workflow only updates the formula
after the release is already cut.

## Caveats and trade-offs

- **`brew services` vs manual daemon**: brew-managed launchd plist owns
  `$(brew --prefix)/var/swiftpandas/sock`; manual `swiftpandas server start`
  owns `~/.swiftpandas/sock`. They don't collide. Don't run both at once
  unless you have a good reason; client commands default to
  `~/.swiftpandas/sock`, so to talk to the brew-managed daemon you'd pass
  `--socket $(brew --prefix)/var/swiftpandas/sock` or set
  `SWIFTPANDAS_SOCK` in your shell rc.
- **Notarization staple in Homebrew copy**: the cp step in `bin.install`
  preserves extended attributes including the notarization staple. The
  `xattr -dr com.apple.quarantine` in the install block strips quarantine
  marks that Gatekeeper may otherwise apply on the first run.
- **Apple Silicon vs Intel parity**: `lipo -archs` in
  [`scripts/build-release.sh`](../scripts/build-release.sh) already prints
  `arm64 x86_64` in the release notes. Spot-check on both archs before
  tagging v0.6.0.
- **homebrew-core migration**: when ready, the formula here is mostly
  copy-paste compatible. Differences: homebrew-core forbids `xattr` calls
  (instead use the `:cellar` `:any_skip_relocation` annotation), and bottles
  must be built by Homebrew CI.

## Verification checklist (PR 6)

1. `brew tap kiraa-ai/tap`
2. `brew install --verbose --debug swiftpandas` — capture install log.
3. `brew test swiftpandas` — must pass.
4. `brew services start swiftpandas` → `swiftpandas server status` (against
   the brew socket) → run full load/pipe/save pipeline → `brew services stop`.
5. `swiftpandas server status` after stop → exit 2 (no server running).
6. `brew uninstall swiftpandas` → cellar gone.
7. Spot-check on an Intel Mac (or via VM): same flow.
8. `brew audit --strict --new-formula Formula/swiftpandas.rb` — formula-quality lint.
