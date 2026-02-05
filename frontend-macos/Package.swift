// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StashOverlay",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "StashMacOSApp",
            targets: ["StashMacOSApp"]
        ),
        .executable(
            name: "StashOverlay",
            targets: ["StashOverlay"]
        )
    ],
    targets: [
        .executableTarget(
            name: "StashMacOSApp",
            path: "Sources/StashMacOSApp"
        ),
        .executableTarget(
            name: "StashOverlay",
            path: "Sources/StashOverlay",
            resources: [.process("Resources")]
        )
    ]
)
