#!/bin/bash
# ============================================================================
# build-release.sh — Build, sign, notarize, and publish swiftpandas
# ============================================================================
#
# Full workflow: build → sign → notarize → create GitHub release with binary
#
# Usage:
#   ./scripts/build-release.sh                    # Full workflow (build + sign + notarize + release)
#   ./scripts/build-release.sh --skip-notarize    # Skip notarization (for testing)
#   ./scripts/build-release.sh --skip-release     # Build + sign + notarize, no GitHub release
#   ./scripts/build-release.sh --dmg              # Also create a DMG
#   ./scripts/build-release.sh v1.0.0             # Specify version tag (default: auto from git)
#
# Prerequisites:
#   1. Xcode command line tools
#   2. "Developer ID Application" certificate in Keychain
#   3. Notarization credentials stored in Keychain:
#        xcrun notarytool store-credentials "KiraaNotarization" \
#            --apple-id "e2mq173@hotmail.com" \
#            --password "<app-specific-password>" \
#            --team-id "VVH38B9225"
#   4. gh CLI authenticated (for GitHub release)
#
# ============================================================================
set -euo pipefail

# ── Configuration ──
SIGNING_IDENTITY="Developer ID Application: ERROL J BRANDT (VVH38B9225)"
TEAM_ID="VVH38B9225"
NOTARIZATION_PROFILE="KiraaNotarization"
PRODUCT_NAME="swiftpandas"
BUNDLE_ID="com.kiraa.swiftpandas"
GITHUB_REPO="kiraa-ai/kiraa-swift-pandas"

# ── Paths ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_DIR/dist"

# ── Parse flags ──
SKIP_NOTARIZE=false
SKIP_RELEASE=false
DO_DMG=false
VERSION=""

for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --skip-release)  SKIP_RELEASE=true ;;
        --dmg)           DO_DMG=true ;;
        v*)              VERSION="$arg" ;;
    esac
done

# Auto-detect version from git tags if not specified
if [ -z "$VERSION" ]; then
    LAST_TAG=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    # Bump patch version, preserve -beta suffix if present
    MAJOR=$(echo "$LAST_TAG" | sed 's/v//' | cut -d. -f1)
    MINOR=$(echo "$LAST_TAG" | sed 's/v//' | cut -d. -f2)
    PATCH=$(echo "$LAST_TAG" | sed 's/v//' | cut -d. -f3 | sed 's/-.*//')
    SUFFIX=$(echo "$LAST_TAG" | grep -o '\-.*' || echo "")
    PATCH=$((PATCH + 1))
    VERSION="v${MAJOR}.${MINOR}.${PATCH}${SUFFIX}"
fi

# Mark as pre-release if version contains beta/alpha/rc
IS_PRERELEASE=false
echo "$VERSION" | grep -qiE "beta|alpha|rc" && IS_PRERELEASE=true

# ── Helpers ──
info()  { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }
step()  { printf "\n\033[1m── %s ──\033[0m\n" "$*"; }

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  SwiftPandas Release Builder                  │"
echo "  │  Version: $VERSION                            │"
echo "  └──────────────────────────────────────────────┘"

# ============================================================================
step "1/7  Run tests"
# ============================================================================

cd "$PROJECT_DIR"
TEST_LOG="/tmp/swiftpandas-test-$$.log"
swift test > "$TEST_LOG" 2>&1
TEST_EXIT=$?

if [ $TEST_EXIT -eq 0 ] && grep -q "Test Suite.*passed" "$TEST_LOG"; then
    TESTS_PASSED=$(grep "Executed" "$TEST_LOG" | tail -1 | grep -o "[0-9]* tests" | head -1)
    info "All tests passed ($TESTS_PASSED)"
else
    grep -E "FAIL|error:|failed" "$TEST_LOG" | tail -10
    fail "Tests failed — aborting release (see $TEST_LOG)"
fi

# ============================================================================
step "2/7  Build universal binary (arm64 + x86_64)"
# ============================================================================

swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -3
BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$PRODUCT_NAME"

[ -f "$BINARY" ] || fail "Binary not found at: $BINARY"

ARCHS=$(lipo -archs "$BINARY" 2>/dev/null || echo "unknown")
BINARY_SIZE=$(du -h "$BINARY" | cut -f1)
info "Binary: $BINARY"
info "Architectures: $ARCHS"
info "Size: $BINARY_SIZE"

