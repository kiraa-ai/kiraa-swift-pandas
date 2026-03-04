// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftPandas",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "SwiftPandas", targets: ["SwiftPandas"]),
    ],
    targets: [
        // C target: skiplist data structure for windowed median
        .target(
            name: "CSkipList",
            path: "Sources/CSkipList",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        // C target: klib hash tables (khash)
        .target(
            name: "CKHash",
            path: "Sources/CKHash",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        // C target: UltraJSON core encoder/decoder
        .target(
            name: "CUltraJSON",
            path: "Sources/CUltraJSON",
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        // Primary Swift library target
        .target(
            name: "SwiftPandas",
            dependencies: ["CSkipList", "CKHash", "CUltraJSON"],
            path: "Sources/SwiftPandas",
            swiftSettings: [
                .define("ACCELERATE_AVAILABLE", .when(platforms: [.macOS, .iOS])),
            ]
        ),
        // Tests
        .testTarget(
            name: "SwiftPandasTests",
            dependencies: ["SwiftPandas"],
            path: "Tests/SwiftPandasTests",
            resources: [.copy("SampleData")]
        ),
    ]
)
