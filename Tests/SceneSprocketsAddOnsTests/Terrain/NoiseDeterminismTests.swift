import CoreGraphics
import Metal
import MetalSprockets
@testable import SceneSprocketsAddOns
import SceneSprocketsAddOnsShaders
import Testing

/// #13: renders with blend noise differed in a few pixels between runs.
@Suite struct NoiseDeterminismTests {
    /// Every mip of `texture`, copied to shared memory.
    func mipBytes(_ texture: MTLTexture) throws -> [[UInt8]] {
        let device = texture.device
        let queue = try #require(device.makeCommandQueue())
        let bytesPerPixel = texture.pixelFormat == .r16Float ? 2 : 8
        return try (0 ..< texture.mipmapLevelCount).map { level in
            let width = max(texture.width >> level, 1)
            let height = max(texture.height >> level, 1)
            let buffer = try #require(device.makeBuffer(length: width * height * bytesPerPixel, options: .storageModeShared))
            let commands = try #require(queue.makeCommandBuffer())
            let blit = try #require(commands.makeBlitCommandEncoder())
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: buffer, destinationOffset: 0, destinationBytesPerRow: width * bytesPerPixel, destinationBytesPerImage: width * height * bytesPerPixel
            )
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            return Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
        }
    }

    @Test func blendNoiseBakesIdentically() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try ShaderLibrary(bundle: .sceneSprocketsAddOnsShaders(), device: device)
        let reference = try mipBytes(try Heightmap.blendNoise(device: device, library: library))
        for attempt in 0 ..< 5 {
            let again = try mipBytes(try Heightmap.blendNoise(device: device, library: library))
            let differing = zip(reference, again).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
            #expect(differing.isEmpty, "attempt \(attempt): mip levels \(differing) differ")
        }
    }

    @MainActor
    @Test func sameFramesBuildTheSameTree() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        func leafBits() throws -> [UInt32] {
            let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
            let camera = FlyCamera()
            camera.pitch = -0.6
            let runner = try Runner(device: device)
            let settings = TerrainSettings()
            for _ in 0 ..< 60 {
                try runner.run(try terrain.tessellator.updateWork(uniforms: terrain.makeUniforms(camera: camera, size: CGSize(width: 160, height: 160), settings: settings)))
            }
            let words = terrain.tessellator.heap.contents().assumingMemoryBound(to: UInt32.self)
            return Array(UnsafeBufferPointer(start: words, count: terrain.tessellator.heap.length / 4))
        }
        let first = try leafBits()
        for attempt in 0 ..< 3 {
            let again = try leafBits()
            let differing = zip(first, again).filter { $0 != $1 }.count
            #expect(differing == 0, "attempt \(attempt): \(differing) heap words differ")
        }
    }

    /// With the tree frozen, only the draw order of the leaves (atomic append) can change between frames.
    @MainActor
    @Test(arguments: ["noise", "plain", "normal", "leafID"])
    func frozenTreeRendersIdenticallyEveryFrame(variant: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
        let size = 160
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
        var settings = TerrainSettings()
        if variant != "noise" {
            settings.style = alpineWithoutNoise
        }
        settings.debugMode = variant == "normal" ? .normal : variant == "leafID" ? .leafID : .off
        func render() throws -> [UInt8] {
            let uniforms = terrain.makeUniforms(camera: camera, size: CGSize(width: size, height: size), settings: settings)
            _ = try renderer.render(try terrain.frame(uniforms: uniforms, style: settings.style))
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            colorTexture.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            return bytes
        }
        for _ in 0 ..< 60 {
            _ = try render()
        }
        settings.frozen = true
        let first = try render()
        var worst = 0
        for _ in 0 ..< 20 {
            worst = max(worst, differingPixels(first, try render(), threshold: 0))
        }
        #expect(worst == 0, "\(variant): up to \(worst) pixels differ between frames of a frozen tree")
    }
}
