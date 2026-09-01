// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "StenoGemmaService",
    platforms: [
        .macOS(.v27),
    ],
    products: [
        .executable(
            name: "steno-gemma-service",
            targets: ["steno-gemma-service"]
        ),
    ],
    dependencies: [
        .package(path: "IPC"),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "37688d2cf7d3906e08c74479c9d9949ce6b81136"
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "StenoGemmaRuntime",
            dependencies: [
                .product(name: "StenoGemmaIPC", package: "ipc"),
                .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "steno-gemma-service",
            dependencies: ["StenoGemmaRuntime"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "StenoGemmaRuntimeTests",
            dependencies: ["StenoGemmaRuntime"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
