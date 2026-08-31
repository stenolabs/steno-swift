// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "StenoGemmaIPC",
    platforms: [
        .macOS(.v26),
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
        .library(
            name: "StenoGemmaProcessGate",
            targets: ["StenoGemmaProcessGate"]
        ),
        .library(
            name: "StenoGemmaModelStore",
            targets: ["StenoGemmaModelStore"]
        ),
        .executable(
            name: "steno-gemma-gate-probe",
            targets: ["StenoGemmaProcessGateProbe"]
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
        .target(
            name: "StenoGemmaProcessGate",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "StenoGemmaModelStore",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "StenoGemmaProcessGateProbe",
            dependencies: ["StenoGemmaProcessGate"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "StenoGemmaIPCTests",
            dependencies: [
                "StenoGemmaIPC",
                "StenoGemmaServiceCore",
                "StenoGemmaProcessGate",
                "StenoGemmaModelStore",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
