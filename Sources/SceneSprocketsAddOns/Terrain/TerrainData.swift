import Metal
import MetalSprockets
import SceneSprocketsAddOnsShaders
import simd

/// Everything a terrain renderer reads: heights as clipmap levels (kept filled by `streamer`) and per-point
/// properties (color, mask weights), each from its own source. Renderers never see sources or streaming.
public final class TerrainData {
    public let device: MTLDevice
    /// Owns the height clipmap and keeps it filled from the height source.
    public let streamer: TerrainStreamer
    /// Color for layers with `usesColorMap`. Flat gray until one is set.
    public internal(set) var color: PropertyField
    /// RGBA weights for layers with a `maskChannel`. All ones until one is set.
    public internal(set) var mask: PropertyField
    /// Size of level 0, and the default extent for color and mask map images. An image heightmap spans exactly this.
    public let worldSize: Float
    public let heightScale: Float

    /// - Parameters:
    ///   - worldSize: Side length of the square terrain in meters; for procedural terrain, of clipmap level 0.
    ///   - heightScale: Meters per unit of height; for images, the height of full white.
    public init(device: MTLDevice, heightSource: HeightSource = .procedural(), worldSize: Float = 16_384, heightScale: Float = 1_100) throws {
        self.device = device
        self.worldSize = worldSize
        self.heightScale = heightScale
        streamer = try TerrainStreamer(
            source: try heightSource.makeSource(device: device, worldSize: worldSize),
            baseSize: worldSize,
            heightScale: heightScale,
            device: device,
            library: try ShaderLibrary(bundle: .sceneSprocketsAddOnsShaders(), device: device)
        )
        color = try PropertyField(name: "Color", source: Self.defaultColor, device: device)
        mask = try PropertyField(name: "Mask", source: Self.defaultMask, device: device)
    }

    /// Meters below which heights are clamped after interpolation (see TerrainHeightSource.heightFloor); nil for none.
    public var heightFloor: Float? {
        streamer.source.heightFloor
    }

    /// The height clipmap, finest first.
    public var levels: [ClipLevel] {
        streamer.levels
    }

    /// The coarsest level.
    public var outerLevel: ClipLevel {
        streamer.outerLevel
    }

    /// Whether the clipmap follows the camera (unbounded source).
    public var isStreaming: Bool {
        streamer.isStreaming
    }

    /// Distance in meters from `position` to the nearest edge of the terrain; nothing exists beyond it.
    public func viewDistance(from position: SIMD3<Float>) -> Float {
        streamer.viewDistance(from: position)
    }

    /// Keeps the clipmap around `position` (see TerrainStreamer). Returns whether anything moved.
    @discardableResult
    public func stream(around position: SIMD3<Float>) throws -> Bool {
        !(try streamer.stream(around: position)).isEmpty
    }
}
