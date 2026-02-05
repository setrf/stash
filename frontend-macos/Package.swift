// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StashOverlay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "StashMacOSCore",
            targets: ["StashMacOSCore"]
        ),
        .executable(
            name: "StashMacOSApp",
            targets: ["StashMacOSAppExecutable"]
        ),
        .executable(
            name: "StashOverlay",
            targets: ["StashOverlay"]
        )
    ],
    targets: [
        .target(
            name: "StashMacOSCore",
            path: "Sources/StashMacOSApp",
        ),
        .executableTarget(
            name: "StashMacOSAppExecutable",
            dependencies: ["StashMacOSCore"],
            path: "Sources/StashMacOSAppExecutable"
        ),
        .executableTarget(
            name: "StashOverlay",
            dependencies: ["StashMacOSCore"],
            path: "Sources/StashOverlay",
            resources: [.process("Resources")]
        )
    ]
)
