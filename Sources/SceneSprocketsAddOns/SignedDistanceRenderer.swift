import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsAddOnsShaders
import SceneSprocketsBlinnPhong
import SceneSprocketsShaders
import simd

/// The material of a signed distance node: the shape, its surface, and how to raymarch it. A
/// ``SignedDistanceRenderer`` draws it.
public struct SignedDistanceMaterial: SceneMaterial, SamplesShadowsInShader, AppliesAmbientOcclusionInShader {
    /// How the surface is lit.
    public enum Surface {
        /// Lit like a Blinn-Phong mesh. Only the material's colors are used; its textures need texture coordinates,
        /// which the shape does not have.
        case blinnPhong(BlinnPhongSceneMaterial)
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

/// The renderer that raymarches every node with a ``SignedDistanceMaterial``.
///
/// Each node draws the back faces of its bounding box, so it still draws when the camera is inside the box. Shapes
/// write their depth, so they hide and are hidden by meshes. They receive shadows but do not cast them.
public struct SignedDistanceRenderer: MaterialRenderer {
    /// The color of the ambient light, in linear RGB. Match the Blinn-Phong renderer's so both look alike.
    public var ambientLightColor: SIMD3<Float>

    /// Creates a signed distance renderer.
    public init(ambientLightColor: SIMD3<Float> = [0.15, 0.15, 0.2]) {
        self.ambientLightColor = ambientLightColor
    }

    public var materialType: any SceneMaterial.Type {
        SignedDistanceMaterial.self
    }

    // swiftlint:disable:next unneeded_throws_rethrows - the protocol requirement throws
    public func makeElement(entries: [SceneGraph.MeshEntry], context: RenderContext) throws -> AnyElement {
        let inFrustum = meshEntriesInFrustum(entries, projectionMatrix: context.projectionMatrix, cameraMatrix: context.cameraMatrix)
        let draws = zip(entries, inFrustum).compactMap { entry, isInFrustum -> (entry: SceneGraph.MeshEntry, material: SignedDistanceMaterial)? in
            guard isInFrustum, let material = entry.material as? SignedDistanceMaterial, !material.instructions.isEmpty else {
                return nil
            }
            return (entry, material)
        }
        return SignedDistanceElement(draws: draws, shading: BlinnPhongShading(context: context, ambientLightColor: ambientLightColor), ambientOcclusion: context.ambientOcclusion, isTransparent: entries.first?.isTransparent ?? false, stereoViews: context.stereoViews)
            .eraseToAnyElement()
    }
}

// An element so it can read the submission index (the shadow map has one texture per frame in flight).
private struct SignedDistanceElement: Element {
    var draws: [(entry: SceneGraph.MeshEntry, material: SignedDistanceMaterial)]
    var shading: BlinnPhongShading
    var ambientOcclusion: MTLTexture?
    var isTransparent: Bool
    var stereoViews: StereoViews?

    @MSEnvironment(\.submissionIndex)
    private var submissionIndex

    var body: some Element {
        get throws {
            let shaders = try SignedDistanceShaders.shared()
            let fragmentShader = shading.shadow == nil ? shaders.fragment : shaders.shadowedFragment
            let shadowBinding = shading.shadowBinding(submissionIndex: submissionIndex)
            let placeholder = try SignedDistanceShaders.placeholderTexture()
            let shading = shading
            let ambientOcclusion = ambientOcclusion
            let stereoViews = stereoViews
            let isTransparent = isTransparent
            return ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                try RenderPipeline(label: "Signed Distance", vertexShader: shaders.vertex, fragmentShader: fragmentShader) {
                    Self.draw(draw.entry, draw.material, shading: shading, shadowBinding: shadowBinding, ambientOcclusion: ambientOcclusion ?? placeholder, stereoViews: stereoViews)
                }
                .materialRenderState(draw.material.renderState, isTransparent: isTransparent, writesBlendedDepth: stereoViews != nil)
                .vertexAmplification(count: stereoViews?.count ?? 1)
            }
        }
    }

    static func draw(_ entry: SceneGraph.MeshEntry, _ material: SignedDistanceMaterial, shading: BlinnPhongShading, shadowBinding: (texture: MTLTexture, sampler: MTLSamplerState, uniforms: BlinnPhongShadowUniforms)?, ambientOcclusion: MTLTexture, stereoViews: StereoViews?) -> AnyElement {
        let world = entry.worldTransform
        var modelMatrix = world
        modelMatrix.columns.3 = SIMD4(SIMD3<Float>(SIMD3<Double>(world.columns.3.xyz) - SIMD3<Double>(shading.cameraPosition)), 1)
        var uniforms = SignedDistanceUniforms()
        uniforms.modelMatrix = modelMatrix
        uniforms.inverseModelMatrix = modelMatrix.inverse
        let linear = simd_float3x3(modelMatrix.columns.0.xyz, modelMatrix.columns.1.xyz, modelMatrix.columns.2.xyz)
        uniforms.normalMatrix = linear.inverse.transpose
        uniforms.boundsMin = material.bounds.min
        uniforms.boundsMax = material.bounds.max
        uniforms.instructionCount = Int32(material.instructions.count)
        uniforms.maxSteps = Int32(material.maxSteps)
        uniforms.hitThreshold = material.hitThreshold
        uniforms.stepScale = material.stepScale

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
        .parameter("instructions", functionType: .fragment, values: material.instructions)
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

// From SignedDistance.metal, loaded once.
private struct SignedDistanceShaders {
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
        let library = try ShaderLibrary(bundle: .sceneSprocketsAddOnsShaders()).namespaced("SignedDistance")
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
            .orThrow(.resourceCreationFailure("Failed to create the signed distance placeholder texture"))
        texture.label = "Signed Distance Placeholder"
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
