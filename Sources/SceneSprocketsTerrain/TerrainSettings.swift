import CoreGraphics
import MetalSprockets
import SceneSprocketsTerrainShaders
import simd

public struct TerrainSettings: Sendable {
    public var targetEdgePixels: Float = 7
    public var meshletSubdivision = 3
    /// Triangles whose height standard deviation is below this (meters) don't split.
    public var minHeightDeviation: Float = 2.5
    /// Multiplies terrain heights when drawing; 1 is true scale.
    public var heightExaggeration: Float = 1
    public var wireframe = false
    public var frozen = false
    /// Material settings and layers: colors, blend rules, lighting and fog.
    public var style = TerrainStyle.alpine
    /// Colors the terrain by an internal quantity instead of shading it.
    public var debugMode = TerrainDebugMode.off
    /// Layer shown by `.layerWeight`.
    public var debugLayer = 0
    /// Unit vector toward the sun.
    public var sunDirection = normalize(SIMD3<Float>(0.6, 0.45, -0.5))

    public init() {}

    /// Sets `sunDirection` from a compass azimuth (0 = -z, clockwise from above) and elevation, in degrees.
    public mutating func setSun(azimuth: Float, elevation: Float) {
        let a = azimuth * .pi / 180
        let e = elevation * .pi / 180
        sunDirection = SIMD3(sin(a) * cos(e), sin(e), -cos(a) * cos(e))
    }

    public var sunAzimuth: Float {
        atan2(sunDirection.x, -sunDirection.z) * 180 / .pi
    }

    public var sunElevation: Float {
        asin(simd_clamp(sunDirection.y, -1, 1)) * 180 / .pi
    }
}

public extension TerrainTessellator {
    /// - Parameters:
    ///   - viewProjection: Terrain space to clip space, with reversed depth.
    ///   - cameraPosition: The camera in terrain space.
    ///   - focalLength: The projection's vertical focal length, `projection[1][1]` (1 / tan(fovY / 2)).
    ///   - viewportHeight: Height of the render target in pixels.
    func makeUniforms(viewProjection: simd_float4x4, cameraPosition: SIMD3<Float>, focalLength: Float, viewportHeight: Float, settings: TerrainSettings) -> TerrainUniforms {
        let planes = Self.frustumPlanes(viewProjection)

        var uniforms = TerrainUniforms()
        uniforms.viewProjection = viewProjection
        uniforms.inverseViewProjection = viewProjection.inverse
        uniforms.frustumPlanes = (planes[0], planes[1], planes[2], planes[3])
        uniforms.cameraPosition = cameraPosition
        uniforms.sunDirection = settings.sunDirection
        uniforms.cbtSize = data.outerLevel.size
        uniforms.cbtOrigin = data.outerLevel.origin
        uniforms.detailSize = data.levels[0].size
        uniforms.detailOrigin = data.levels[0].origin
        uniforms.heightScale = data.heightScale * settings.heightExaggeration
        uniforms.heightExaggeration = settings.heightExaggeration
        uniforms.hasHeightFloor = data.heightFloor == nil ? 0 : 1
        uniforms.heightFloor = data.heightFloor ?? 0
        uniforms.targetEdgePixels = settings.targetEdgePixels
        uniforms.projectionScale = viewportHeight * 0.5 * focalLength
        uniforms.updateMode = nextUpdateMode(frozen: settings.frozen)
        uniforms.wireframe = settings.wireframe ? 1 : 0
        uniforms.debugMode = UInt32(settings.debugMode.rawValue)
        uniforms.debugLayer = UInt32(max(settings.debugLayer, 0))
        uniforms.meshletSubdivision = UInt32(settings.meshletSubdivision)
        uniforms.minHeightVariance = settings.minHeightDeviation * settings.minHeightDeviation
        return uniforms
    }

    /// The per-frame CBT update: splits or merges leaves and builds the list of visible leaves that `terrainWork`
    /// draws. Compute passes; run once per frame, before the render pass that contains `terrainWork`. After the
    /// outer clipmap level moved, extra split/merge passes run first so the tessellation catches up in this frame.
    @ElementBuilder
    func updateWork(uniforms: TerrainUniforms) throws -> some Element {
        let catchUp = takeCatchUpPasses(uniforms)
        ForEach(Array(catchUp.enumerated()), id: \.offset) { _, passUniforms in
            try self.updatePass(uniforms: passUniforms)
        }
        try updatePass(uniforms: uniforms)
    }

    /// A whole frame with the built-in sky: `updateWork`, then one render pass with `terrainWork` and `skyWork`.
    /// To add your own content or sky, compose those pieces in your own passes instead.
    @ElementBuilder
    func frame(uniforms: TerrainUniforms, style: TerrainStyle = .alpine) throws -> some Element {
        try updateWork(uniforms: uniforms)
        try RenderPass(label: "Terrain") {
            try self.terrainWork(uniforms: uniforms, style: style)
            try self.skyWork(uniforms: uniforms, style: style)
        }
    }

    /// Uniforms for catch-up passes, alternating split and merge: 48 when the outer level moved or resized since the
    /// last update, else none.
    private func takeCatchUpPasses(_ uniforms: TerrainUniforms) -> [TerrainUniforms] {
        let outer = (size: data.outerLevel.size, origin: data.outerLevel.origin)
        defer { lastOuterLevel = outer }
        guard let last = lastOuterLevel, last.size != outer.size || last.origin != outer.origin else {
            return []
        }
        return (0 ..< 48).map { index in
            var pass = uniforms
            pass.updateMode = UInt32(index & 1)
            return pass
        }
    }

    /// Left, right, bottom, top planes (Gribb–Hartmann), normalized, pointing inward.
    private static func frustumPlanes(_ matrix: simd_float4x4) -> [SIMD4<Float>] {
        let rows = matrix.transpose
        return [rows.columns.3 + rows.columns.0, rows.columns.3 - rows.columns.0, rows.columns.3 + rows.columns.1, rows.columns.3 - rows.columns.1].map { plane in
            plane / length(SIMD3(plane.x, plane.y, plane.z))
        }
    }
}
