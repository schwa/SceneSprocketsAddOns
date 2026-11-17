import Metal
import MetalSprockets
import simd

/// A box of colored voxels. ``VoxelMaterial`` draws it.
public struct VoxelGrid: Sendable, Equatable {
    /// The number of voxels along each axis.
    public let size: SIMD3<Int>
    /// The color of each voxel in sRGB, x fastest then y then z. Alpha 0 is empty; any other alpha is solid.
    public private(set) var colors: [SIMD4<UInt8>]

    /// Creates an empty grid.
    public init(size: SIMD3<Int>) {
        precondition(all(size .> 0), "Voxel grids need at least one voxel on each axis")
        self.size = size
        colors = Array(repeating: .zero, count: size.x * size.y * size.z)
    }

    /// The color of the voxel at `position`; alpha 0 is empty.
    public subscript(position: SIMD3<Int>) -> SIMD4<UInt8> {
        get {
            colors[index(position)]
        }
        set {
            colors[index(position)] = newValue
        }
    }

    /// The number of filled voxels.
    public var filledCount: Int {
        colors.count { $0.w != 0 }
    }

    private func index(_ position: SIMD3<Int>) -> Int {
        precondition(all(position .>= 0) && all(position .< size), "Voxel position \(position) is outside the grid \(size)")
        return position.x + size.x * (position.y + size.y * position.z)
    }

    /// A 3D texture of the grid. Its format is sRGB, so shaders read linear colors.
    public func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm_srgb
        descriptor.width = size.x
        descriptor.height = size.y
        descriptor.depth = size.z
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try device.makeTexture(descriptor: descriptor).orThrow(.resourceCreationFailure("Failed to create the voxel texture"))
        texture.label = "Voxels"
        colors.withUnsafeBytes { bytes in
            // swiftlint:disable:next force_unwrapping - the grid is never empty
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size.x, size.y, size.z), mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: size.x * 4, bytesPerImage: size.x * size.y * 4)
        }
        return texture
    }
}
