import CoreGraphics
import Metal
import MetalSprockets
import SceneSprocketsTerrainShaders
import simd

/// Convenience pairing of a `TerrainData` with a `TerrainTessellator` that draws it, forwarding the common calls of both.
/// Use the two directly to pair the data with another renderer or several.
public final class Terrain {
    public let data: TerrainData
    public let tessellator: TerrainTessellator

    /// - Parameters:
    ///   - worldSize: Side length of the square terrain in meters; for procedural terrain, of clipmap level 0.
    ///   - heightScale: Meters per unit of height; for images, the height of full white.
    public init(device: MTLDevice, heightSource: HeightSource = .procedural(), worldSize: Float = 16_384, heightScale: Float = 1_100) throws {
        data = try TerrainData(device: device, heightSource: heightSource, worldSize: worldSize, heightScale: heightScale)
        tessellator = try TerrainTessellator(data: data)
    }

    // MARK: Data

    public var worldSize: Float {
        data.worldSize
    }

    public var heightScale: Float {
        data.heightScale
    }

    public var levels: [ClipLevel] {
        data.levels
    }

    public var outerLevel: ClipLevel {
        data.outerLevel
    }

    public var isStreaming: Bool {
        data.isStreaming
    }

    public func viewDistance(from position: SIMD3<Float>) -> Float {
        data.viewDistance(from: position)
    }

    @discardableResult
    public func stream(around position: SIMD3<Float>) throws -> Bool {
        try data.stream(around: position)
    }

    public func height(at xz: SIMD2<Float>, exaggeration: Float = 1) -> Float {
        data.height(at: xz, exaggeration: exaggeration)
    }

    public func keepingAboveGround(_ transform: simd_float4x4, clearance: Float = 2, exaggeration: Float = 1) -> simd_float4x4 {
        data.keepingAboveGround(transform, clearance: clearance, exaggeration: exaggeration)
    }

    public func setColorMap(_ image: CGImage?) throws {
        try data.setColorMap(image)
    }

    public func setMaskMap(_ image: CGImage?) throws {
        try data.setMaskMap(image)
    }

    // MARK: Rendering

    public var leafCount: Int {
        tessellator.leafCount
    }

    public var visibleCount: Int {
        tessellator.visibleCount
    }

    public func makeUniforms(viewProjection: simd_float4x4, cameraPosition: SIMD3<Float>, focalLength: Float, viewportHeight: Float, settings: TerrainSettings) -> TerrainUniforms {
        tessellator.makeUniforms(viewProjection: viewProjection, cameraPosition: cameraPosition, focalLength: focalLength, viewportHeight: viewportHeight, settings: settings)
    }

    @ElementBuilder
    public func frame(uniforms: TerrainUniforms, style: TerrainStyle = .alpine) throws -> some Element {
        try tessellator.frame(uniforms: uniforms, style: style)
    }

    @ElementBuilder
    public func updateWork(uniforms: TerrainUniforms) throws -> some Element {
        try tessellator.updateWork(uniforms: uniforms)
    }

    @ElementBuilder
    public func terrainWork(uniforms: TerrainUniforms, style: TerrainStyle) throws -> some Element {
        try tessellator.terrainWork(uniforms: uniforms, style: style)
    }

    public func skyWork(uniforms: TerrainUniforms, style: TerrainStyle) throws -> some Element {
        try tessellator.skyWork(uniforms: uniforms, style: style)
    }

    @ElementBuilder
    public func mapWork(style: TerrainStyle, heightExaggeration: Float = 1, contourInterval: Float? = nil, contoursOnly: Bool = false) throws -> some Element {
        try tessellator.mapWork(style: style, heightExaggeration: heightExaggeration, contourInterval: contourInterval, contoursOnly: contoursOnly)
    }
}
