import Metal
import simd

/// One level of a terrain clipmap: a square of height data `size` meters across, centered on `origin`. Levels are
/// nested around the camera; each outer level is larger and coarser. The textures wrap: each texel holds the world
/// position that maps onto it modulo the texture size, so moving the level only rewrites the strips that came into
/// view, and shaders sample at `xz / size + 0.5` with a repeating sampler.
public final class ClipLevel {
    /// Mipmapped (height, height²) in meters; the mips average both, for the LOD variance test.
    let moments: MTLTexture
    /// R32Float copy of the moments' mip 0 height, for displacement and shading.
    let heights: MTLTexture
    /// Side length in meters.
    public internal(set) var size: Float
    /// Center in world x/z meters. A multiple of `chunkSize` while streaming.
    public internal(set) var origin: SIMD2<Float>

    init(moments: MTLTexture, heights: MTLTexture, size: Float, origin: SIMD2<Float> = .zero) {
        self.moments = moments
        self.heights = heights
        self.size = size
        self.origin = origin
    }

    /// Texels per side.
    public var resolution: Int {
        moments.width
    }

    /// Levels move in whole chunks; a level is `chunksPerSide` chunks across.
    public static let chunksPerSide = 8

    public var chunkSize: Float {
        size / Float(Self.chunksPerSide)
    }
}
