import Metal
import MetalSprockets
@testable import SceneSprocketsAddOns
import Testing

/// terrainHeight (TerrainNoise.h) in Double, as a reference free of float precision limits.
enum ReferenceTerrain {
    static func hash(_ cell: SIMD2<Int>) -> Double {
        let q = SIMD2<UInt32>(truncatingIfNeeded: cell &+ 100_000)
        var h = (q.x &* 1_597_334_677) ^ (q.y &* 3_812_015_801)
        h ^= h >> 16
        h &*= 0x7FEB_352D
        h ^= h >> 15
        h &*= 0x846C_A68B
        h ^= h >> 16
        return Double(h) / 4_294_967_295
    }

    static func noised(_ x: SIMD2<Double>) -> SIMD3<Double> {
        let i = x.rounded(.down)
        let f = x - i
        let u = f * f * f * (f * (f * 6 - 15) + 10)
        let du = 30 * f * f * (f * (f - 2) + 1)
        let cell = SIMD2<Int>(Int(i.x), Int(i.y))
        let a = hash(cell)
        let b = hash(cell &+ SIMD2(1, 0))
        let c = hash(cell &+ SIMD2(0, 1))
        let d = hash(cell &+ SIMD2(1, 1))
        let k1 = b - a
        let k2 = c - a
        let k4 = a - b - c + d
        let value = a + k1 * u.x + k2 * u.y + k4 * u.x * u.y
        let derivative = du * (SIMD2(k1, k2) + k4 * SIMD2(u.y, u.x))
        return SIMD3(-1 + 2 * value, 2 * derivative.x, 2 * derivative.y)
    }

    static func height(_ xz: SIMD2<Double>, octaves: Int, heightScale: Double) -> Double {
        var p = xz / 1_800
        var sum = 0.0
        var amplitude = 1.0
        var slope = SIMD2<Double>.zero
        for _ in 0 ..< octaves {
            let n = noised(p)
            slope += SIMD2(n.y, n.z)
            sum += amplitude * n.x / (1 + (slope * slope).sum())
            amplitude *= 0.5
            // float2x2(float2(0.8, -0.6), float2(0.6, 0.8)) * p * 2, columns first.
            p = SIMD2(0.8 * p.x + 0.6 * p.y, -0.6 * p.x + 0.8 * p.y) * 2
        }
        return sum * heightScale
    }
}

@Suite struct GenerationPrecisionTests {
    /// #29: far from the origin the generator's float lattice coordinates lost their fractional part, so terrain
    /// turned blocky. Baked heights must match the Double reference everywhere.
    @Test(arguments: [Double(0), 1_000_000, 10_000_000, 40_000_000])
    func bakedHeightsMatchTheReferenceFarFromTheOrigin(at distance: Double) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let generator = try TerrainGenerator(device: device, octaves: 8)
        let size = 64
        let texelMeters = 8.0
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let start = SIMD2(Int(distance / texelMeters), -size / 2)
        try generator.bake([.init(start: start, count: SIMD2(repeating: size))], into: texture, worldSize: Float(Double(size) * texelMeters), heightScale: 1_100, runner: try Runner(device: device))

        var values = [SIMD2<Float>](repeating: .zero, count: size * size)
        texture.getBytes(&values, bytesPerRow: size * 8, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        var worst = 0.0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let texel = start &+ SIMD2(x, y)
                let stored = ((texel &+ size / 2) % size &+ size) % size
                let baked = Double(values[stored.y * size + stored.x].x)
                let xz = (SIMD2<Double>(Double(texel.x), Double(texel.y)) + 0.5) * texelMeters
                worst = max(worst, abs(baked - ReferenceTerrain.height(xz, octaves: 8, heightScale: 1_100)))
            }
        }
        #expect(worst < 0.5, "worst height error \(worst) m at \(distance) m")
    }
}
