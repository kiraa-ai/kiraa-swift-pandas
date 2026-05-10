#!/bin/bash
# ============================================================================
# build-xcframework.sh — Build SwiftPandas.xcframework for macOS + iOS
# ============================================================================
#
# Produces dist/SwiftPandas.xcframework.zip containing three slices:
#
#   - macos-arm64_x86_64        (macOS device, Intel + Apple Silicon)
#   - ios-arm64                 (iOS device)
#   - ios-arm64_x86_64-simulator (iOS Simulator, Intel + Apple Silicon)
#
# All slices are built with BUILD_LIBRARY_FOR_DISTRIBUTION=YES so the
# resulting .swiftinterface files are forward-compatible with future
# Xcode/Swift versions.
#
# Usage:
#   ./scripts/build-xcframework.sh
#
# Output:
#   dist/SwiftPandas.xcframework      — the unzipped framework bundle
#   dist/SwiftPandas.xcframework.zip  — the artifact to upload to GitHub Releases
#
# After running:
#   1. Attach dist/SwiftPandas.xcframework.zip to the GitHub release that
#      matches the current git tag (e.g. v0.5.0-beta).
#   2. Update Package.swift's `xcframeworkURL` and `xcframeworkChecksum`
#      to match the uploaded asset (the script prints the new values).
#   3. Commit and tag.
#
# Prerequisites:
#   - Xcode + command line tools installed
#   - xcodegen installed (brew install xcodegen)
#
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/xcframework"
DIST_DIR="$PROJECT_DIR/dist"

info()  { printf "  \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "  \033[33m⚠\033[0m %s\n" "$*"; }
fail()  { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; exit 1; }
step()  { printf "\n\033[1m── %s ──\033[0m\n" "$*"; }

cd "$PROJECT_DIR"

# ── Preflight ──
command -v xcodebuild >/dev/null || fail "xcodebuild not on PATH (install Xcode command line tools)"
command -v xcodegen   >/dev/null || fail "xcodegen not on PATH (brew install xcodegen)"
command -v swift      >/dev/null || fail "swift not on PATH"

# ── Regenerate Xcode project from project.yml ──
step "Regenerating SwiftPandas.xcodeproj"
xcodegen --spec project.yml --quiet
info "project regenerated"

# ── Clean previous build artifacts ──
step "Cleaning previous build artifacts"
rm -rf "$BUILD_DIR" "$DIST_DIR/SwiftPandas.xcframework" "$DIST_DIR/SwiftPandas.xcframework.zip"
mkdir -p "$BUILD_DIR" "$DIST_DIR"
info "cleaned"

# ── Archive each platform slice ──
archive_slice() {
    local scheme="$1"
    local destination="$2"
    local archive_name="$3"

    step "Archiving $archive_name ($destination)"
    xcodebuild archive \
        -project SwiftPandas.xcodeproj \
        -scheme "$scheme" \
        -destination "$destination" \
        -archivePath "$BUILD_DIR/$archive_name.xcarchive" \
        -derivedDataPath "$BUILD_DIR/derived" \
        SKIP_INSTALL=NO \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
        -quiet

    if [ ! -d "$BUILD_DIR/$archive_name.xcarchive/Products/Library/Frameworks/SwiftPandas.framework" ]; then
        fail "Archive completed but SwiftPandas.framework not found in $archive_name"
    fi
    info "$archive_name archived"
}

archive_slice "SwiftPandas"     "generic/platform=macOS"          "SwiftPandas-macOS"
archive_slice "SwiftPandas-iOS" "generic/platform=iOS"            "SwiftPandas-iOS"
archive_slice "SwiftPandas-iOS" "generic/platform=iOS Simulator"  "SwiftPandas-iOSSim"

# ── Bundle into XCFramework ──
step "Creating XCFramework"
xcodebuild -create-xcframework \
    -framework "$BUILD_DIR/SwiftPandas-macOS.xcarchive/Products/Library/Frameworks/SwiftPandas.framework" \
    -framework "$BUILD_DIR/SwiftPandas-iOS.xcarchive/Products/Library/Frameworks/SwiftPandas.framework" \
    -framework "$BUILD_DIR/SwiftPandas-iOSSim.xcarchive/Products/Library/Frameworks/SwiftPandas.framework" \
    -output "$DIST_DIR/SwiftPandas.xcframework" \
    >/dev/null
info "XCFramework written to dist/SwiftPandas.xcframework"

# ── Zip ──
step "Zipping XCFramework"
(cd "$DIST_DIR" && zip -ryq SwiftPandas.xcframework.zip SwiftPandas.xcframework)
ZIP_SIZE=$(du -h "$DIST_DIR/SwiftPandas.xcframework.zip" | cut -f1)
info "dist/SwiftPandas.xcframework.zip ($ZIP_SIZE)"

# ── Compute SPM checksum ──
step "Computing SPM checksum"
CHECKSUM=$(swift package compute-checksum "$DIST_DIR/SwiftPandas.xcframework.zip")
info "checksum: $CHECKSUM"

# ── Detect current tag (if any) ──
CURRENT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")

# ── Final instructions ──
step "Next steps"
cat <<EOF

  1. Upload the artifact to GitHub Releases:

       gh release upload ${CURRENT_TAG:-<TAG>} dist/SwiftPandas.xcframework.zip

  2. Update Package.swift with the new coordinates:

       let xcframeworkURL = "https://github.com/kiraa-ai/kiraa-swift-pandas/releases/download/${CURRENT_TAG:-<TAG>}/SwiftPandas.xcframework.zip"
       let xcframeworkChecksum = "$CHECKSUM"

  3. Verify a binary build resolves cleanly:

       SWIFTPANDAS_USE_BINARY=1 swift package resolve

EOF
