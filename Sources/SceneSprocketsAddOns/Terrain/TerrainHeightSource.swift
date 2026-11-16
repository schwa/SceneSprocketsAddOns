import CoreGraphics
import Metal
import MetalSprockets

/// Supplies terrain heights. A `TerrainStreamer` asks it to fill regions of its clipmap levels; renderers only see the
/// levels, never the source.
public protocol TerrainHeightSource: AnyObject {
    /// Side length in meters of the square, centered on the origin, that a bounded source covers. nil for a source that
    /// covers the whole plane, which is streamed around the camera.
    var extent: Float? { get }
    /// Texels per side of a level: for a bounded source, its own data's size; for an unbounded one, level 0's.
    var resolution: SIMD2<Int> { get }
    /// Writes (height, height²) in meters into mip 0 of `level.moments` for `regions`. Regions are in the level's texel
    /// coordinates: texel g covers world x from g to g + 1 texels (texel size = level.size / level.resolution), and is
    /// stored at (g + resolution / 2) mod resolution. A bounded source is asked for its whole extent once.
    func fill(_ regions: [TerrainGenerator.TexelRegion], of level: ClipLevel, heightScale: Float, runner: Runner) throws
    /// Meters below which drawn and queried heights are clamped, after interpolation; nil for none. For example sea
    /// level, so a flat sea meets the land along a smooth contour of the stored (signed) heights.
    var heightFloor: Float? { get }
}

public extension TerrainHeightSource {
    var heightFloor: Float? {
        nil
    }
}

/// The built-in eroded fBm noise. Unbounded: any region of any level can be generated, and neighbours always match.
public final class ProceduralHeights: TerrainHeightSource {
    let generator: TerrainGenerator
    public let resolution: SIMD2<Int>

    public var extent: Float? {
        nil
    }

    /// - Parameter size: Texels per side of level 0; the outer level uses half.
    public init(device: MTLDevice, size: Int = 4_096, octaves: Int = 8) throws {
        generator = try TerrainGenerator(device: device, octaves: octaves)
        resolution = SIMD2(repeating: size)
    }

    public func fill(_ regions: [TerrainGenerator.TexelRegion], of level: ClipLevel, heightScale: Float, runner: Runner) throws {
        try generator.bake(regions, into: try Heightmap.levelView(level.moments, 0), worldSize: level.size, heightScale: heightScale, runner: runner)
    }
}

/// A heightmap image: luminance 0...1 times the height scale. Bounded: it covers `extent` meters around the origin.
/// 16-bit grayscale keeps its precision.
public final class ImageHeights: TerrainHeightSource {
    let image: CGImage
    public let extent: Float?
    /// Meters subtracted from luminance x height scale, so images can store heights below 0.
    public let heightOffset: Float
    public let heightFloor: Float?

    public var resolution: SIMD2<Int> {
        SIMD2(image.width, image.height)
    }

    public init(image: CGImage, extent: Float, heightOffset: Float = 0, heightFloor: Float? = nil) {
        self.image = image
        self.extent = extent
        self.heightOffset = heightOffset
        self.heightFloor = heightFloor
    }

    public func fill(_: [TerrainGenerator.TexelRegion], of level: ClipLevel, heightScale: Float, runner _: Runner) throws {
        let moments = try Heightmap.luminance(of: image).map { value -> SIMD2<Float> in
            let height = value * heightScale - heightOffset
            return SIMD2(height, height * height)
        }
        level.moments.replace(
            region: MTLRegionMake2D(0, 0, image.width, image.height),
            mipmapLevel: 0,
            withBytes: moments,
            bytesPerRow: image.width * MemoryLayout<SIMD2<Float>>.stride
        )
    }
}

extension HeightSource {
    /// The source object for this case. `worldSize` is the extent an image covers.
    func makeSource(device: MTLDevice, worldSize: Float) throws -> TerrainHeightSource {
        switch self {
        case let .procedural(size, octaves):
            try ProceduralHeights(device: device, size: size, octaves: octaves)
        case let .image(image, heightOffset, heightFloor):
            ImageHeights(image: image, extent: worldSize, heightOffset: heightOffset, heightFloor: heightFloor)
        }
    }
}
