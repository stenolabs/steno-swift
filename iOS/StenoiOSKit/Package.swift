// swift-tools-version: 6.3

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "StenoiOSKit",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "StenoiOSAudio", targets: ["StenoiOSAudio"]),
    ],
    dependencies: [
        // The shared recording core, so iOS writes its tracks with the same
        // code as the Mac instead of a second implementation that drifts.
        .package(path: "../../StenoKit"),
    ],
    targets: [
        .target(
            name: "StenoiOSAudio",
            dependencies: [
                .product(name: "StenoAudioCore", package: "StenoKit"),
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "StenoiOSAudioTests",
            dependencies: ["StenoiOSAudio"],
            swiftSettings: strictConcurrencySettings
        ),
    ]
)
