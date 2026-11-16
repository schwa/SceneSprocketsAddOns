import CoreGraphics
import Foundation
import SceneSprocketsAddOns
import SceneSprocketsAddOnsShaders
import simd

// Test-only camera: yaw/pitch with an infinite reversed-depth projection.
final class FlyCamera {
    init() {}

    var position = SIMD3<Float>(0, 900, 2_500)
    var yaw: Float = 0
    var pitch: Float = -0.25
    var fieldOfView: Float = .pi / 3
    var near: Float = 0.25

    var forward: SIMD3<Float> {
        SIMD3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
    }

    var right: SIMD3<Float> {
        SIMD3(cos(yaw), 0, -sin(yaw))
    }

    /// Camera-to-world transform. Setting it keeps position, yaw and pitch, and drops roll.
    var transform: simd_float4x4 {
        get {
            viewMatrix.inverse
        }
        set {
            let back = SIMD3<Float>(newValue.columns.2.x, newValue.columns.2.y, newValue.columns.2.z)
            let direction = length(back) > 0 ? -normalize(back) : SIMD3<Float>(0, 0, -1)
            yaw = atan2(-direction.x, -direction.z)
            pitch = asin(simd_clamp(direction.y, -1, 1))
            position = SIMD3(newValue.columns.3.x, newValue.columns.3.y, newValue.columns.3.z)
        }
    }

    var viewMatrix: simd_float4x4 {
        let forward = forward
        let right = normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        let rotation = simd_float4x4(rows: [
            SIMD4(right, 0),
            SIMD4(up, 0),
            SIMD4(-forward, 0),
            SIMD4(0, 0, 0, 1)
        ])
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(-position, 1)
        return rotation * translation
    }

    /// Infinite far plane, reversed depth (near maps to 1, infinity to 0).
    func projectionMatrix(aspect: Float) -> simd_float4x4 {
        let focal = 1 / tan(fieldOfView / 2)
        return simd_float4x4(columns: (
            SIMD4(focal / aspect, 0, 0, 0),
            SIMD4(0, focal, 0, 0),
            SIMD4(0, 0, 0, -1),
            SIMD4(0, 0, near, 0)
        ))
    }
}

extension Terrain {
    func makeUniforms(camera: FlyCamera, size: CGSize, settings: TerrainSettings) -> TerrainUniforms {
        let aspect = Float(max(size.width, 1) / max(size.height, 1))
        return makeUniforms(
            viewProjection: camera.projectionMatrix(aspect: aspect) * camera.viewMatrix,
            cameraPosition: camera.position,
            focalLength: 1 / tan(camera.fieldOfView / 2),
            viewportHeight: Float(size.height),
            settings: settings
        )
    }
}
