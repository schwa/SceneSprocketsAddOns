import CoreGraphics
import Metal
import MetalKit
import simd

/// Supplies one per-point terrain property, such as color or mask weights, separately from the heights. Sources are
/// bounded: they cover `extent` meters around `origin`, and lookups outside clamp to the edge. Streaming (unbounded)
/// property sources aren't supported yet.
public protocol TerrainPropertySource: AnyObject {
    /// Side length in meters of the square the source covers.
    var extent: Float { get }
    /// Center of that square in world x/z meters.
    var origin: SIMD2<Float> { get }
    /// The property as a texture covering the square, north (-z) at the top.
    func makeTexture(device: MTLDevice) throws -> MTLTexture
}

/// An image spread over a square. Color images are sampled as sRGB; data such as mask weights should not be.
public final class ImagePropertySource: TerrainPropertySource {
    public let image: CGImage
    public let extent: Float
    public let origin: SIMD2<Float>
    public let isSRGB: Bool

    public init(image: CGImage, extent: Float, origin: SIMD2<Float> = .zero, isSRGB: Bool) {
        self.image = image
        self.extent = extent
        self.origin = origin
        self.isSRGB = isSRGB
    }

    public func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let texture = try MTKTextureLoader(device: device).newTexture(cgImage: image, options: [
            .SRGB: isSRGB,
            .generateMipmaps: true,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue
        ])
        texture.label = "Property Image"
        return texture
    }
}

/// The same RGBA value everywhere.
public final class ConstantPropertySource: TerrainPropertySource {
    public let rgba: SIMD4<UInt8>

    public init(_ rgba: SIMD4<UInt8>) {
        self.rgba = rgba
    }

    // A 1x1 texture sampled with clamping gives the same value at any position.
    public var extent: Float {
        1
    }

    public var origin: SIMD2<Float> {
        .zero
    }

    public func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TerrainError.allocationFailed("Constant property")
        }
        let bytes = [rgba.x, rgba.y, rgba.z, rgba.w]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 4)
        texture.label = "Constant Property"
        return texture
    }
}

/// One property of the terrain as renderers read it: a texture and where it lies in the world.
public final class PropertyField {
    public let name: String
    public let source: TerrainPropertySource
    let texture: MTLTexture

    init(name: String, source: TerrainPropertySource, device: MTLDevice) throws {
        self.name = name
        self.source = source
        texture = try source.makeTexture(device: device)
        texture.label = name
    }

    /// (origin x, origin z, extent, 0), as the shaders' map lookups expect.
    var placement: SIMD4<Float> {
        SIMD4(source.origin.x, source.origin.y, source.extent, 0)
    }
}
