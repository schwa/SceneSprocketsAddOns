import Foundation
import Metal
import MetalSprockets
import MetalSprocketsPBR
import SceneSprockets
import SceneSprocketsBlinnPhong
import SceneSprocketsPBR
import SceneSprocketsShaders
import simd

// Shared by surfaces that are drawn as their proxy box and found in the fragment shader (signed distance shapes,
// voxel grids). Their shaders follow one layout:
// - `vertex_main` draws the box, reading `viewFrame` (BlinnPhongFrame) and `uniforms`.
// - `fragment_main` lights with Blinn-Phong, with a `HAS_SHADOWS` function constant.
// - `fragment_pbr` lights with `PBR::shade`.

/// How a raymarched surface is lit.
package enum RaymarchSurface {
    case blinnPhong(BlinnPhongSceneMaterial)
    case pbr(PBRSceneMaterial)

    package var isTransparent: Bool {
        switch self {
        case .blinnPhong(let material):
            material.opacity < 1 || material.renderState.blendsWithBackground
        case .pbr(let material):
            material.isTransparent
        }
    }

    var renderState: MaterialRenderState {
        switch self {
        case .blinnPhong(let material):
            material.renderState
        case .pbr:
            MaterialRenderState()
        }
    }
}

package struct RaymarchShaders {
    var vertex: VertexShader
    var blinnPhong: FragmentShader
    var shadowedBlinnPhong: FragmentShader
    var pbr: FragmentShader

    package init(library: ShaderNamespace) throws {
        func fragment(shadows: Bool) throws -> FragmentShader {
            var constants = FunctionConstants()
            constants["HAS_SHADOWS"] = .bool(shadows)
            return try library.function(named: "fragment_main", type: FragmentShader.self, constants: constants)
        }
        vertex = try library.function(named: "vertex_main", type: VertexShader.self)
        blinnPhong = try fragment(shadows: false)
        shadowedBlinnPhong = try fragment(shadows: true)
        pbr = try library.function(named: "fragment_pbr", type: FragmentShader.self)
    }
}

/// One node to draw. `bind` adds the node's own parameters (`uniforms` and the like) to the box draw.
package struct RaymarchDraw {
    package var entry: SceneGraph.MeshEntry
    package var surface: RaymarchSurface
    package var bind: (AnyElement, simd_float4x4) -> AnyElement

    package init(entry: SceneGraph.MeshEntry, surface: RaymarchSurface, bind: @escaping (AnyElement, simd_float4x4) -> AnyElement) {
        self.entry = entry
        self.surface = surface
        self.bind = bind
    }
}

/// `world` with its translation made relative to `origin`, in double precision so it stays exact far from the world
/// origin.
package func raymarchModelMatrix(_ world: simd_float4x4, origin: SIMD3<Float>) -> simd_float4x4 {
    var matrix = world
    let translation = SIMD3<Double>(SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)) - SIMD3<Double>(origin)
    matrix.columns.3 = SIMD4(SIMD3<Float>(translation), 1)
    return matrix
}

package extension simd_float4x4 {
    var upperLeft: simd_float3x3 {
        simd_float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z), SIMD3(columns.1.x, columns.1.y, columns.1.z), SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }
}

/// The back faces of a 36-vertex box, so it still draws with the camera (or light) inside it.
package func raymarchBoxDraw(modelMatrix: simd_float4x4, stereoViews: StereoViews? = nil) -> AnyElement {
    let isMirrored = modelMatrix.upperLeft.determinant < 0
    return Draw { encoder in
        stereoViews?.configure(encoder)
        encoder.setCullMode(.front)
        encoder.setFrontFacing(isMirrored ? .clockwise : .counterClockwise)
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 36)
    }
    .eraseToAnyElement()
}

