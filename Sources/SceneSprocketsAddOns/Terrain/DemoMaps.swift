import CoreGraphics
import Foundation
import SceneSprocketsAddOnsShaders
import simd

/// Generated color and mask maps for trying out map-driven layers without image files.
public enum DemoMaps {
    /// A patchy, satellite-like color map: noise blends greens, ochres and browns.
    public static func colorMap(size: Int = 512) -> CGImage? {
        let palette: [SIMD3<Float>] = [[0.20, 0.32, 0.12], [0.36, 0.42, 0.18], [0.55, 0.45, 0.25], [0.42, 0.30, 0.20]]
        return image(size: size) { u, v in
            let n = fractalNoise(u * 6, v * 6)
            let index = simd_clamp(n * Float(palette.count - 1), 0, Float(palette.count - 1) - 0.001)
            let lower = Int(index)
            let color = simd_mix(palette[lower], palette[lower + 1], SIMD3(repeating: index - Float(lower)))
            return SIMD4(color * (0.85 + 0.3 * fractalNoise(u * 40, v * 40)), 1)
        }
    }

    /// RGBA weights: red is noise blobs, green a ring around the center, blue east-west bands, alpha all ones.
    public static func maskMap(size: Int = 512) -> CGImage? {
        image(size: size) { u, v in
            let blobs = simd_smoothstep(0.55, 0.65, fractalNoise(u * 5 + 17, v * 5 + 3))
            let radius = simd_length(SIMD2(u, v) - 0.5)
            let ring = 1 - simd_smoothstep(0.03, 0.06, abs(radius - 0.3))
            let bands = simd_smoothstep(0.4, 0.6, 0.5 + 0.5 * sin(v * 40))
            return SIMD4(blobs, ring, bands, 1)
        }
    }

    /// Alpine with an ochre wash from the color map on flat ground, red flowers in the red-mask blobs, a blue ring
    /// from the green mask channel, and darker bands from the blue channel.
    public static let style: TerrainStyle = {
        var style = TerrainStyle.alpine
        var layers = style.layers
        let snow = layers.removeLast()
        layers += [
            TerrainLayer([0.5, 0.5, 0.5], slope: [0.8, 0.9, 100, 100], usesColorMap: true, opacity: 0.7),
            TerrainLayer([0.75, 0.10, 0.12], slope: [0.85, 0.95, 100, 100], maskChannel: 0, opacity: 0.8),
            TerrainLayer([0.10, 0.25, 0.70], maskChannel: 1),
            TerrainLayer([0.15, 0.18, 0.10], slope: [0.7, 0.85, 100, 100], maskChannel: 2, opacity: 0.4),
            snow
        ]
        style.layers = layers
        return style
    }()

    private static func image(size: Int, pixel: (Float, Float) -> SIMD4<Float>) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let value = simd_clamp(pixel((Float(x) + 0.5) / Float(size), (Float(y) + 0.5) / Float(size)), .zero, .one)
                let index = (y * size + x) * 4
                for channel in 0 ..< 4 {
                    bytes[index + channel] = UInt8(value[channel] * 255)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Value noise summed over four octaves, in [0, 1].
    private static func fractalNoise(_ x: Float, _ y: Float) -> Float {
        var sum: Float = 0
        var amplitude: Float = 0.5
        var frequency: Float = 1
        for _ in 0 ..< 4 {
            sum += amplitude * valueNoise(x * frequency, y * frequency)
            amplitude *= 0.5
            frequency *= 2
        }
        return sum / 0.9375
    }

    private static func valueNoise(_ x: Float, _ y: Float) -> Float {
        let ix = floor(x)
        let iy = floor(y)
        var fx = x - ix
        var fy = y - iy
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        func hash(_ i: Float, _ j: Float) -> Float {
            var h = UInt32(bitPattern: Int32(truncatingIfNeeded: Int(i) &* 73_856_093 ^ Int(j) &* 19_349_663))
            h ^= h >> 13
            h = h &* 0x5BD1_E995
            h ^= h >> 15
            return Float(h) / Float(UInt32.max)
        }
        let top = simd_mix(hash(ix, iy), hash(ix + 1, iy), fx)
        let bottom = simd_mix(hash(ix, iy + 1), hash(ix + 1, iy + 1), fx)
        return simd_mix(top, bottom, fy)
    }
}
