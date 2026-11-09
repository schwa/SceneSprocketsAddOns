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
        .package(path: "../SceneSprockets"),
        .package(url: "https://github.com/schwa/GeometryLite3D", .upToNextMinor(from: "0.2.7")),
        .package(url: "https://github.com/schwa/MetalSprockets", .upToNextMinor(from: "0.2.9")),
        .package(url: "https://github.com/schwa/SwiftMesh", .upToNextMinor(from: "0.0.11")),
        .package(url: "https://github.com/schwa/MetalSprocketsAddOns", .upToNextMinor(from: "0.2.5")),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        // Optional features built on the scene graph, such as content generators, that most apps do not need.
        .target(
            name: "SceneSprocketsAddOns",
            dependencies: [
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
                .product(name: "MetalSprocketsAddOns", package: "MetalSprocketsAddOns"),
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
                .product(name: "SwiftMesh", package: "SwiftMesh"),
            ]
        ),
        .testTarget(
            name: "SceneSprocketsAddOnsTests",
            dependencies: [
                "SceneSprocketsAddOns",
                .product(name: "SceneSprockets", package: "SceneSprockets"),
                .product(name: "GeometryLite3D", package: "GeometryLite3D"),
                .product(name: "MetalSprocketsAddOnsShaders", package: "MetalSprocketsAddOns"),
                .product(name: "MetalSprockets", package: "MetalSprockets"),
            ]
        ),
    ]
)
