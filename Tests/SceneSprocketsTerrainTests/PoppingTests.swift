import Metal
import MetalSprockets
@testable import SceneSprocketsTerrain
import SceneSprocketsTerrainShaders
import Testing

/// How much the picture jumps when the clipmap levels move, isolated from camera motion: the same view is drawn just
/// before and just after the move.
@MainActor
@Suite(.serialized)
struct PoppingTests {
    // #23: the band where level 0 fades into the outer level was tied to level 0's position, so every 2 km it jumped and
    // distant shapes changed.
    @Test func movingLevelZeroDoesNotChangeThePicture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
        let size = 200
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
        var settings = TerrainSettings()
        settings.style.material.boundaryNoiseScale = 1
        settings.style.layers = settings.style.layers.map { layer in
            var layer = layer
            layer.altitudeNoise = 0
            layer.slopeNoise = 0
            return layer
        }
        let camera = FlyCamera()
        camera.position = [0, 1_500, 0]
        camera.yaw = .pi / 2
        camera.pitch = -0.12

        func render() throws -> [UInt8] {
            let uniforms = terrain.makeUniforms(camera: camera, size: CGSize(width: size, height: size), settings: settings)
            _ = try renderer.render(try terrain.frame(uniforms: uniforms, style: settings.style))
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            colorTexture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return bytes
        }

        try terrain.stream(around: camera.position)
        for _ in 0 ..< 120 {
            _ = try render()
        }
        var detailMoves = 0
        for _ in 0 ..< 90 {
            camera.position += camera.forward * 25
            // Let the LOD settle at this position, so the two renders differ only by the move.
            for _ in 0 ..< 6 {
                _ = try render()
            }
            let before = try render()
            let again = try render()
            // Without a move, the settled view repeats exactly.
            #expect(differingPixels(before, again) == 0, "baseline at x = \(camera.position.x)")
            let farOrigin = terrain.outerLevel.origin
            guard try terrain.stream(around: camera.position), terrain.outerLevel.origin == farOrigin else {
                continue
            }
            detailMoves += 1
            let after = try render()
            let changed = differingPixels(before, after)
            #expect(changed < size * size / 200, "level 0 move \(detailMoves) at x = \(camera.position.x): \(changed) pixels changed")
        }
        #expect(detailMoves >= 1)
    }
}
