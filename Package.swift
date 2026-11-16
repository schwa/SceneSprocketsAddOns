// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SceneSprocketsAddOns",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "SceneSprocketsAddOns", targets: ["SceneSprocketsAddOns"]),
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/SceneSprockets", branch: "main"),
        .package(url: "https://github.com/schwa/GeometryLite3D", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/schwa/MetalSprockets", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/schwa/SwiftMesh", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/schwa/MetalSprocketsAddOns", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", .upToNextMinor(from: "0.4.1")),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // Optional features built on the scene graph, such as content generators, that most apps do not need.
        .target(
            name: "SceneSprocketsAddOns",
            dependencies: [
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                "SceneSprocketsAddOnsShaders",
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "MetalSprocketsAddOns", package: "MetalSprocketsAddOns"),
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
            ],
            // Copied, not processed, so the 16-bit terrain heightmap PNG is not recompressed.
            resources: [.copy("Terrain/Resources")]
        ),
        .target(
            name: "SceneSprocketsAddOnsShaders",
            dependencies: [
                .product(name: "MetalSprocketsShaders", package: "MetalSprockets"),
            ],
            exclude: ["Metal"],
            cSettings: [.define("METAL_COMPILER_PLUGIN_DEBUG", .when(configuration: .debug))],
            plugins: [.plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")]
        ),
        .testTarget(
            name: "SceneSprocketsAddOnsTests",
            dependencies: [
                "SceneSprocketsAddOns",
                "SceneSprocketsAddOnsShaders",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
            ]
        ),
    ]
)
