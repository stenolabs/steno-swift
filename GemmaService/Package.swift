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
            url: "https://github.com/ml-explore/mlx-swift.git",
            revision: "0bb916c67f4b9e5c682cbe02a42c701c93ab5021"
        ),
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm.git",
            revision: "37688d2cf7d3906e08c74479c9d9949ce6b81136",
            traits: []
        ),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            exact: "1.3.0"
        ),
    ],
    targets: [
        .target(
            name: "StenoMLXFoundationModels",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXGuidedGeneration", package: "mlx-swift-lm"),
            ],
            path: "Vendor/StenoMLXFoundationModels",
            exclude: ["README.md", "NOTICE.md", "LICENSE"],
            swiftSettings: [
                .define("FoundationModelsIntegration"),
                .define("STENO_VENDORED_ADAPTER"),
            ]
        ),
        .target(
            name: "StenoGemmaRuntime",
            dependencies: [
                .product(name: "StenoGemmaIPC", package: "ipc"),
                .product(name: "StenoGemmaModelStore", package: "ipc"),
                "StenoMLXFoundationModels",
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
            dependencies: [
                "StenoGemmaRuntime",
                .product(name: "StenoGemmaModelStore", package: "ipc"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "StenoGemmaRuntimeTests",
            dependencies: [
                "StenoGemmaRuntime",
                .product(name: "StenoGemmaModelStore", package: "ipc"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "StenoMLXFoundationModelsTests",
            dependencies: [
                "StenoMLXFoundationModels",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
