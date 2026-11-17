import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import MetalSprocketsPBR
import SceneSprockets
import SceneSprocketsAddOnsShaders
import SceneSprocketsBlinnPhong
import SceneSprocketsPBR
import SceneSprocketsRaymarching
import SceneSprocketsShaders
import simd

/// The material of a signed distance node: the shape, its surface, and how to raymarch it. A
/// ``SignedDistanceRenderer`` draws it.
public struct SignedDistanceMaterial: SceneMaterial, SamplesShadowsInShader, AppliesAmbientOcclusionInShader {
    /// How the surface is lit. Only the material's factors and colors are used: its textures need texture
    /// coordinates, which the shape does not have.
    public enum Surface {
        /// Lit like a Blinn-Phong mesh.
        case blinnPhong(BlinnPhongSceneMaterial)
        /// Lit like a PBR mesh, with the environment and exposure of the renderer's ``SignedDistanceRenderer/pbr``.
        case pbr(PBRSceneMaterial)
    }

    /// The shape. Change it with `SceneGraph.Node.setSignedDistanceShape(_:surface:device:)`, which also updates the
    /// node's bounds.
    public let shape: SignedDistanceShape
    /// How the surface is lit.
    public var surface: Surface
    /// The most steps along each ray before it counts as a miss.
    public var maxSteps = 128
    /// A ray hits when it is closer to the surface than this fraction of its length.
    public var hitThreshold: Float = 0.001
    /// The fraction of the distance to step each time. Lower it below 1 for shapes whose distances overshoot.
    public var stepScale: Float = 1

    let instructions: [SignedDistanceInstruction]
    let bounds: BoundingBox3D

    /// Creates a material. Throws if the shape nests too deeply for the shader.
    public init(shape: SignedDistanceShape, surface: Surface) throws {
        self.shape = shape
        self.surface = surface
        instructions = try shape.instructions()
        bounds = shape.bounds ?? BoundingBox3D(min: .zero, max: .zero)
    }

    public var isTransparent: Bool {
        surface.raymarchSurface.isTransparent
    }
}

extension SignedDistanceMaterial.Surface {
    var raymarchSurface: RaymarchSurface {
        switch self {
        case .blinnPhong(let material): .blinnPhong(material)
        case .pbr(let material): .pbr(material)
        }
    }
}

/// The renderer that raymarches every node with a ``SignedDistanceMaterial``.
///
/// Each node draws the back faces of its bounding box, so it still draws when the camera is inside the box. Shapes
/// write their depth, so they hide and are hidden by meshes. They receive shadows, and cast them when their node's
/// `castsShadow` is set.
public struct SignedDistanceRenderer: MaterialRenderer, ShadowCasterRenderer {
    /// The color of the ambient light for Blinn-Phong surfaces, in linear RGB. Match the Blinn-Phong renderer's so
    /// both look alike.
    public var ambientLightColor: SIMD3<Float>
    /// The environment, exposure and tone mapping for PBR surfaces. Pass the scene's PBR renderer so both look alike.
    public var pbr: PBRMaterialRenderer

    /// Creates a signed distance renderer.
    public init(ambientLightColor: SIMD3<Float> = [0.15, 0.15, 0.2], pbr: PBRMaterialRenderer = PBRMaterialRenderer()) {
        self.ambientLightColor = ambientLightColor
        self.pbr = pbr
    }

    public var materialType: any SceneMaterial.Type {
        SignedDistanceMaterial.self
    }

    public func makeElement(entries: [SceneGraph.MeshEntry], context: RenderContext) throws -> AnyElement {
        let inFrustum = meshEntriesInFrustum(entries, projectionMatrix: context.projectionMatrix, cameraMatrix: context.cameraMatrix)
        let draws = zip(entries, inFrustum).compactMap { entry, isInFrustum -> RaymarchDraw? in
            guard isInFrustum, let material = entry.material as? SignedDistanceMaterial, !material.instructions.isEmpty else {
                return nil
            }
            return RaymarchDraw(entry: entry, surface: material.surface.raymarchSurface) { box, modelMatrix in
                material.bind(box, modelMatrix: modelMatrix)
            }
        }
        return RaymarchElement(draws: draws, shaders: { try SignedDistanceShaders.shared().scene }, context: context, ambientLightColor: ambientLightColor, pbr: pbr)
            .eraseToAnyElement()
    }

    public func makeShadowCasterElement(entries: [SceneGraph.MeshEntry], context: ShadowCasterContext) throws -> AnyElement {
        let shaders = try SignedDistanceShaders.shared()
        let draws = entries.compactMap { entry -> (entry: SceneGraph.MeshEntry, material: SignedDistanceMaterial)? in
            guard let material = entry.material as? SignedDistanceMaterial, !material.instructions.isEmpty else {
                return nil
            }
            return (entry, material)
        }
        return try RenderPipeline(label: "Signed Distance Shadows", vertexShader: shaders.shadowVertex, fragmentShader: shaders.shadowFragment) {
            ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                let modelMatrix = raymarchModelMatrix(draw.entry.worldTransform, origin: context.renderOrigin)
                draw.material.bind(raymarchBoxDraw(modelMatrix: modelMatrix), modelMatrix: modelMatrix)
            }
            .parameter("lightViewProjection", value: context.viewProjection)
            .parameter("shadowMapSize", functionType: .fragment, value: Float(context.resolution))
            .parameter("inverseViewProjection", functionType: .fragment, value: context.viewProjection.inverse)
        }
        .eraseToAnyElement()
    }
}

private extension SignedDistanceMaterial {
    // The per-node uniforms and program.
    func bind(_ box: AnyElement, modelMatrix: simd_float4x4) -> AnyElement {
        var uniforms = SignedDistanceUniforms()
        uniforms.modelMatrix = modelMatrix
        uniforms.inverseModelMatrix = modelMatrix.inverse
        uniforms.normalMatrix = modelMatrix.upperLeft.inverse.transpose
        uniforms.boundsMin = bounds.min
        uniforms.boundsMax = bounds.max
        uniforms.instructionCount = Int32(instructions.count)
        uniforms.maxSteps = Int32(maxSteps)
        uniforms.hitThreshold = hitThreshold
        uniforms.stepScale = stepScale
        return box
            .parameter("uniforms", value: uniforms)
            .parameter("instructions", functionType: .fragment, values: instructions)
            .eraseToAnyElement()
    }
}

// From SignedDistance.metal, loaded once.
private struct SignedDistanceShaders {
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
        let library = try ShaderLibrary(bundle: .sceneSprocketsAddOnsShaders()).namespaced("SignedDistance")
        let shaders = Self(
            scene: try RaymarchShaders(library: library),
            shadowVertex: try library.function(named: "shadow_vertex", type: VertexShader.self),
            shadowFragment: try library.function(named: "shadow_fragment", type: FragmentShader.self)
        )
        cached = shaders
        return shaders
    }
}