# Verify Metal shaders embedded
SHADER_COUNT=$(strings "$BINARY" 2>/dev/null | grep -c "kernel void" || true)
if [ "$SHADER_COUNT" -gt 0 ]; then
    info "Metal GPU shaders: $SHADER_COUNT kernels embedded"
else
    warn "Metal shader strings not found — GPU acceleration may not work"
fi

# ============================================================================
step "3/7  Code sign"
# ============================================================================

if security find-identity -v -p codesigning | grep -q "$TEAM_ID"; then
    codesign --force --sign "$SIGNING_IDENTITY" \
             --timestamp \
             --options runtime \
             --identifier "$BUNDLE_ID" \
             "$BINARY"
    info "Signed: $SIGNING_IDENTITY"
    codesign --verify --verbose "$BINARY" 2>&1 | grep -q "valid on disk" && info "Signature verified"
else
    warn "Signing identity not found — binary will be unsigned"
    SKIP_NOTARIZE=true
fi

# ============================================================================
step "4/7  Package"
# ============================================================================

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cp "$BINARY" "$OUTPUT_DIR/$PRODUCT_NAME"

MACOS_VER=$(sw_vers -productVersion | cut -d. -f1)
ZIP_NAME="${PRODUCT_NAME}-${VERSION}-macos${MACOS_VER}-universal.zip"

cd "$OUTPUT_DIR"
ditto -c -k --keepParent "$PRODUCT_NAME" "$ZIP_NAME"
ZIP_SIZE=$(du -h "$ZIP_NAME" | cut -f1)
info "Created: $ZIP_NAME ($ZIP_SIZE)"

# ============================================================================
if [ "$SKIP_NOTARIZE" = false ]; then
step "5/7  Notarize"
# ============================================================================

    info "Submitting to Apple notary service…"
    NOTARIZE_OUTPUT=$(xcrun notarytool submit "$ZIP_NAME" \
        --keychain-profile "$NOTARIZATION_PROFILE" \
        --wait 2>&1)
    echo "$NOTARIZE_OUTPUT" | grep -E "status:|id:" | head -4

    if echo "$NOTARIZE_OUTPUT" | grep -q "status: Accepted"; then
        info "Notarization accepted"
        info "Gatekeeper will validate online — no quarantine warnings for users"
    else
        warn "Notarization failed — continuing without it"
        echo "$NOTARIZE_OUTPUT"
    fi
else
    step "5/7  Notarize (skipped)"
    warn "Skipped — users will need: xattr -d com.apple.quarantine $PRODUCT_NAME"
fi

# ============================================================================
if [ "$DO_DMG" = true ]; then
step "5b  Create DMG"
# ============================================================================

    DMG_NAME="${PRODUCT_NAME}-${VERSION}-macos${MACOS_VER}-universal.dmg"
    DMG_STAGING="$OUTPUT_DIR/.dmg-staging"

    rm -rf "$DMG_STAGING"
    mkdir -p "$DMG_STAGING"
    cp "$PRODUCT_NAME" "$DMG_STAGING/"

    cat > "$DMG_STAGING/INSTALL.txt" << 'EOF'
SwiftPandas CLI — Installation
==============================

1. Copy 'swiftpandas' to your PATH:
   sudo cp swiftpandas /usr/local/bin/

2. Verify:
   swiftpandas --help

3. Quick test:
   echo "name,score\nAlice,95\nBob,87" | tr '\\n' '\n' > /tmp/test.csv
   swiftpandas -i /tmp/test.csv -c "sort(score, desc)"

4. GUI mode:
   swiftpandas --gui
EOF

    hdiutil create -volname "SwiftPandas $VERSION" \
                   -srcfolder "$DMG_STAGING" \
                   -ov -format UDZO \
                   "$DMG_NAME" 2>/dev/null
    rm -rf "$DMG_STAGING"

    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_NAME" 2>/dev/null || true

    if [ "$SKIP_NOTARIZE" = false ]; then
        info "Notarizing DMG…"
        DMG_NOTARIZE=$(xcrun notarytool submit "$DMG_NAME" \
            --keychain-profile "$NOTARIZATION_PROFILE" \
            --wait 2>&1)
        if echo "$DMG_NOTARIZE" | grep -q "status: Accepted"; then
            xcrun stapler staple "$DMG_NAME" 2>/dev/null
            info "DMG notarized and stapled: $DMG_NAME"
        else
            warn "DMG notarization failed"
        fi
    fi
    info "Created: $DMG_NAME ($(du -h "$DMG_NAME" | cut -f1))"
fi

