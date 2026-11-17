import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsBlinnPhong
import SceneSprocketsPBR
import SceneSprocketsRaymarching
import SceneSprocketsVoxelsShaders
import simd
import SwiftMesh

/// The material of a voxel node: the voxels, their size, and how they are lit. A ``VoxelRenderer`` draws it.
///
/// The grid is centered on the node's origin.
public struct VoxelMaterial: SceneMaterial, SamplesShadowsInShader, AppliesAmbientOcclusionInShader {
    /// How the voxels are lit. Only the material's factors and colors are used: its textures need texture
    /// coordinates, which voxels do not have.
    public enum Surface {
        /// Lit like a Blinn-Phong mesh. Each voxel's color multiplies the material's ambient and diffuse colors.
        case blinnPhong(BlinnPhongSceneMaterial)
        /// Lit like a PBR mesh, with the environment and exposure of the renderer's ``VoxelRenderer/pbr``. Each
        /// voxel's color multiplies the material's base color.
        case pbr(PBRSceneMaterial)

        var raymarchSurface: RaymarchSurface {
            switch self {
            case .blinnPhong(let material): .blinnPhong(material)
            case .pbr(let material): .pbr(material)
            }
        }
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
        surface.raymarchSurface.isTransparent
    }

    // The node's uniforms and voxels. Grid space has one unit per voxel, with the grid from 0 to its size.
    func bind(_ box: AnyElement, nodeMatrix: simd_float4x4) -> AnyElement {
        let origin = bounds.min
        let gridToNode = simd_float4x4(SIMD4(voxelSize, 0, 0, 0), SIMD4(0, voxelSize, 0, 0), SIMD4(0, 0, voxelSize, 0), SIMD4(origin, 1))
        let modelMatrix = nodeMatrix * gridToNode
        var uniforms = VoxelUniforms()
        uniforms.modelMatrix = modelMatrix
        uniforms.inverseModelMatrix = modelMatrix.inverse
        uniforms.normalMatrix = modelMatrix.upperLeft.inverse.transpose
        uniforms.size = SIMD3<Int32>(truncatingIfNeeded: size)
        return box
            .parameter("uniforms", value: uniforms)
            .parameter("voxels", functionType: .fragment, texture: texture)
            .eraseToAnyElement()
    }
}

public extension SceneGraph.Node {
    /// Replaces the node's content with a voxel grid, centered on the node's origin.
    func setVoxels(_ grid: VoxelGrid, voxelSize: Float = 1, surface: VoxelMaterial.Surface = .blinnPhong(BlinnPhongSceneMaterial(color: [1, 1, 1])), device: MTLDevice) throws {
        setVoxels(VoxelMaterial(texture: try grid.makeTexture(device: device), voxelSize: voxelSize, surface: surface), device: device)
    }

    /// Replaces the node's content with a voxel material, centered on the node's origin. Nodes can share a material,
    /// and so its texture.
    func setVoxels(_ material: VoxelMaterial, device: MTLDevice) {
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
        content = .mesh(mesh, materials: [material])
    }
}

/// The renderer that draws every node with a ``VoxelMaterial``.
///
/// Each node draws the back faces of its grid's box, so it still draws when the camera is inside the box. Voxels write
/// their depth, so they hide and are hidden by meshes. They receive shadows, and cast them when their node's
/// `castsShadow` is set.
public struct VoxelRenderer: MaterialRenderer, ShadowCasterRenderer {
    /// The color of the ambient light for Blinn-Phong surfaces, in linear RGB. Match the Blinn-Phong renderer's so
    /// both look alike.
    public var ambientLightColor: SIMD3<Float>
    /// The environment, exposure and tone mapping for PBR surfaces. Pass the scene's PBR renderer so both look alike.
    public var pbr: PBRMaterialRenderer

    /// Creates a voxel renderer.
    public init(ambientLightColor: SIMD3<Float> = [0.15, 0.15, 0.2], pbr: PBRMaterialRenderer = PBRMaterialRenderer()) {
        self.ambientLightColor = ambientLightColor
        self.pbr = pbr
    }

    public var materialType: any SceneMaterial.Type {
        VoxelMaterial.self
    }

    public func makeElement(entries: [SceneGraph.MeshEntry], context: RenderContext) throws -> AnyElement {
        let inFrustum = meshEntriesInFrustum(entries, projectionMatrix: context.projectionMatrix, cameraMatrix: context.cameraMatrix)
        let draws = zip(entries, inFrustum).compactMap { entry, isInFrustum -> RaymarchDraw? in
            guard isInFrustum, let material = entry.material as? VoxelMaterial else {
                return nil
            }
            return RaymarchDraw(entry: entry, surface: material.surface.raymarchSurface) { box, nodeMatrix in
                material.bind(box, nodeMatrix: nodeMatrix)
            }
        }
        return RaymarchElement(draws: draws, shaders: { try VoxelShaders.shared().scene }, context: context, ambientLightColor: ambientLightColor, pbr: pbr)
            .eraseToAnyElement()
    }

    public func makeShadowCasterElement(entries: [SceneGraph.MeshEntry], context: ShadowCasterContext) throws -> AnyElement {
        let shaders = try VoxelShaders.shared()
        let draws = entries.compactMap { entry -> (entry: SceneGraph.MeshEntry, material: VoxelMaterial)? in
            (entry.material as? VoxelMaterial).map { (entry, $0) }
        }
        return try RenderPipeline(label: "Voxel Shadows", vertexShader: shaders.shadowVertex, fragmentShader: shaders.shadowFragment) {
            ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                let nodeMatrix = raymarchModelMatrix(draw.entry.worldTransform, origin: context.renderOrigin)
                draw.material.bind(raymarchBoxDraw(modelMatrix: nodeMatrix), nodeMatrix: nodeMatrix)
            }
            .parameter("lightViewProjection", value: context.viewProjection)
            .parameter("shadowMapSize", functionType: .fragment, value: Float(context.resolution))
            .parameter("inverseViewProjection", functionType: .fragment, value: context.viewProjection.inverse)
        }
        .eraseToAnyElement()
    }
}

// From Voxel.metal, loaded once.
private struct VoxelShaders {
    var scene: RaymarchShaders
    var shadowVertex: VertexShader
    var shadowFragment: FragmentShader

    nonisolated(unsafe) private static var cached: Self?
    private static let lock = NSLock()

    static func shared() throws -> Self {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let library = try ShaderLibrary(bundle: .sceneSprocketsVoxelsShaders()).namespaced("Voxel")
        let shaders = Self(
            scene: try RaymarchShaders(library: library),
            shadowVertex: try library.function(named: "shadow_vertex", type: VertexShader.self),
            shadowFragment: try library.function(named: "shadow_fragment", type: FragmentShader.self)
        )
        cached = shaders
        return shaders
    }
}
