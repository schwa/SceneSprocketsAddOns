import Metal
import simd

public extension TerrainData {
    /// Terrain height in meters at a world-space x/z position, from clipmap level 0. Bilinear, like the shaders'
    /// sampler; the moments are in shared memory, so this reads only four texels. Fixed terrain clamps at its edges;
    /// streamed terrain wraps like its texture (positions outside level 0 read whatever chunk shares their texels).
    func height(at xz: SIMD2<Float>, exaggeration: Float = 1) -> Float {
        let moments = levels[0].moments
        let size = SIMD2<Int>(moments.width, moments.height)
        // Texel centers sit at (i + 0.5) / size.
        let texel = (xz / levels[0].size + 0.5) * SIMD2<Float>(size) - 0.5
        let weight = texel - floor(texel)
        let base = SIMD2<Int>(Int(floor(texel.x)), Int(floor(texel.y)))
        func sample(_ x: Int, _ y: Int) -> Float {
            let position = base &+ SIMD2(x, y)
            return read(isStreaming ? ((position % size) &+ size) % size : simd_clamp(position, .zero, size &- 1))
        }
        func read(_ position: SIMD2<Int>) -> Float {
            var value = SIMD2<Float>.zero
            moments.getBytes(&value, bytesPerRow: MemoryLayout<SIMD2<Float>>.stride, from: MTLRegionMake2D(position.x, position.y, 1, 1), mipmapLevel: 0)
            return value.x
        }
        let top = simd_mix(sample(0, 0), sample(1, 0), weight.x)
        let bottom = simd_mix(sample(0, 1), sample(1, 1), weight.x)
        let height = simd_mix(top, bottom, weight.y)
        return max(height, heightFloor ?? -.infinity) * exaggeration
    }

    /// `transform` (camera-to-world) moved up if needed so the camera stays `clearance` meters above the terrain.
    func keepingAboveGround(_ transform: simd_float4x4, clearance: Float = 2, exaggeration: Float = 1) -> simd_float4x4 {
        let position = transform.columns.3
        let minimumY = height(at: SIMD2(position.x, position.z), exaggeration: exaggeration) + clearance
        guard position.y < minimumY else {
            return transform
        }
        var result = transform
        result.columns.3.y = minimumY
        return result
    }
}