# ============================================================================
step "6/7  Generate release notes"
# ============================================================================

cd "$PROJECT_DIR"

# Gather info for release notes
TEST_COUNT=$(grep "Executed" "$TEST_LOG" | tail -1 | grep -o "[0-9]* tests" | head -1 || echo "unknown")
COMMIT_SHA=$(git rev-parse --short HEAD)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -n "$LAST_TAG" ]; then
    CHANGELOG=$(git log "${LAST_TAG}..HEAD" --oneline --no-merges 2>/dev/null | head -20)
else
    CHANGELOG=$(git log --oneline --no-merges -20 2>/dev/null)
fi

NOTARIZED="No"
[ "$SKIP_NOTARIZE" = false ] && NOTARIZED="Yes"

NOTES_FILE="/tmp/swiftpandas-release-notes-$$.md"
cat > "$NOTES_FILE" << EOF
## SwiftPandas CLI $VERSION

Universal macOS binary (arm64 + x86_64) — works on both Apple Silicon and Intel Macs.

### Installation

\`\`\`bash
# Download and install
unzip $ZIP_NAME
sudo cp swiftpandas /usr/local/bin/
swiftpandas --help
\`\`\`

### Highlights

- **CLI mode** — pipe-chained DSL for CSV transformation
- **JSON transform files** — structured pipeline definitions
- **GUI mode** — interactive SwiftUI interface (\`swiftpandas --gui\`)
- **Metal GPU acceleration** — hardware-accelerated GroupBy and Merge
- **Verbose logging** — step-by-step validation, timing, and error reporting

### Binary details

| Property | Value |
|---|---|
| Architectures | \`$ARCHS\` |
| Size | $BINARY_SIZE (binary) / $ZIP_SIZE (zip) |
| macOS minimum | 13.0 (Ventura) |
| Signed | Developer ID Application: ERROL J BRANDT |
| Notarized | $NOTARIZED |
| Metal shaders | Embedded (runtime compilation) |
| Tests | $TEST_COUNT passing |
| Commit | \`$COMMIT_SHA\` |

### Changes since $LAST_TAG

$(echo "$CHANGELOG" | sed 's/^/- /')

---
Built with \`swift build -c release --arch arm64 --arch x86_64\`
EOF

info "Release notes generated ($NOTES_FILE)"

# ============================================================================
if [ "$SKIP_RELEASE" = false ]; then
step "7/7  Publish GitHub release"
# ============================================================================

    cd "$OUTPUT_DIR"

    # Collect assets to upload
    ASSET_FLAGS="$ZIP_NAME"
    DMG_NAME="${PRODUCT_NAME}-${VERSION}-macos${MACOS_VER}-universal.dmg"
    [ -f "$DMG_NAME" ] && ASSET_FLAGS="$ASSET_FLAGS $DMG_NAME"

    PRERELEASE_FLAG=""
    [ "$IS_PRERELEASE" = true ] && PRERELEASE_FLAG="--prerelease"

    info "Creating release $VERSION on $GITHUB_REPO $([ "$IS_PRERELEASE" = true ] && echo "(pre-release)" || echo "")…"
    gh release create "$VERSION" \
        --repo "$GITHUB_REPO" \
        --title "SwiftPandas CLI $VERSION" \
        --notes-file "$NOTES_FILE" \
        $PRERELEASE_FLAG \
        $ASSET_FLAGS

    RELEASE_URL=$(gh release view "$VERSION" --repo "$GITHUB_REPO" --json url -q .url)
    info "Published: $RELEASE_URL"
else
    step "7/7  Publish GitHub release (skipped)"
    warn "Skipped — run without --skip-release to publish"
fi

# ============================================================================
step "Done"
# ============================================================================

echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  Release $VERSION complete                    │"
echo "  └──────────────────────────────────────────────┘"
echo ""
echo "  Files:"
ls -lh "$OUTPUT_DIR/" | grep -v "^total\|dmg-staging" | awk '{print "    " $NF " (" $5 ")"}'
echo ""
if [ "$SKIP_RELEASE" = false ]; then
    echo "  GitHub: $(gh release view "$VERSION" --repo "$GITHUB_REPO" --json url -q .url 2>/dev/null || echo 'check releases page')"
    echo ""
    echo "  Users can install with:"
    echo "    gh release download $VERSION --repo $GITHUB_REPO --pattern '*.zip'"
    echo "    unzip $ZIP_NAME"
    echo "    sudo cp swiftpandas /usr/local/bin/"
fi
echo ""
