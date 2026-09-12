#!/usr/bin/env bash
# ============================================================================
# release.sh — orchestrate a SwiftPandas release, end to end
#
# The release is split at the review gate (release PRs are approved like any
# other PR), so it runs in three phases:
#
#   prepare <version>   Build the XCFramework from current main, compute its
#                       checksum, stamp version/CHANGELOG/Package.swift, and
#                       open the release PR. The zip stays in dist/ — publish
#                       uploads that exact artifact, so the checksum committed
#                       in the PR matches the asset byte-for-byte.
#
#   publish <version>   After the release PR merges: verify main's pin
#                       matches dist/'s zip, tag, create the GitHub release
#                       with the CHANGELOG section as notes, upload the zip.
#
#   consumer <version>  In kiraa-engine: sync the vendored
#                       packages/kiraa-swift-pandas tree from this checkout,
#                       pin its Package.swift to the new asset, run the
#                       engine test suite, and open the bump PR.
#
# Usage:
#   scripts/release.sh prepare 0.9.0-beta
#   scripts/release.sh publish 0.9.0-beta          # after the PR merges
#   scripts/release.sh consumer 0.9.0-beta [path]  # default ../kiraa-engine
#
# Prerequisites: gh (authenticated), xcodegen, Xcode CLT.
# ============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

phase="${1:-}"
version="${2:-}"
[ -n "$phase" ] && [ -n "$version" ] || {
    echo "usage: scripts/release.sh {prepare|publish|consumer} <version> [engine-path]" >&2
    exit 1
}
tag="v${version}"
zip_path="dist/SwiftPandas.xcframework.zip"
asset_url="https://github.com/kiraa-ai/kiraa-swift-pandas/releases/download/${tag}/SwiftPandas.xcframework.zip"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
die()  { echo "ERROR: $1" >&2; exit 1; }

case "$phase" in
# ────────────────────────────────────────────────────────────────────────────
prepare)
    step "Preflight"
    [ "$(git branch --show-current)" = "main" ] || die "run prepare from main"
    git fetch origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
        || die "main is not in sync with origin/main"
    if [ -n "$(git status --porcelain)" ]; then
        echo "WARNING: working tree has local changes; only release files will be committed:"
        git status --short
    fi
    git rev-parse -q --verify "refs/tags/${tag}" >/dev/null && die "tag ${tag} already exists"

    step "Tests + validation on the release candidate"
    swift test 2>&1 | tail -1 | grep -q "passed" || die "swift test failed"
    bash scripts/validate/run_validation.sh >/dev/null || die "validation failed"

    step "Build XCFramework (this takes a few minutes)"
    ./scripts/build-xcframework.sh
    [ -f "$zip_path" ] || die "expected ${zip_path} after build"
    checksum="$(swift package compute-checksum "$zip_path")"
    echo "checksum: ${checksum}"

    step "Stamp version ${version}"
    git checkout -b "release/${tag}"
    # Version constant
    sed -i '' -E "s|(public static var version: String \{ \")[^\"]+(\" \})|\1${version}\2|" \
        Sources/SwiftPandas/SwiftPandas.swift
    grep -q "\"${version}\"" Sources/SwiftPandas/SwiftPandas.swift \
        || die "failed to stamp version constant"
    # Binary pin — points at the asset publish will upload
    sed -i '' -E "s|^let xcframeworkURL = .*$|let xcframeworkURL = \"${asset_url}\"|" Package.swift
    sed -i '' -E "s|^let xcframeworkChecksum = .*$|let xcframeworkChecksum = \"${checksum}\"|" Package.swift
    grep -q "$checksum" Package.swift || die "failed to pin checksum"
    # CHANGELOG: retitle Unreleased as this version, add a fresh Unreleased
    release_date="$(date +%Y-%m-%d)"
    sed -i '' "s|^## \[Unreleased\]$|## [Unreleased]\\
\\
## [${version}] — ${release_date}|" CHANGELOG.md
    grep -q "## \[${version}\]" CHANGELOG.md || die "failed to stamp CHANGELOG"

    step "Open release PR"
    git add Package.swift CHANGELOG.md Sources/SwiftPandas/SwiftPandas.swift
    git commit -m "release: ${tag}

