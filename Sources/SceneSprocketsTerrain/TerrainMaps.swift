import CoreGraphics
import Metal

public extension TerrainData {
    /// Replaces the color property, used by layers with `usesColorMap`.
    func setColor(_ source: TerrainPropertySource) throws {
        color = try PropertyField(name: "Color", source: source, device: device)
    }

    /// Replaces the mask property: RGBA weights for layers with a `maskChannel`.
    func setMask(_ source: TerrainPropertySource) throws {
        mask = try PropertyField(name: "Mask", source: source, device: device)
    }

    /// Sets the color map: an image covering the `worldSize` square at the origin, north (-z) at the top, sampled as
    /// sRGB. `nil` restores the flat gray placeholder.
    func setColorMap(_ image: CGImage?) throws {
        try setColor(image.map { ImagePropertySource(image: $0, extent: worldSize, isSRGB: true) } ?? Self.defaultColor)
    }

    /// Sets the mask map: an image whose RGBA channels are per-region weights, covering the `worldSize` square at the
    /// origin, north at the top. `nil` restores all-ones.
    func setMaskMap(_ image: CGImage?) throws {
        try setMask(image.map { ImagePropertySource(image: $0, extent: worldSize, isSRGB: false) } ?? Self.defaultMask)
    }

    internal static var defaultColor: TerrainPropertySource {
        ConstantPropertySource([128, 128, 128, 255])
    }

    internal static var defaultMask: TerrainPropertySource {
        ConstantPropertySource([255, 255, 255, 255])
    }
}
