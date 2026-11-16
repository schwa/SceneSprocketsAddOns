import CoreGraphics
import Metal
import MetalSprockets
@testable import SceneSprocketsTerrain
import SceneSprocketsTerrainShaders
import Testing

/// Renders a fixed view offscreen with a fresh terrain (so LOD history is identical) and returns BGRA bytes.
@MainActor
func renderTerrain(
    style: TerrainStyle,
    size: Int = 160,
    debugMode: TerrainDebugMode = .off,
    heightExaggeration: Float = 1,
    configure: (Terrain) throws -> Void = { _ in },
    compose: ((Terrain, TerrainUniforms, TerrainStyle) throws -> any Element)? = nil,
    placeCamera: (Terrain, FlyCamera) -> Void = { _, _ in }
) throws -> [UInt8] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
    try configure(terrain)
    let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
    color.usage = [.renderTarget, .shaderRead]
    color.storageMode = .shared
    let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
    depth.usage = .renderTarget
    depth.storageMode = .private
    let colorTexture = try #require(device.makeTexture(descriptor: color))
    let renderer = try OffscreenRenderer(
        size: CGSize(width: size, height: size),
        colorTexture: colorTexture,
        depthTexture: try #require(device.makeTexture(descriptor: depth)),
        clearDepth: 0
    )
    let camera = FlyCamera()
    camera.pitch = -0.6
    placeCamera(terrain, camera)
    var settings = TerrainSettings()
    settings.style = style
    settings.debugMode = debugMode
    settings.heightExaggeration = heightExaggeration
    for _ in 0 ..< 60 {
        let uniforms = terrain.makeUniforms(camera: camera, size: CGSize(width: size, height: size), settings: settings)
        if let compose {
            _ = try renderer.render(AnyElement(try compose(terrain, uniforms, style)))
        } else {
            _ = try renderer.render(try terrain.frame(uniforms: uniforms, style: style))
        }
    }
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    colorTexture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    return bytes
}

/// Alpine without blend-boundary noise, for tests whose expectations are easier to read without noisy boundaries.
let alpineWithoutNoise: TerrainStyle = {
    var style = TerrainStyle.alpine
    style.layers = style.layers.map { layer in
        var layer = layer
        layer.altitudeNoise = 0
        layer.slopeNoise = 0
        return layer
    }
    return style
}()

/// Renders the mini-map of a fresh terrain offscreen and returns BGRA bytes.
@MainActor
func renderMap(style: TerrainStyle, contourInterval: Float? = nil, contoursOnly: Bool = false, size: Int = 128) throws -> [UInt8] {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
    let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
    color.usage = [.renderTarget, .shaderRead]
    color.storageMode = .shared
    let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
    depth.usage = .renderTarget
    depth.storageMode = .private
    let colorTexture = try #require(device.makeTexture(descriptor: color))
    let renderer = try OffscreenRenderer(
        size: CGSize(width: size, height: size),
        colorTexture: colorTexture,
        depthTexture: try #require(device.makeTexture(descriptor: depth)),
        clearDepth: 0
    )
    _ = try renderer.render(try terrain.mapWork(style: style, contourInterval: contourInterval, contoursOnly: contoursOnly))
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    colorTexture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    return bytes
}

func redPixels(_ pixels: [UInt8]) -> Int {
    stride(from: 0, to: pixels.count, by: 4).count { index in
        Int(pixels[index + 2]) > Int(pixels[index + 1]) + 40 && Int(pixels[index + 2]) > Int(pixels[index]) + 40
    }
}

