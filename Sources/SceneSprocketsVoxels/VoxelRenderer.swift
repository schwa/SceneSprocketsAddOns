import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsBlinnPhong
import SceneSprocketsShaders
import SceneSprocketsVoxelsShaders
import simd
import SwiftMesh

/// The material of a voxel node: the voxels, their size, and how they are lit. A ``VoxelRenderer`` draws it.
///
/// The grid is centered on the node's origin.
public struct VoxelMaterial: SceneMaterial, SamplesShadowsInShader, AppliesAmbientOcclusionInShader {
    /// How the voxels are lit.
    public enum Surface {
        /// Lit like a Blinn-Phong mesh. Each voxel's color multiplies the material's ambient and diffuse colors.
        /// Only the material's colors are used; its textures need texture coordinates, which voxels do not have.
        case blinnPhong(BlinnPhongSceneMaterial)
    }

    /// The voxels, made by ``VoxelGrid/makeTexture(device:)``.
    public let texture: MTLTexture
    /// The edge length of one voxel, in the node's units.
    public let voxelSize: Float
    /// How the voxels are lit.
    public var surface: Surface

    /// Creates a material from a texture made by ``VoxelGrid/makeTexture(device:)``.
    public init(texture: MTLTexture, voxelSize: Float, surface: Surface) {
        self.texture = texture
        self.voxelSize = voxelSize
        self.surface = surface
    }

    var size: SIMD3<Int> {
        SIMD3(texture.width, texture.height, texture.depth)
    }

    /// The node-space box around the grid.
    public var bounds: BoundingBox3D {
        let half = SIMD3<Float>(size) * voxelSize / 2
        return BoundingBox3D(min: -half, max: half)
    }

    public var isTransparent: Bool {
        switch surface {
        case .blinnPhong(let material):
            material.opacity < 1 || material.renderState.blendsWithBackground
        }
    }

    var renderState: MaterialRenderState {
        switch surface {
        case .blinnPhong(let material):
            material.renderState
        }
    }
}

public extension SceneGraph.Node {
    /// Replaces the node's content with a voxel grid, centered on the node's origin.
    func setVoxels(_ grid: VoxelGrid, voxelSize: Float = 1, surface: VoxelMaterial.Surface = .blinnPhong(BlinnPhongSceneMaterial(color: [1, 1, 1])), device: MTLDevice) throws {
        let material = VoxelMaterial(texture: try grid.makeTexture(device: device), voxelSize: voxelSize, surface: surface)
        let bounds = material.bounds
        let corners = (0..<8).map { index in
            SIMD3<Float>(
                index & 1 == 0 ? bounds.min.x : bounds.max.x,
                index & 2 == 0 ? bounds.min.y : bounds.max.y,
                index & 4 == 0 ? bounds.min.z : bounds.max.z
            )
        }
        let indices: [UInt32] = [0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6]
        // The mesh is only for bounds, culling and selection; the renderer traces the texture.
        let mesh = MetalMesh(
            device: device,
            attributes: [.positions(corners)],
            submeshes: [MetalMesh.SubmeshIndices(label: "Bounds", indices: indices, primitiveType: .triangle)],
            label: "Voxel Bounds"
        )
        content = .mesh(mesh, materials: [material], castsShadow: false)
    }
}

/// The renderer that draws every node with a ``VoxelMaterial``.
///
/// Each node draws the back faces of its grid's box, so it still draws when the camera is inside the box. Voxels write
/// their depth, so they hide and are hidden by meshes. They receive shadows but do not cast them.
public struct VoxelRenderer: MaterialRenderer {
    /// The color of the ambient light, in linear RGB. Match the Blinn-Phong renderer's so both look alike.
    public var ambientLightColor: SIMD3<Float>

    /// Creates a voxel renderer.
    public init(ambientLightColor: SIMD3<Float> = [0.15, 0.15, 0.2]) {
        self.ambientLightColor = ambientLightColor
    }

    public var materialType: any SceneMaterial.Type {
        VoxelMaterial.self
    }

    // swiftlint:disable:next unneeded_throws_rethrows - the protocol requirement throws
    public func makeElement(entries: [SceneGraph.MeshEntry], context: RenderContext) throws -> AnyElement {
        let inFrustum = meshEntriesInFrustum(entries, projectionMatrix: context.projectionMatrix, cameraMatrix: context.cameraMatrix)
        let draws = zip(entries, inFrustum).compactMap { entry, isInFrustum -> (entry: SceneGraph.MeshEntry, material: VoxelMaterial)? in
            guard isInFrustum, let material = entry.material as? VoxelMaterial else {
                return nil
            }
            return (entry, material)
        }
        return VoxelElement(draws: draws, shading: BlinnPhongShading(context: context, ambientLightColor: ambientLightColor), ambientOcclusion: context.ambientOcclusion, isTransparent: entries.first?.isTransparent ?? false, stereoViews: context.stereoViews)
            .eraseToAnyElement()
    }
}

// An element so it can read the submission index (the shadow map has one texture per frame in flight).
private struct VoxelElement: Element {
    var draws: [(entry: SceneGraph.MeshEntry, material: VoxelMaterial)]
    var shading: BlinnPhongShading
    var ambientOcclusion: MTLTexture?
    var isTransparent: Bool
    var stereoViews: StereoViews?

    @MSEnvironment(\.submissionIndex)
    private var submissionIndex

