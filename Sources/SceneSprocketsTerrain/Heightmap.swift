import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalSprockets

/// Where terrain heights come from.
public enum HeightSource {
    /// Bakes the built-in eroded fBm noise at the given resolution.
    case procedural(size: Int = 4_096, octaves: Int = 8)
    /// Uses an image's luminance, 0...1, times the terrain's height scale, minus `heightOffset` meters (so the image can
    /// hold heights below 0). 16-bit grayscale DEMs keep their precision. Drawn heights never go below `heightFloor`,
    /// which is applied after interpolation so the contour where the terrain meets the floor stays smooth.
    case image(CGImage, heightOffset: Float = 0, heightFloor: Float? = nil)
}

public extension HeightSource {
    /// Real elevation around the Golden Gate (USGS 3DEP, public domain), true scale with the default `worldSize` and
    /// `heightScale`. The image stores heights + 120 m so the bay floor is kept; the floor at 0 draws the water flat.
    /// See Resources/SanFranciscoBay.md.
    static func sanFranciscoBay() throws -> HeightSource {
        guard
            let url = Bundle.module.url(forResource: "SanFranciscoBay", withExtension: "png", subdirectory: "Resources"),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw TerrainError.allocationFailed("SanFranciscoBay.png")
        }
        return .image(image, heightOffset: 120, heightFloor: 0)
    }
}

/// Texture helpers for clipmap levels: the mipmapped (height, height²) moments, their heights copy, and noise.
enum Heightmap {
    /// Rebuilds the moments' mips and the heights copy after mip 0 changed.
    static func refresh(moments: MTLTexture, heights: MTLTexture, library: ShaderLibrary, runner: Runner) throws {
        try downsample(moments, library: library, runner: runner)
        try extract(moments: moments, into: heights, library: library)
    }

    /// Single-channel R32Float copy of the moments' mip 0 height.
    static func heights(from moments: MTLTexture, library: ShaderLibrary) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: moments.width, height: moments.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let heights = moments.device.makeTexture(descriptor: descriptor) else {
            throw TerrainError.allocationFailed("Heights")
        }
        heights.label = "Heights"
        try extract(moments: moments, into: heights, library: library)
        return heights
    }

    private static func extract(moments: MTLTexture, into heights: MTLTexture, library: ShaderLibrary) throws {
        let kernel: ComputeKernel = try library.heightmap_extract
        let level0 = try levelView(moments, 0)
        try Runner(configuration: MetalContextConfiguration(device: moments.device)).run(
            try ComputePass(label: "Extract Heights") {
                try ComputePipeline(computeKernel: kernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: moments.width, height: moments.height, depth: 1))
                }
                .parameter("moments", texture: level0)
                .parameter("heights", texture: heights)
            }
        )
    }

    /// Bakes a tileable, mipmapped 512² noise texture with `kernel`.
    private static func bakeNoise(device: MTLDevice, kernel: ComputeKernel, format: MTLPixelFormat, label: String) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 512, height: 512, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .private
        guard let noise = device.makeTexture(descriptor: descriptor) else {
            throw TerrainError.allocationFailed(label)
        }
        noise.label = label
        try Runner(configuration: MetalContextConfiguration(device: device)).run(
            try ComputePass(label: "Bake \(label)") {
                try ComputePipeline(computeKernel: kernel) {
                    try ComputeDispatch(threadsPerGrid: MTLSize(width: 512, height: 512, depth: 1))
                }
                .parameter("noise", texture: try levelView(noise, 0))
                EncoderBarrier(after: .dispatch, before: .blit)
                ComputeCommand { encoder in
                    encoder.generateMipmaps(texture: noise)
                }
                .useComputeResource(noise, usage: [.read, .write])
            }
        )
        return noise
    }

    /// Tileable value noise that shifts material blend boundaries (blend_noise_bake).
    static func blendNoise(device: MTLDevice, library: ShaderLibrary) throws -> MTLTexture {
        try bakeNoise(device: device, kernel: try library.blend_noise_bake, format: .r16Float, label: "Blend Noise")
    }

    /// Tileable noise with its derivatives for close-up surface detail (detail_noise_bake).
    static func detailNoise(device: MTLDevice, library: ShaderLibrary) throws -> MTLTexture {
        try bakeNoise(device: device, kernel: try library.detail_noise_bake, format: .rgba16Float, label: "Detail Noise")
    }

    static func makeTexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TerrainError.allocationFailed("Heightmap")
        }
        texture.label = "Heightmap"
        return texture
    }

    static func levelView(_ texture: MTLTexture, _ level: Int) throws -> MTLTexture {
        guard let view = texture.makeTextureView(pixelFormat: texture.pixelFormat, textureType: .type2D, levels: level ..< level + 1, slices: 0 ..< 1) else {
            throw TerrainError.allocationFailed("Heightmap level \(level)")
        }
        return view
    }

    private static func downsample(_ texture: MTLTexture, library: ShaderLibrary, runner: Runner) throws {
        let kernel: ComputeKernel = try library.heightmap_downsample
        let levels = try (0 ..< texture.mipmapLevelCount).map { try levelView(texture, $0) }
        try runner.run(
            try ComputePass(label: "Heightmap Mips") {
                QueueBarrier(after: .dispatch, before: .dispatch)
                try ComputePipeline(computeKernel: kernel) {
                    ForEach(Array(1 ..< levels.count), id: \.self) { level in
                        try ComputeDispatch(threadsPerGrid: MTLSize(width: levels[level].width, height: levels[level].height, depth: 1))
                            .parameter("source", texture: levels[level - 1])
                            .parameter("destination", texture: levels[level])
                        EncoderBarrier(after: .dispatch, before: .dispatch)
                    }
                }
            }
        )
    }

    static func luminance(of image: CGImage) throws -> [Float] {
        // Gray values are heights, not colors: drawing a grayscale image in its own color space keeps them as stored.
        // Converting to linear gray would apply the gamma CoreGraphics assumes for untagged gray images (about 2.2)
        // and squash heights. Color images still go through linear gray to get a luminance.
        guard let space = image.colorSpace.flatMap({ $0.model == .monochrome ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.linearGray) else {
            throw TerrainError.allocationFailed("Linear gray color space")
        }
        var pixels = [Float](repeating: 0, count: image.width * image.height)
        // CoreGraphics draws into a caller-owned buffer, so this needs the array's storage.
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 32,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else {
            throw TerrainError.allocationFailed("Heightmap image context")
        }
        return pixels
    }
}
