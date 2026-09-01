// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "StenoGemmaIPC",
    platforms: [
        .macOS(.v27),
    ],
    products: [
        .library(
            name: "StenoGemmaIPC",
            targets: ["StenoGemmaIPC"]
        ),
        .library(
            name: "StenoGemmaServiceCore",
            targets: ["StenoGemmaServiceCore"]
        ),
    ],
    targets: [
        .target(
            name: "StenoGemmaIPC",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "StenoGemmaServiceCore",
            dependencies: ["StenoGemmaIPC"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "StenoGemmaIPCTests",
            dependencies: ["StenoGemmaIPC", "StenoGemmaServiceCore"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