    var body: some Element {
        get throws {
            let shaders = try VoxelShaders.shared()
            let fragmentShader = shading.shadow == nil ? shaders.fragment : shaders.shadowedFragment
            let shadowBinding = shading.shadowBinding(submissionIndex: submissionIndex)
            let placeholder = try VoxelShaders.placeholderTexture()
            let shading = shading
            let ambientOcclusion = ambientOcclusion
            let stereoViews = stereoViews
            let isTransparent = isTransparent
            return ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                try RenderPipeline(label: "Voxels", vertexShader: shaders.vertex, fragmentShader: fragmentShader) {
                    Self.draw(draw.entry, draw.material, shading: shading, shadowBinding: shadowBinding, ambientOcclusion: ambientOcclusion ?? placeholder, stereoViews: stereoViews)
                }
                .materialRenderState(draw.material.renderState, isTransparent: isTransparent, writesBlendedDepth: stereoViews != nil)
                .vertexAmplification(count: stereoViews?.count ?? 1)
            }
        }
    }

    static func draw(_ entry: SceneGraph.MeshEntry, _ material: VoxelMaterial, shading: BlinnPhongShading, shadowBinding: (texture: MTLTexture, sampler: MTLSamplerState, uniforms: BlinnPhongShadowUniforms)?, ambientOcclusion: MTLTexture, stereoViews: StereoViews?) -> AnyElement {
        let world = entry.worldTransform
        var nodeMatrix = world
        nodeMatrix.columns.3 = SIMD4(SIMD3<Float>(SIMD3<Double>(world.columns.3.xyz) - SIMD3<Double>(shading.cameraPosition)), 1)
        // Grid space has one unit per voxel, with the grid from 0 to its size.
        let scale = material.voxelSize
        let origin = material.bounds.min
        let gridToNode = simd_float4x4(SIMD4(scale, 0, 0, 0), SIMD4(0, scale, 0, 0), SIMD4(0, 0, scale, 0), SIMD4(origin, 1))
        let modelMatrix = nodeMatrix * gridToNode
        var uniforms = VoxelUniforms()
        uniforms.modelMatrix = modelMatrix
        uniforms.inverseModelMatrix = modelMatrix.inverse
        let linear = simd_float3x3(modelMatrix.columns.0.xyz, modelMatrix.columns.1.xyz, modelMatrix.columns.2.xyz)
        uniforms.normalMatrix = linear.inverse.transpose
        uniforms.size = SIMD3<Int32>(truncatingIfNeeded: material.size)

        var surface: BlinnPhongMaterialUniforms
        switch material.surface {
        case .blinnPhong(let blinnPhong):
            surface = blinnPhong.uniforms
        }
        surface.receivesShadow = entry.receivesShadow ? 1 : 0
        surface.opacity *= entry.opacity

        let isMirrored = linear.determinant < 0
        var element = Draw { encoder in
            stereoViews?.configure(encoder)
            // Back faces, so the box still draws with the camera inside it.
            encoder.setCullMode(.front)
            encoder.setFrontFacing(isMirrored ? .clockwise : .counterClockwise)
            encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 36)
        }
        .parameter("frame", functionType: .vertex, value: shading.frame)
        .parameter("uniforms", functionType: .vertex, value: uniforms)
        .parameter("frame", functionType: .fragment, value: shading.frame)
        .parameter("lights", functionType: .fragment, values: shading.lights)
        .parameter("material", functionType: .fragment, value: surface)
        .parameter("uniforms", functionType: .fragment, value: uniforms)
        .parameter("voxels", texture: material.texture)
        .parameter("ambientOcclusion", texture: ambientOcclusion)
        .eraseToAnyElement()
        if let shadowBinding {
            element = element
                .parameter("shadowMap", texture: shadowBinding.texture)
                .parameter("shadowSampler", samplerState: shadowBinding.sampler)
                .parameter("shadow", functionType: .fragment, value: shadowBinding.uniforms)
                .eraseToAnyElement()
        }
        return element
    }
}

// From Voxel.metal, loaded once.
private struct VoxelShaders {
    var vertex: VertexShader
    var fragment: FragmentShader
    var shadowedFragment: FragmentShader

    nonisolated(unsafe) private static var cached: Self?
    nonisolated(unsafe) private static var cachedPlaceholder: MTLTexture?
    private static let lock = NSLock()

    static func shared() throws -> Self {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let library = try ShaderLibrary(bundle: .sceneSprocketsVoxelsShaders()).namespaced("Voxel")
        func fragment(shadows: Bool) throws -> FragmentShader {
            var constants = FunctionConstants()
            constants["HAS_SHADOWS"] = .bool(shadows)
            return try library.function(named: "fragment_main", type: FragmentShader.self, constants: constants)
        }
        let shaders = Self(
            vertex: try library.function(named: "vertex_main", type: VertexShader.self),
            fragment: try fragment(shadows: false),
            shadowedFragment: try fragment(shadows: true)
        )
        cached = shaders
        return shaders
    }

    // 1x1 white: full ambient visibility when ambient occlusion is off.
    static func placeholderTexture() throws -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPlaceholder {
            return cachedPlaceholder
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try (MTLCreateSystemDefaultDevice()?.makeTexture(descriptor: descriptor))
            .orThrow(.resourceCreationFailure("Failed to create the voxel placeholder texture"))
        texture.label = "Voxel Placeholder"
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        cachedPlaceholder = texture
        return texture
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
