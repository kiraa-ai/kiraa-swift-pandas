// swift-tools-version: 5.9
// ============================================================================
// Package.swift — Swift Package Manager manifest for SwiftPandas
// ============================================================================
//
// SwiftPandas is a high-performance data manipulation library for Swift,
// inspired by Python's pandas. This manifest supports two build modes:
//
//   1. **Source build (default)** — compiles SwiftPandas from source.
//      Includes the test suites and the swiftpandas CLI executable.
//
//   2. **Binary build (opt-in)** — set `SWIFTPANDAS_USE_BINARY=1` in the
//      environment to consume a precompiled `SwiftPandas.xcframework.zip`
//      published on the GitHub release for the matching tag. The test
//      targets are dropped from the package graph in this mode; the CLI
//      continues to build from source against the binary library.
//
//   Source mode supports macOS, iOS, and Linux (with reduced functionality
//   when Accelerate/Metal aren't available). Binary mode supports macOS
//   (arm64+x86_64) and iOS (device + simulator) only — those are the
//   slices included in the published XCFramework.
//
// ## Dependencies
//
//   The package has one external Swift package dependency
//   (swift-argument-parser, used by the CLI). The library itself is pure
//   Swift; numeric hot paths use Apple's Accelerate framework directly.
//
// ## Conditional Compilation Flags
//
//   - `ACCELERATE_AVAILABLE` — Defined on macOS and iOS only. Guards usage
//     of Apple's Accelerate framework (vDSP, vForce) for SIMD-optimized
//     numeric operations. When absent (e.g., Linux), scalar fallbacks are
//     used.
//
// ## Unsafe Build Flags
//
//   - `-O` on the Swift library and test targets — keeps benchmarks and
//     tests representative of release performance.
//
// ============================================================================
import Foundation
import PackageDescription

// ── Build mode ──
// Set `SWIFTPANDAS_USE_BINARY=1` to consume the published XCFramework
// instead of building from source. See README → Installation.
let useBinary = ProcessInfo.processInfo.environment["SWIFTPANDAS_USE_BINARY"] == "1"

// Coordinates of the published XCFramework. Update these in lockstep with
// every tagged release: scripts/build-xcframework.sh prints the new
// checksum after building, and the asset must be uploaded to the matching
// GitHub release before consumers can resolve the binary target.
let xcframeworkURL = "https://github.com/kiraa-ai/kiraa-swift-pandas/releases/download/v0.8.0-beta/SwiftPandas.xcframework.zip"
let xcframeworkChecksum = "541944efb7a68252f77de8e1dbd477bc138da1396caef969ebf0656c2c54a14b"

// ── Source-mode targets ──
let sourceTargets: [Target] = [
    .target(
        name: "SwiftPandas",
        path: "Sources/SwiftPandas",
        exclude: [
            "Metal/Shaders/GroupByShaders.metal",
            "Metal/Shaders/MergeShaders.metal",
            "Metal/Shaders/VectorSearchShaders.metal",
        ],
        swiftSettings: [
            .define("ACCELERATE_AVAILABLE", .when(platforms: [.macOS, .iOS])),
            .unsafeFlags(["-O"]),
        ]
    ),
    .testTarget(
        name: "SwiftPandasTests",
        dependencies: ["SwiftPandas"],
        path: "Tests/SwiftPandasTests",
        resources: [.copy("SampleData")],
        swiftSettings: [
            .unsafeFlags(["-O"]),
        ]
    ),
    .testTarget(
        name: "SwiftPandasCLITests",
        dependencies: ["SwiftPandasCLI", "SwiftPandas"],
        path: "Tests/SwiftPandasCLITests",
        resources: [.copy("Fixtures")]
    ),
]

// ── Binary-mode target ──
// Single .binaryTarget pointing at the published XCFramework. SPM picks
// the right slice (macOS arm64/x86_64, iOS device, iOS simulator) based
// on the consumer's build destination.
let binaryTargets: [Target] = [
    .binaryTarget(
        name: "SwiftPandas",
        url: xcframeworkURL,
        checksum: xcframeworkChecksum
    ),
]

// ── CLI target (always built from source) ──
let cliTarget: Target = .executableTarget(
    name: "SwiftPandasCLI",
    dependencies: [
        "SwiftPandas",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ],
    path: "Sources/SwiftPandasCLI"
)

let package = Package(
    name: "SwiftPandas",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftPandas", targets: ["SwiftPandas"]),
        .executable(name: "swiftpandas", targets: ["SwiftPandasCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: useBinary ? binaryTargets + [cliTarget] : sourceTargets + [cliTarget]
)
