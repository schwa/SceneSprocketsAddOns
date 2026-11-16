import MetalSprockets
import MetalSprocketsUI
import SceneSprocketsTerrainShaders
import simd
import SwiftUI

/// Holds a TerrainStyle by reference so views can carry it without SwiftUI comparing the C struct field by field.
final class StyleBox {
    let value: TerrainStyle

    init(_ value: TerrainStyle) {
        self.value = value
    }
}

/// Top-down map with an arrow at the camera's position, pointing where it looks.
public struct MiniMap: View {
    let terrain: Terrain
    let style: StyleBox
    let cameraTransform: simd_float4x4
    let heightExaggeration: Float
    let contourInterval: Float?
    let contoursOnly: Bool
    /// Side length in points.
    let size: CGFloat

    /// - Parameters:
    ///   - cameraTransform: Camera-to-world transform, for the position arrow.
    ///   - contourInterval: Meters between contour lines on the map; nil uses the style's. 0 turns them off.
    ///   - contoursOnly: Draw only contour lines, on plain paper.
    ///   - size: Side length in points.
    public init(
        terrain: Terrain,
        style: TerrainStyle,
        cameraTransform: simd_float4x4,
        heightExaggeration: Float = 1,
        contourInterval: Float? = nil,
        contoursOnly: Bool = false,
        size: CGFloat
    ) {
        self.terrain = terrain
        // The style goes in a reference box: SwiftUI compares view fields, and storing the imported C material struct
        // directly in a view crashed that comparison at launch.
        self.style = StyleBox(style)
        self.cameraTransform = cameraTransform
        self.heightExaggeration = heightExaggeration
        self.contourInterval = contourInterval
        self.contoursOnly = contoursOnly
        self.size = size
    }

    public var body: some View {
        let position = cameraTransform.columns.3
        let forward = -cameraTransform.columns.2
        // Map space: +x right, +z down. Rotation is clockwise from up.
        let heading = Angle(radians: Double(atan2(forward.x, -forward.z)))
        let level = terrain.levels[0]
        let local = (SIMD2(position.x, position.z) - level.origin) / level.size + 0.5
        let isInside = local.x >= 0 && local.x <= 1 && local.y >= 0 && local.y <= 1

        GeometryReader { geometry in
            RenderView { _, _ in
                try terrain.mapWork(style: style.value, heightExaggeration: heightExaggeration, contourInterval: contourInterval, contoursOnly: contoursOnly)
            }
            Image(systemName: "location.north.fill")
                .accessibilityLabel("Camera position")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .shadow(color: .black.opacity(0.6), radius: 1)
                .rotationEffect(heading)
                .position(
                    x: CGFloat(simd_clamp(local.x, 0, 1)) * geometry.size.width,
                    y: CGFloat(simd_clamp(local.y, 0, 1)) * geometry.size.height
                )
                .opacity(isInside ? 1 : 0.5)
        }
        .allowsHitTesting(false)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.6), lineWidth: 1))
        .shadow(radius: 4)
    }
}
