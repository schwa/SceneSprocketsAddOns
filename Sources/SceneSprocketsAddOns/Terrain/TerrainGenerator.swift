import Metal
import MetalSprockets
import SceneSprocketsAddOnsShaders

/// Eroded fBm terrain baked into heightmap textures, any region at a time. Heights depend only on world position, so
/// separately baked regions join without seams.
public struct TerrainGenerator {
    /// A rectangle of the world in texel coordinates: texel x covers world x from x to x + 1 texels.
    public struct TexelRegion {
        public var start: SIMD2<Int>
        public var count: SIMD2<Int>

        public init(start: SIMD2<Int>, count: SIMD2<Int>) {
            self.start = start
            self.count = count
        }
    }

    public var octaves: Int
    private let kernel: ComputeKernel

    public init(device: MTLDevice, octaves: Int = 8) throws {
        self.octaves = octaves
        kernel = try ShaderLibrary(bundle: .sceneSprocketsAddOnsShaders(), device: device).heightmap_bake
    }

    /// Writes (height, height²) for `regions` into `texture` (an RG32Float level whose width spans `worldSize`).
    /// The texture wraps: world texel g is stored at (g + size / 2) mod size.
    public func bake(_ regions: [TexelRegion], into texture: MTLTexture, worldSize: Float, heightScale: Float, runner: Runner) throws {
        try runner.run(
            try ComputePass(label: "Bake Heightmap") {
                try ComputePipeline(computeKernel: kernel) {
                    ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                        try ComputeDispatch(threadsPerGrid: MTLSize(width: region.count.x, height: region.count.y, depth: 1))
                            .parameter("start", value: SIMD2<Int32>(truncatingIfNeeded: region.start))
                            .parameter("count", value: SIMD2<UInt32>(truncatingIfNeeded: region.count))
                            .parameter("origins", values: Self.octaveOrigins(
                                at: SIMD2<Double>(Double(region.start.x), Double(region.start.y)) * Double(worldSize) / Double(texture.width),
                                octaves: octaves
                            ))
                    }
                }
                .parameter("heightmap", texture: texture)
                .parameter("worldSize", value: worldSize)
                .parameter("heightScale", value: heightScale)
                .parameter("octaves", value: UInt32(octaves))
            }
        )
    }

    /// Per octave, the lattice position of world point `xz` split into an exact cell and a fraction, in double
    /// precision; the shader adds the small per-texel part (see terrainHeight in TerrainNoise.h). Layout matches
    /// OctaveOrigin: int2 cell, float2 fraction.
    static func octaveOrigins(at xz: SIMD2<Double>, octaves: Int) -> [OctaveOrigin] {
        var p = xz / 1_800
        return (0 ..< octaves).map { _ in
            let cell = p.rounded(.down)
            let origin = OctaveOrigin(cell: SIMD2(Int32(cell.x), Int32(cell.y)), fraction: SIMD2(Float(p.x - cell.x), Float(p.y - cell.y)))
            // float2x2(float2(0.8, -0.6), float2(0.6, 0.8)) * p * 2, as in the shader.
            p = SIMD2(0.8 * p.x + 0.6 * p.y, -0.6 * p.x + 0.8 * p.y) * 2
            return origin
        }
    }
}

/// Matches OctaveOrigin in TerrainNoise.h (which Swift can't see; it is Metal-only): int2 cell, float2 fraction.
struct OctaveOrigin {
    var cell: SIMD2<Int32>
    var fraction: SIMD2<Float>
}
