// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StashOverlay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "StashOverlay",
            targets: ["StashOverlay"]
        )
    ],
    targets: [
        .executableTarget(
            name: "StashOverlay",
            path: "Sources/StashOverlay",
            resources: [.process("Resources")]
        )
    ]
)