/// An RGBA image whose left half is `left` and right half is `right`.
func splitImage(left: [UInt8], right: [UInt8]) throws -> CGImage {
    var pixels: [UInt8] = []
    for _ in 0 ..< 8 {
        for x in 0 ..< 8 {
            pixels += x < 4 ? left : right
        }
    }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = pixels.withUnsafeMutableBytes { bytes in
        CGContext(
            data: bytes.baseAddress,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
    return try #require(image)
}

func differingPixels(_ lhs: [UInt8], _ rhs: [UInt8], threshold: Int = 8) -> Int {
    stride(from: 0, to: lhs.count, by: 4).count { index in
        (0 ..< 3).contains { abs(Int(lhs[index + $0]) - Int(rhs[index + $0])) > threshold }
    }
}

@Suite(.serialized)
@MainActor
struct ShadingTests {
    @Test func boundaryNoiseBreaksUpBlends() throws {
        var plain = TerrainStyle.alpine
        plain.layers = plain.layers.map { layer in
            var layer = layer
            layer.altitudeNoise = 0
            layer.slopeNoise = 0
            return layer
        }
        let without = try renderTerrain(style: plain)
        let with = try renderTerrain(style: TerrainStyle.alpine)
        // Noise moves blend boundaries, so a visible share of pixels changes color.
        #expect(differingPixels(without, with) > without.count / 4 / 50)
        // The same material gives the same image.
        #expect(differingPixels(with, try renderTerrain(style: .alpine), threshold: 0) == 0)
    }

    @Test func topLayerCoveringEverythingSetsTheColor() throws {
        var style = TerrainStyle.alpine
        style.layers.append(TerrainLayer([0.8, 0.05, 0.05]))
        let pixels = try renderTerrain(style: style)
        // BGRA. Most pixels show terrain (some show sky); terrain pixels must be red-dominant.
        #expect(redPixels(pixels) > pixels.count / 4 / 2)
    }

    @Test func layerOrderMatters() throws {
        let red = TerrainLayer([0.8, 0.05, 0.05], slope: [0.6, 0.9, 100, 100])
        let blue = TerrainLayer([0.05, 0.05, 0.8], altitude: [-0.2, 0.1, 100, 100])
        var redOnTop = TerrainStyle.alpine
        redOnTop.layers = [TerrainLayer([0.4, 0.4, 0.4]), blue, red]
        var blueOnTop = redOnTop
        blueOnTop.layers = [TerrainLayer([0.4, 0.4, 0.4]), red, blue]
        // Where both layers apply, the one painted last wins.
        #expect(differingPixels(try renderTerrain(style: redOnTop), try renderTerrain(style: blueOnTop)) > 160 * 160 / 20)
    }

    @Test(arguments: ["curvature", "valley", "aspect"])
    func shapeBandsSelectPartOfTheTerrain(feature: String) throws {
        func material(positive: Bool?) -> TerrainStyle {
            var layer = TerrainLayer([0.8, 0.05, 0.05])
            let band: SIMD4<Float> = positive == true ? [0, 0.02, 100, 100] : [-100, -100, -0.02, 0]
            if positive != nil {
                switch feature {
                case "curvature": layer.curvatureBand = band
                case "valley": layer.valleyBand = band
                default: layer.aspectBand = band
                }
            }
            var style = TerrainStyle.alpine
            style.layers.append(layer)
            return style
        }
        let everywhere = redPixels(try renderTerrain(style: material(positive: nil)))
        let high = try renderTerrain(style: material(positive: true))
        let low = try renderTerrain(style: material(positive: false))
        // Each side of the band colors only part of the terrain, and the two sides differ.
        #expect(redPixels(high) < everywhere * 9 / 10)
        #expect(redPixels(low) < everywhere * 9 / 10)
        #expect(redPixels(high) > everywhere / 20)
        #expect(redPixels(low) > everywhere / 20)
        #expect(differingPixels(high, low) > 160 * 160 / 10)
    }

    @Test func moreThanEightLayersRender() throws {
        // Eleven layers: ten invisible (opacity 0) and a red one on top that covers everything.
        var style = TerrainStyle.alpine
        style.layers = (0 ..< 10).map { _ in TerrainLayer([0, 0, 1], opacity: 0) } + [TerrainLayer([0.8, 0.05, 0.05])]
        let pixels = try renderTerrain(style: style)
        #expect(redPixels(pixels) > pixels.count / 4 / 2)
    }

    @Test func noLayersRendersWithoutCrashing() throws {
        var style = TerrainStyle.alpine
        style.layers = []
        _ = try renderTerrain(style: style)
    }

    @Test func colorMapLayerTakesItsColorFromTheImage() throws {
        var style = TerrainStyle.alpine
        style.layers.append(TerrainLayer([0, 0, 1], usesColorMap: true))
        let red = try splitImage(left: [220, 20, 20, 255], right: [220, 20, 20, 255])
        let pixels = try renderTerrain(style: style) { try $0.setColorMap(red) }
        // The layer's own color is blue; red terrain means the map was used.
        #expect(redPixels(pixels) > pixels.count / 4 / 2)
    }

    @Test func maskChannelLimitsALayerToPartOfTheTerrain() throws {
        var style = TerrainStyle.alpine
        style.layers.append(TerrainLayer([0.8, 0.05, 0.05], maskChannel: 0))
        // No mask loaded: the default mask is all ones, so the layer covers everything.
        let everywhere = redPixels(try renderTerrain(style: style))
        let mask = try splitImage(left: [255, 0, 0, 255], right: [0, 0, 0, 255])
        let masked = redPixels(try renderTerrain(style: style) { try $0.setMaskMap(mask) })
        #expect(masked < everywhere * 9 / 10)
        #expect(masked > everywhere / 20)
    }

    @Test func surfaceDetailAddsCloseUpVariation() throws {
        // A few meters above the ground, looking down: well inside the detail fade distance.
        func closeUp(_ terrain: Terrain, _ camera: FlyCamera) {
            camera.position = [100, terrain.height(at: [100, 100]) + 8, 100]
            camera.pitch = -0.9
        }
        var plain = TerrainStyle.alpine
        plain.material.detailStrength = 0
        plain.layers = plain.layers.map { layer in
            var layer = layer
            layer.colorVariation = 0
            return layer
        }
        let with = try renderTerrain(style: TerrainStyle.alpine, placeCamera: closeUp)
        let without = try renderTerrain(style: plain, placeCamera: closeUp)
        #expect(differingPixels(with, without, threshold: 4) > 160 * 160 / 4)

        // From the default view (about 900 m up), detail has faded out, so the images match.
        let farWith = try renderTerrain(style: .alpine)
        let farWithout = try renderTerrain(style: plain)
        #expect(differingPixels(farWith, farWithout) < 160 * 160 / 100)
    }

    @Test func everyDebugModeRendersSomethingDifferent() throws {
        let shaded = try renderTerrain(style: .alpine)
        for mode in TerrainDebugMode.allCases where mode != .off {
            // colorMap and maskMap show the flat placeholders, which still differ from shading.
            let pixels = try renderTerrain(style: .alpine, debugMode: mode)
            #expect(differingPixels(shaded, pixels) > 160 * 160 / 10, "\(mode.name)")
            // Magenta is the shader's fallback for an unhandled mode.
            let magenta = stride(from: 0, to: pixels.count, by: 4).count { pixels[$0 + 2] > 240 && pixels[$0 + 1] < 15 && pixels[$0] > 240 }
            #expect(magenta == 0, "\(mode.name)")
        }
    }

    @Test func heightExaggerationChangesTheTerrain() throws {
        let normal = try renderTerrain(style: .alpine)
        let exaggerated = try renderTerrain(style: .alpine, heightExaggeration: 2.5)
        #expect(differingPixels(normal, exaggerated) > 160 * 160 / 5)
    }

    @Test func collisionFollowsHeightExaggeration() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: .procedural(size: 512))
        for xz in [SIMD2<Float>(0, 0), SIMD2(1_234, -567), SIMD2(-3_000, 2_500)] {
            let height = terrain.height(at: xz)
            #expect(abs(terrain.height(at: xz, exaggeration: 3) - 3 * height) < 0.01)
        }
    }

    @Test func contourLinesDarkenTheTerrain() throws {
        let plain = try renderTerrain(style: alpineWithoutNoise)
        var style = alpineWithoutNoise
        style.material.contourInterval = 50
        style.material.contourOpacity = 1
        let contoured = try renderTerrain(style: style)
        // Lines only darken: some pixels change, and none get brighter.
        #expect(differingPixels(plain, contoured) > 160 * 160 / 50)
        let brighter = stride(from: 0, to: plain.count, by: 4).count { index in
            (0 ..< 3).contains { Int(contoured[index + $0]) > Int(plain[index + $0]) + 8 }
        }
        #expect(brighter == 0)
    }

    @Test func callersCanComposeTheTerrainWithoutTheBuiltInSky() throws {
        // A level camera, so the top of the view is sky.
        let level: (Terrain, FlyCamera) -> Void = { _, camera in
            camera.position = [0, 2_500, 0]
            camera.pitch = 0
        }
        let full = try renderTerrain(style: alpineWithoutNoise, placeCamera: level)
        let compose: (Terrain, TerrainUniforms, TerrainStyle) throws -> any Element = { terrain, uniforms, style in
            try Group {
                try terrain.updateWork(uniforms: uniforms)
                try RenderPass(label: "Caller") {
                    try terrain.terrainWork(uniforms: uniforms, style: style)
                }
            }
        }
        let composed = try renderTerrain(style: alpineWithoutNoise, compose: compose, placeCamera: level)
        let size = 160
        func row(_ pixels: [UInt8], _ y: Int) -> [UInt8] {
            Array(pixels[(y * size * 4) ..< ((y + 1) * size * 4)])
        }
        // Without the sky, the top row keeps one clear color instead of the sky gradient.
        let top = row(composed, 0)
        #expect(Set(stride(from: 0, to: top.count, by: 4).map { top[$0 ..< $0 + 4] }).count == 1)
        #expect(differingPixels(top, row(full, 0)) == size)
        // The bottom rows are terrain and match the full frame.
        let bottom = Array(composed[(size * size * 4 * 3 / 4)...])
        #expect(differingPixels(bottom, Array(full[(size * size * 4 * 3 / 4)...])) == 0)
    }

    @Test func fogCanFadeToACustomColorInsteadOfTheBuiltInSky() throws {
        var style = alpineWithoutNoise
        style.material.fogDensity = 0.01
        style.material.fogSkyBlend = 0
        style.material.fogColor = [1, 0, 0]
        let pixels = try renderTerrain(style: style)
        // Dense fog to red: the terrain is mostly red.
        #expect(redPixels(pixels) > 160 * 160 / 2)
    }

    @Test func miniMapContoursAreIndependentOfTheView() throws {
        // The style has contours off; the map turns them on by itself. A 128 px map of 16 km is 125 m per pixel, so
        // closer lines would fade out as too dense.
        let plain = try renderMap(style: alpineWithoutNoise)
        let contoured = try renderMap(style: alpineWithoutNoise, contourInterval: 250)
        #expect(differingPixels(plain, contoured) > 128 * 128 / 50)
        // And the other way round: style contours on, map contours off.
        var style = alpineWithoutNoise
        style.material.contourInterval = 50
        #expect(differingPixels(plain, try renderMap(style: style, contourInterval: 0)) == 0)
    }

    @Test func contoursOnlyMapIsLinesOnPaper() throws {
        var style = alpineWithoutNoise
        style.material.contourOpacity = 1
        let pixels = try renderMap(style: style, contourInterval: 250, contoursOnly: true)
        var paper = 0
        var ink = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let (blue, green, red) = (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
            if abs(red - 245) <= 2, abs(green - 240) <= 2, abs(blue - 224) <= 2 {
                paper += 1
            } else if red < 200 {
                ink += 1
            }
        }
        // Mostly paper, some ink, and nothing that looks like shaded terrain (green).
        #expect(paper > pixels.count / 4 / 2)
        #expect(ink > 128 * 128 / 100)
        let greenish = stride(from: 0, to: pixels.count, by: 4).count { Int(pixels[$0 + 1]) > Int(pixels[$0 + 2]) + 10 }
        #expect(greenish == 0)
    }

    @Test func propertiesCanBePlacedAnywhere() throws {
        // A red/blue split color image as the top layer's color. Moving the image's square across the view changes
        // which half the camera sees; its default placement is the worldSize square at the origin.
        var style = alpineWithoutNoise
        style.layers.append(TerrainLayer([0.5, 0.5, 0.5], usesColorMap: true))
        let image = try splitImage(left: [255, 0, 0, 255], right: [0, 0, 255, 255])
        func render(origin: SIMD2<Float>) throws -> [UInt8] {
            try renderTerrain(style: style) { terrain in
                try terrain.data.setColor(ImagePropertySource(image: image, extent: 20_000, origin: origin, isSRGB: true))
            }
        }
        // The camera looks at about x = 0, so with the split there the view shows both colors; shifted far right it
        // shows only the left (red) half.
        let centered = try render(origin: [0, 0])
        let shifted = try render(origin: [9_000, 0])
        #expect(redPixels(shifted) > redPixels(centered) + 160 * 160 / 10)
    }
}
