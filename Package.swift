// swift-tools-version: 6.0
import PackageDescription

// Library only. The runnable demo lives in a separate repository
// (static-stability-demo-app) that consumes this package as a remote,
// version-pinned dependency. There is deliberately no executable target here.
//
// Platforms: only the ones CI builds (macOS tests, a generic iOS Simulator build,
// and Linux tests). The library has no Apple-only imports.
let package = Package(
    name: "StaticStability",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StaticStability", targets: ["StaticStability"]),
    ],
    targets: [
        .target(name: "StaticStability"),
        .testTarget(name: "StaticStabilityTests", dependencies: ["StaticStability"]),
    ]
)
