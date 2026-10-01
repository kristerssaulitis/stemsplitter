// swift-tools-version: 6.0
import PackageDescription

// StemSplitter — on-device stem splitter (plan: Approach B, Stem Engine).
// StemCore: contracts + engine + support. StemUI: design system + flow views.
// Spike: Day-1 benchmark harness (plan T1/TE2). No third-party dependencies (plan S3).
let package = Package(
    name: "StemSplitter",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        // Explicit library products — Xcode 27 refuses to link implicit
        // target-as-product ("Missing package product" at build-description time).
        .library(name: "StemCore", targets: ["StemCore"]),
        .library(name: "StemUI", targets: ["StemUI"]),
        // Day-1 benchmark spike CLI (plan T1/TE2): `swift run spike <corpus-dir>`.
        .executable(name: "spike", targets: ["Spike"]),
    ],
    targets: [
        .target(
            name: "StemCore",
            path: "Sources/StemCore"
        ),
        .target(
            name: "StemUI",
            dependencies: ["StemCore"],
            path: "Sources/StemUI"
        ),
        .executableTarget(
            name: "Spike",
            dependencies: ["StemCore"],
            path: "Spike/Sources"
        ),
        .testTarget(
            name: "StemCoreTests",
            dependencies: ["StemCore"],
            path: "Tests/StemCoreTests"
        ),
    ]
)
