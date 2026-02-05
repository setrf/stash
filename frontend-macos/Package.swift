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
            targets: ["StashMacOSApp"]
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
            exclude: ["StashMacOSApp.swift"]
        ),
        .executableTarget(
            name: "StashMacOSApp",
            dependencies: ["StashMacOSCore"],
            path: "Sources/StashMacOSApp",
            exclude: [
                "AppViewModel.swift",
                "BackendClient.swift",
                "FileScanner.swift",
                "Models.swift",
                "RootView.swift",
                "Theme.swift"
            ],
            sources: ["StashMacOSApp.swift"]
        ),
        .executableTarget(
            name: "StashOverlay",
            dependencies: ["StashMacOSCore"],
            path: "Sources/StashOverlay",
            resources: [.process("Resources")]
        )
    ]
)
