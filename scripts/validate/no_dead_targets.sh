#!/usr/bin/env bash
# ============================================================================
# no_dead_targets.sh — guard against dead vendored C targets (proposal B6a)
#
# Fails if Package.swift declares a C `.target` that no Swift file under
# Sources/ ever `import`s. Such a target is compiled (here with -O3) into every
# build for nothing: dead weight in binary size, build time, and audit surface.
# The v0.8.0-beta package shipped three of them (CSkipList/CKHash/CUltraJSON);
# this guard keeps them from creeping back.
#
# Exit 0 = clean (PASS), exit 1 = a declared C target is unused (FAIL).
# ============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

manifest="Package.swift"
[ -f "$manifest" ] || { echo "FAIL: $manifest not found"; exit 1; }

# C targets are those whose source directory holds .c/.h files. Extract every
# target name declared in the manifest, then classify by directory contents.
# (Read into a loop rather than `mapfile` — macOS ships bash 3.2.)
names="$(grep -oE 'name:[[:space:]]*"[A-Za-z0-9_]+"' "$manifest" \
    | sed -E 's/.*"([A-Za-z0-9_]+)".*/\1/' | sort -u)"

dead=0
checked=0
while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir="Sources/$name"
    # Only consider targets backed by C sources.
    if compgen -G "$dir/*.c" > /dev/null 2>&1 || compgen -G "$dir/**/*.h" > /dev/null 2>&1; then
        checked=$((checked + 1))
        if grep -rq --include='*.swift' "import $name" Sources/; then
            echo "ok:   C target '$name' is imported"
        else
            echo "DEAD: C target '$name' is compiled but never imported"
            dead=$((dead + 1))
        fi
    fi
done <<EOF
$names
EOF

echo "---"
if [ "$dead" -gt 0 ]; then
    echo "FAIL: $dead dead C target(s) declared in $manifest"
    exit 1
fi
echo "PASS: no dead C targets ($checked C target(s) checked)"
