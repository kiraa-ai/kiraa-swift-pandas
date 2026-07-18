#!/usr/bin/env bash
# Test df.groupBy("region").mean() using the SwiftPandas Swift API directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SALES_CSV="$ROOT_DIR/examples/data/sales.csv"
TMPDIR_PKG=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PKG"' EXIT

cat > "$TMPDIR_PKG/Package.swift" <<MANIFEST
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GroupByTest",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "$ROOT_DIR"),
    ],
    targets: [
        .executableTarget(
            name: "GroupByTest",
            dependencies: ["SwiftPandas"],
            path: "Sources"
        ),
    ]
)
MANIFEST

mkdir -p "$TMPDIR_PKG/Sources"

cat > "$TMPDIR_PKG/Sources/main.swift" <<SWIFT
import SwiftPandas

let df = try DataFrame.readCSV(path: "$SALES_CSV")
print("Input (\(df.shape.rows) rows x \(df.shape.columns) cols):")
print(df)
print()

let result = df.groupBy("region").mean()
print("groupBy(\"region\").mean():")
print(result)
SWIFT

swift run --package-path "$TMPDIR_PKG" -c release 2>/dev/null
