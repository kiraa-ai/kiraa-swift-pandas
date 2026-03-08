// swift-tools-version: 5.9
// ============================================================================
// Package.swift — Swift Package Manager manifest for SwiftPandas
// ============================================================================
//
// SwiftPandas is a high-performance data manipulation library for Swift,
// inspired by Python's pandas. This manifest defines the package structure,
// platform requirements, and build configuration for the entire library.
//
// ## Package Structure
//
//   - **SwiftPandas** (Swift library target)
//     The primary library providing DataFrame, Series, GroupBy, CSV I/O, merge,
//     filter, lazy evaluation, and Metal GPU-accelerated operations.
//
//   - **CSkipList** (C language target)
//     A skip-list data structure used internally for efficient windowed median
//     calculations in rolling/window operations.
//
//   - **CKHash** (C language target)
//     Wraps klib's khash — a fast, lightweight hash table implementation used
//     to accelerate GroupBy hashing and key lookups (FNV-1a based).
//
//   - **CUltraJSON** (C language target)
//     Embeds the UltraJSON C encoder/decoder for high-throughput JSON
//     serialization and deserialization of DataFrames and Series.
//
//   - **SwiftPandasTests** (test target)
//     Unit and integration tests for the library. Bundles sample CSV/JSON data
//     under Tests/SwiftPandasTests/SampleData via a resource copy rule.
//
//   A standalone demo application is managed through the Xcode project
//   (SwiftPandas.xcodeproj) rather than as a Swift Package Manager target.
//
// ## Platform Requirements
//
//   - macOS 13+ (Ventura) — required for Accelerate/vDSP APIs and Metal shaders
//   - iOS 16+ — required for equivalent framework availability on iOS
//
// ## Dependencies
//
//   The package has no external Swift package dependencies. All native C
//   libraries (CSkipList, CKHash, CUltraJSON) are vendored directly in the
//   Sources directory and compiled as part of the build.
//
// ## Conditional Compilation Flags
//
//   - `ACCELERATE_AVAILABLE` — Defined on macOS and iOS only. Guards usage of
//     Apple's Accelerate framework (vDSP, vForce) for SIMD-optimized numeric
//     operations on Series and DataFrame columns. When this flag is absent
//     (e.g., on Linux), the library falls back to scalar implementations.
//
// ## Unsafe Build Flags
//
//   - `-O3` on all C targets: maximises compiler optimisation for the
//     performance-critical C data structures and JSON codec.
//   - `-O` on the Swift library and test targets: enables standard Swift
//     optimisation to keep benchmarks and tests representative of release
//     performance characteristics.
//
// ============================================================================
import PackageDescription

let package = Package(
    name: "SwiftPandas",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftPandas", targets: ["SwiftPandas"]),
    ],
    targets: [
        // ----------------------------------------------------------------
        // CSkipList — C implementation of a probabilistic skip-list.
        // Provides O(log n) insertion, deletion, and rank-based access,
        // used by the rolling-window engine for efficient streaming
        // median and quantile calculations over Series data.
        // ----------------------------------------------------------------
        .target(
            name: "CSkipList",
            path: "Sources/CSkipList",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-O3"]),
            ]
        ),
        // ----------------------------------------------------------------
        // CKHash — Vendored klib khash (open-addressing hash map).
        // Powers the GroupBy engine and merge/join key indexing with
        // FNV-1a hashing, delivering significantly lower overhead than
        // Swift Dictionary for large-scale categorical grouping.
        // ----------------------------------------------------------------
        .target(
            name: "CKHash",
            path: "Sources/CKHash",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-O3"]),
            ]
        ),
        // ----------------------------------------------------------------
        // CUltraJSON — Embedded UltraJSON C codec (encoder + decoder).
        // Offers high-throughput JSON serialization for DataFrame and
        // Series I/O, outperforming Foundation's JSONSerialization on
        // large tabular payloads.
        // ----------------------------------------------------------------
        .target(
            name: "CUltraJSON",
            path: "Sources/CUltraJSON",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-O3"]),
            ]
        ),
        // ----------------------------------------------------------------
        // SwiftPandas — The primary library target.
        // Contains all public API surface: DataFrame, Series, GroupBy,
        // CSV/JSON readers and writers, merge/join operations, lazy
        // evaluation engine, filter predicates, and optional Metal
        // GPU-accelerated compute kernels. Depends on the three C
        // targets above for low-level data structure performance.
        //
        // The ACCELERATE_AVAILABLE flag enables Apple Accelerate
        // (vDSP/vForce) for vectorised numeric operations on supported
        // Apple platforms. The -O flag keeps optimisation on so that
        // development builds reflect realistic performance.
        // ----------------------------------------------------------------
        .target(
            name: "SwiftPandas",
            dependencies: ["CSkipList", "CKHash", "CUltraJSON"],
            path: "Sources/SwiftPandas",
            swiftSettings: [
                .define("ACCELERATE_AVAILABLE", .when(platforms: [.macOS, .iOS])),
                .unsafeFlags(["-O"]),
            ]
        ),
        // ----------------------------------------------------------------
        // SwiftPandasTests — Unit and integration test suite.
        // Validates DataFrame, Series, GroupBy, CSV/JSON I/O, merge,
        // filter, and lazy evaluation behaviour. Sample data files
        // under Tests/SwiftPandasTests/SampleData are copied into the
        // test bundle via the resources rule below so that I/O tests
        // can run against realistic fixtures.
        // ----------------------------------------------------------------
        .testTarget(
            name: "SwiftPandasTests",
            dependencies: ["SwiftPandas"],
            path: "Tests/SwiftPandasTests",
            resources: [.copy("SampleData")],
            swiftSettings: [
                .unsafeFlags(["-O"]),
            ]
        ),
    ]
)