Bump version to ${version} and pin Package.swift to the ${tag}
XCFramework asset (checksum ${checksum:0:8}…${checksum: -4}). The asset is
built from this commit's source and uploaded by scripts/release.sh publish
after this PR merges."
    git push -u origin "release/${tag}"
    gh pr create --base main --head "release/${tag}" \
        --title "release: ${tag}" \
        --body "Version bump + XCFramework pin for ${tag}. Asset checksum \`${checksum}\` (built from this source; \`scripts/release.sh publish ${version}\` uploads the identical zip after merge). Release notes: the \`[${version}]\` section of CHANGELOG.md." \
        --reviewer markos-kiraa
    echo
    echo "NEXT: after the PR merges, run: scripts/release.sh publish ${version}"
    echo "      (keep dist/SwiftPandas.xcframework.zip — publish uploads that exact file)"
    ;;
# ────────────────────────────────────────────────────────────────────────────
publish)
    step "Preflight"
    [ -f "$zip_path" ] || die "missing ${zip_path} — publish uploads the zip prepare built"
    git fetch origin main
    git checkout main >/dev/null 2>&1 || true
    git pull --ff-only
    grep -q "${asset_url}" Package.swift \
        || die "main's Package.swift does not pin ${tag} — has the release PR merged?"
    pinned="$(sed -nE 's|^let xcframeworkChecksum = "([a-f0-9]+)"$|\1|p' Package.swift)"
    actual="$(swift package compute-checksum "$zip_path")"
    [ "$pinned" = "$actual" ] \
        || die "checksum mismatch: Package.swift pins ${pinned} but ${zip_path} is ${actual}"

    step "Tag ${tag}"
    git tag -a "$tag" -m "SwiftPandas ${version}"
    git push origin "$tag"

    step "Create GitHub release + upload asset"
    # Notes = this version's CHANGELOG section
    awk "/^## \[${version}\]/{found=1; next} /^## \[/{if(found) exit} found" CHANGELOG.md > /tmp/release-notes.md
    gh release create "$tag" "$zip_path" \
        --title "SwiftPandas ${version}" \
        --notes-file /tmp/release-notes.md
    echo
    echo "NEXT: scripts/release.sh consumer ${version}"
    ;;
# ────────────────────────────────────────────────────────────────────────────
consumer)
    engine="${3:-$repo_root/../kiraa-engine}"
    vendored="$engine/packages/kiraa-swift-pandas"
    [ -d "$vendored" ] || die "vendored package not found at ${vendored}"

    step "Preflight (kiraa-engine)"
    git -C "$engine" fetch origin
    branch="bump/swiftpandas-${tag}"
    git -C "$engine" checkout -b "$branch" origin/main

    step "Sync vendored source + pin binary"
    rsync -a --delete "$repo_root/Sources/" "$vendored/Sources/"
    rsync -a --delete "$repo_root/Tests/"   "$vendored/Tests/"
    cp "$repo_root/CHANGELOG.md" "$vendored/CHANGELOG.md"
    sed -i '' -E "s|^let xcframeworkURL = .*$|let xcframeworkURL = \"${asset_url}\"|" "$vendored/Package.swift"
    checksum="$(sed -nE 's|^let xcframeworkChecksum = "([a-f0-9]+)"$|\1|p' "$repo_root/Package.swift")"
    sed -i '' -E "s|^let xcframeworkChecksum = .*$|let xcframeworkChecksum = \"${checksum}\"|" "$vendored/Package.swift"

    step "Engine test suite (includes byte-exact CSV pins)"
    (cd "$engine" && bash scripts/run-tests.sh) || die "kiraa-engine tests failed against ${tag}"

    step "Open bump PR"
    git -C "$engine" add packages/kiraa-swift-pandas
    git -C "$engine" commit -m "chore: bump SwiftPandas to ${tag}

Vendored source synced to the ${tag} release; binary pin updated
(checksum ${checksum:0:8}…). scripts/run-tests.sh green, including the
byte-exact CSV emission pins."
    git -C "$engine" push -u origin "$branch"
    (cd "$engine" && gh pr create --base main --head "$branch" \
        --title "chore: bump SwiftPandas to ${tag}" \
        --body "Dependency bump to [${tag}](https://github.com/kiraa-ai/kiraa-swift-pandas/releases/tag/${tag}) — CSV/columnar I/O acceleration (kiraa-swift-pandas#30). \`scripts/run-tests.sh\` green including the byte-exact CSV pins. Follow-up: re-run the AC10 job (same month as job 15598) for the before/after wall-clock.")
    ;;
*)
    die "unknown phase '${phase}' (expected prepare|publish|consumer)"
    ;;
esac
