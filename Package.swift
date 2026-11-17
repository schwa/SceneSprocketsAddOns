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
        .library(name: "SceneSprocketsAddOns", targets: ["SceneSprocketsAddOns", "SceneSprocketsAddOnsShaders"]),
        .library(name: "SceneSprocketsTerrain", targets: ["SceneSprocketsTerrain", "SceneSprocketsTerrainShaders"]),
        .library(name: "SceneSprocketsVoxels", targets: ["SceneSprocketsVoxels", "SceneSprocketsVoxelsShaders"]),
    ],
    dependencies: [
        .package(url: "https://github.com/schwa/SceneSprockets", branch: "main"),
        .package(url: "https://github.com/schwa/MetalSprocketsPBR", .upToNextMinor(from: "0.2.3")),
        .package(url: "https://github.com/schwa/GeometryLite3D", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/schwa/MetalSprockets", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/schwa/SwiftMesh", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/schwa/MetalSprocketsAddOns", .upToNextMinor(from: "0.3.0")),
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", .upToNextMinor(from: "0.4.1")),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // Shared by renderers that find their surface in the fragment shader (signed distance shapes, voxels).
        .target(
            name: "SceneSprocketsRaymarching",
            dependencies: [
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "SceneSprocketsBlinnPhong", package: "SceneSprockets"),
                .product(name: "SceneSprocketsPBR", package: "SceneSprockets"),
                .product(name: "SceneSprocketsShaders", package: "SceneSprockets"),
                .product(name: "MetalSprocketsPBR", package: "MetalSprocketsPBR"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
            ]
        ),
        // Optional features built on the scene graph, such as content generators, that most apps do not need.
        .target(
            name: "SceneSprocketsAddOns",
            dependencies: [
                "SceneSprocketsAddOnsShaders",
                "SceneSprocketsRaymarching",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "SceneSprocketsBlinnPhong", package: "SceneSprockets"),
                .product(name: "SceneSprocketsPBR", package: "SceneSprockets"),
                .product(name: "SceneSprocketsShaders", package: "SceneSprockets"),
                .product(name: "MetalSprocketsPBR", package: "MetalSprocketsPBR"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsAddOns", package: "MetalSprocketsAddOns"),
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
            ]
        ),
        .target(
            name: "SceneSprocketsAddOnsShaders",
            dependencies: [
                .product(name: "SceneSprocketsShaders", package: "SceneSprockets"),
                .product(name: "MetalSprocketsPBRShaders", package: "MetalSprocketsPBR"),
            ],
            exclude: ["Metal"],
            cSettings: [.define("METAL_COMPILER_PLUGIN_DEBUG", .when(configuration: .debug))],
            plugins: [.plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")]
        ),
        // Large heightfield terrain tessellated on the GPU with a concurrent binary tree.
        .target(
            name: "SceneSprocketsTerrain",
            dependencies: [
                "SceneSprocketsTerrainShaders",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsUI", package: "MetalSprockets"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
            ],
            // Copied, not processed, so the 16-bit heightmap PNG is not recompressed.
            resources: [.copy("Resources")]
        ),
        .target(
            name: "SceneSprocketsTerrainShaders",
            dependencies: [
                .product(name: "MetalSprocketsShaders", package: "MetalSprockets"),
            ],
            exclude: ["Metal"],
            cSettings: [.define("METAL_COMPILER_PLUGIN_DEBUG", .when(configuration: .debug))],
            plugins: [.plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")]
        ),
        // Voxel grids traced in the fragment shader, and a MagicaVoxel .vox loader.
        .target(
            name: "SceneSprocketsVoxels",
            dependencies: [
                "SceneSprocketsVoxelsShaders",
                "SceneSprocketsRaymarching",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "SceneSprocketsBlinnPhong", package: "SceneSprockets"),
                .product(name: "SceneSprocketsPBR", package: "SceneSprockets"),
                .product(name: "MetalSprocketsPBR", package: "MetalSprocketsPBR"),
                .product(name: "SceneSprocketsShaders", package: "SceneSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
            ]
        ),
        .target(
            name: "SceneSprocketsVoxelsShaders",
            dependencies: [
                .product(name: "SceneSprocketsShaders", package: "SceneSprockets"),
                .product(name: "MetalSprocketsPBRShaders", package: "MetalSprocketsPBR"),
            ],
            exclude: ["Metal"],
            cSettings: [.define("METAL_COMPILER_PLUGIN_DEBUG", .when(configuration: .debug))],
            plugins: [.plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")]
        ),
        .testTarget(
            name: "SceneSprocketsVoxelsTests",
            dependencies: [
                "SceneSprocketsVoxels",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "SceneSprocketsBlinnPhong", package: "SceneSprockets"),
                .product(name: "SceneSprocketsPBR", package: "SceneSprockets"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
            ]
        ),
        .testTarget(
            name: "SceneSprocketsAddOnsTests",
            dependencies: [
                "SceneSprocketsAddOns",
                "SceneSprocketsAddOnsShaders",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "SceneSprocketsBlinnPhong", package: "SceneSprockets"),
                .product(name: "SceneSprocketsPBR", package: "SceneSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
            ]
        ),
        .testTarget(
            name: "SceneSprocketsTerrainTests",
            dependencies: [
                "SceneSprocketsTerrain",
                "SceneSprocketsTerrainShaders",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
            ]
        ),
    ]
)