/// Draws raymarched nodes in the scene pass, each lit by its surface.
package struct RaymarchElement: Element {
    var draws: [RaymarchDraw]
    var shaders: () throws -> RaymarchShaders
    var context: RenderContext
    var ambientLightColor: SIMD3<Float>
    var pbr: PBRMaterialRenderer

    @MSEnvironment(\.submissionIndex)
    private var submissionIndex

    package init(draws: [RaymarchDraw], shaders: @escaping () throws -> RaymarchShaders, context: RenderContext, ambientLightColor: SIMD3<Float>, pbr: PBRMaterialRenderer) {
        self.draws = draws
        self.shaders = shaders
        self.context = context
        self.ambientLightColor = ambientLightColor
        self.pbr = pbr
    }

    package var body: some Element {
        get throws {
            let shaders = try shaders()
            let shading = BlinnPhongShading(context: context, ambientLightColor: ambientLightColor)
            let blinnPhongFragment = shading.shadow == nil ? shaders.blinnPhong : shaders.shadowedBlinnPhong
            let shadowBinding = shading.shadowBinding(submissionIndex: submissionIndex)
            let placeholder = try RaymarchPlaceholder.texture()
            let ambientOcclusion = context.ambientOcclusion ?? placeholder
            let pbrBindings = draws.contains { if case .pbr = $0.surface { true } else { false } } ? try pbr.frameBindings(context: context, submissionIndex: submissionIndex) : nil
            let stereoViews = context.stereoViews
            let isTransparent = draws.first?.entry.isTransparent ?? false
            return ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                let modelMatrix = raymarchModelMatrix(draw.entry.worldTransform, origin: shading.cameraPosition)
                let box = draw.bind(raymarchBoxDraw(modelMatrix: modelMatrix, stereoViews: stereoViews), modelMatrix)
                    .parameter("viewFrame", functionType: .vertex, value: shading.frame)
                switch draw.surface {
                case .blinnPhong(let material):
                    try RenderPipeline(label: "Raymarched Blinn-Phong", vertexShader: shaders.vertex, fragmentShader: blinnPhongFragment) {
                        Self.blinnPhong(box, material: material, entry: draw.entry, shading: shading, shadowBinding: shadowBinding, ambientOcclusion: ambientOcclusion)
                    }
                    .materialRenderState(draw.surface.renderState, isTransparent: isTransparent, writesBlendedDepth: stereoViews != nil)
                    .vertexAmplification(count: stereoViews?.count ?? 1)
                    .eraseToAnyElement()
                case .pbr(let material):
                    try RenderPipeline(label: "Raymarched PBR", vertexShader: shaders.vertex, fragmentShader: shaders.pbr) {
                        try Self.pbr(box, material: material, entry: draw.entry, bindings: pbrBindings)
                    }
                    .materialRenderState(draw.surface.renderState, isTransparent: isTransparent, writesBlendedDepth: stereoViews != nil)
                    .vertexAmplification(count: stereoViews?.count ?? 1)
                    .eraseToAnyElement()
                }
            }
        }
    }

    static func blinnPhong(_ box: some Element, material: BlinnPhongSceneMaterial, entry: SceneGraph.MeshEntry, shading: BlinnPhongShading, shadowBinding: (texture: MTLTexture, sampler: MTLSamplerState, uniforms: BlinnPhongShadowUniforms)?, ambientOcclusion: MTLTexture) -> AnyElement {
        var surface = material.uniforms
        surface.receivesShadow = entry.receivesShadow ? 1 : 0
        surface.opacity *= entry.opacity
        let element = box
            .parameter("frame", functionType: .fragment, value: shading.frame)
            .parameter("lights", functionType: .fragment, values: shading.lights)
            .parameter("material", functionType: .fragment, value: surface)
            .parameter("ambientOcclusion", texture: ambientOcclusion)
        guard let shadowBinding else {
            return element.eraseToAnyElement()
        }
        return element
            .parameter("shadowMap", texture: shadowBinding.texture)
            .parameter("shadowSampler", samplerState: shadowBinding.sampler)
            .parameter("shadow", functionType: .fragment, value: shadowBinding.uniforms)
            .eraseToAnyElement()
    }

    // `bindings` is made in `body` whenever a draw is PBR.
    static func pbr(_ box: some Element, material: PBRSceneMaterial, entry: SceneGraph.MeshEntry, bindings: PBRFrameBindings?) throws -> AnyElement {
        var bindings = try bindings.orThrow(.resourceCreationFailure("No PBR frame bindings"))
        if !entry.receivesShadow {
            bindings.shadow.enabled = 0
        }
        return bindings.apply(to: box
            .parameter("material", functionType: .fragment, value: material.raymarchUniforms(opacity: entry.opacity))
            .parameter("materialResources", functionType: .fragment, buffer: material.pbrMaterial.resourceBuffer))
            .eraseToAnyElement()
    }
}

private extension PBRSceneMaterial {
    // Factors only: the surface has a normal but no texture coordinates or tangents.
    func raymarchUniforms(opacity: Float) -> PBRMaterialUniforms {
        var uniforms = pbrMaterial.uniforms
        uniforms.hasNormals = 1
        uniforms.hasTangents = 0
        let slots: [WritableKeyPath<PBRMaterialUniforms, PBRTextureSlot>] = [
            \.baseColor, \.metallicRoughness, \.normal, \.occlusion, \.emissive, \.transmission, \.thickness, \.specular,
            \.specularColor, \.iridescence, \.iridescenceThickness, \.anisotropy, \.sheenColor, \.sheenRoughness,
            \.clearcoat, \.clearcoatRoughness, \.clearcoatNormal, \.diffuseTransmission, \.diffuseTransmissionColor
        ]
        for slot in slots {
            uniforms[keyPath: slot].enabled = 0
        }
        if opacity < 1 {
            uniforms.alphaMode = .blend
            uniforms.baseColorFactor.w *= opacity
        }
        return uniforms
    }
}

// 1x1 white: full ambient visibility when ambient occlusion is off.
private enum RaymarchPlaceholder {
    nonisolated(unsafe) private static var cached: MTLTexture?
    private static let lock = NSLock()

    static func texture() throws -> MTLTexture {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try (MTLCreateSystemDefaultDevice()?.makeTexture(descriptor: descriptor))
            .orThrow(.resourceCreationFailure("Failed to create the raymarching placeholder texture"))
        texture.label = "Raymarching Placeholder"
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        cached = texture
        return texture
    }
}
