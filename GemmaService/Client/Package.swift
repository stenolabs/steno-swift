// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "StenoGemmaClient",
    platforms: [
        .macOS(.v27),
    ],
    products: [
        .library(
            name: "StenoGemmaClient",
            targets: ["StenoGemmaClient"]
        ),
    ],
    dependencies: [
        .package(path: "../IPC"),
    ],
    targets: [
        .target(
            name: "StenoGemmaClient",
            dependencies: [
                .product(name: "StenoGemmaIPC", package: "IPC"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "StenoGemmaClientTests",
            dependencies: [
                "StenoGemmaClient",
                .product(name: "StenoGemmaIPC", package: "IPC"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
