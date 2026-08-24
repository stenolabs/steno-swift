// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "StenoNemotronLiveBenchmark",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "steno-nemotron-live-bench", targets: ["StenoNemotronLiveBench"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "667181a368da13b3a9178e310414e9dcbe8f23ce"
        ),
    ],
    targets: [
        .target(name: "NemotronBenchmarkSupport"),
        .executableTarget(
            name: "StenoNemotronLiveBench",
            dependencies: [
                "NemotronBenchmarkSupport",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "NemotronBenchmarkSupportTests",
            dependencies: ["NemotronBenchmarkSupport"]
        ),
    ]
)
