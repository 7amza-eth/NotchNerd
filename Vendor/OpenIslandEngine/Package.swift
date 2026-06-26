// swift-tools-version:6.0
import PackageDescription

// Vendored engine for NotchNerd — Open Island's headless Core (detection / bridge / hook
// installer / session reducer) + the hook CLI. Pure Foundation/Darwin; ZERO external deps.
//
// Tools version is pinned to 6.0 (NOT upstream's 6.2) so boring.notch's CI Xcode 16.4 (Swift 6.0)
// can build it; Core uses no 6.2-only syntax. Two products only: the library + the hook CLI.
let package = Package(
    name: "OpenIslandEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenIslandCore", targets: ["OpenIslandCore"]),
        .executable(name: "OpenIslandHooks", targets: ["OpenIslandHooks"]),
    ],
    targets: [
        .target(name: "OpenIslandCore"),
        .executableTarget(
            name: "OpenIslandHooks",
            dependencies: ["OpenIslandCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
