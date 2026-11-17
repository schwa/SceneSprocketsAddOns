import Foundation
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsBlinnPhong
import SceneSprocketsShaders
import SceneSprocketsToonShaders
import simd
import SwiftMesh

/// A cel-shaded material: flat bands of light between a shade color and the full color, a hard highlight, a rim light,
/// and an outline. A ``ToonRenderer`` draws it.
///
/// The mesh needs normals. The outline pushes the mesh's back faces out along their normals, so meshes with split
/// normals at hard edges (such as boxes) show gaps at the corners; smooth meshes outline cleanly.
public struct ToonMaterial: SceneMaterial, SamplesShadowsInShader {
    /// The lit color, in linear RGB.
    public var color: SIMD3<Float>
    /// Multiplies ``color`` where no light reaches, including in shadow.
    public var shadeColor: SIMD3<Float>
    /// The number of lit steps between shade and full color. 1 is two-tone.
    public var bands: Int
    /// The width of the soft edge between bands, as a fraction of a band. 0 is a hard edge.
    public var bandSoftness: Float
    /// The color of the highlight, in linear RGB; black turns it off.
    public var highlightColor: SIMD3<Float>
    /// The highlight's size, from 0 (none) to 1 (large).
    public var highlightSize: Float
    /// The color of the light along the silhouette, in linear RGB; black turns it off.
    public var rimColor: SIMD3<Float>
    /// The rim light's width, from 0 (none) to 1 (the whole surface).
    public var rimWidth: Float
    /// The outline color, in linear RGB with alpha.
    public var outlineColor: SIMD4<Float>
    /// The outline width in pixels. 0 draws no outline.
    public var outlineWidth: Float

    /// Creates a toon material.
    public init(color: SIMD3<Float>, shadeColor: SIMD3<Float> = [0.45, 0.45, 0.55], bands: Int = 2, bandSoftness: Float = 0.05, highlightColor: SIMD3<Float> = [1, 1, 1], highlightSize: Float = 0.1, rimColor: SIMD3<Float> = .zero, rimWidth: Float = 0.25, outlineColor: SIMD4<Float> = [0, 0, 0, 1], outlineWidth: Float = 2) {
        self.color = color
        self.shadeColor = shadeColor
        self.bands = bands
        self.bandSoftness = bandSoftness
        self.highlightColor = highlightColor
        self.highlightSize = highlightSize
        self.rimColor = rimColor
        self.rimWidth = rimWidth
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
    }

    func uniforms(receivesShadow: Bool) -> ToonMaterialUniforms {
        var uniforms = ToonMaterialUniforms()
        uniforms.receivesShadow = receivesShadow ? 1 : 0
        uniforms.color = color
        uniforms.shadeColor = shadeColor
        uniforms.bands = Int32(max(bands, 1))
        uniforms.bandSoftness = max(bandSoftness, 0)
        uniforms.highlightColor = highlightColor
        // N·H above 1 - size² / 4: a size of 0 never passes.
        uniforms.highlightThreshold = highlightSize > 0 ? 1 - min(highlightSize, 1) * min(highlightSize, 1) / 4 : 1
        uniforms.rimColor = rimColor
        uniforms.rimThreshold = rimWidth > 0 ? 1 - min(rimWidth, 1) : 1
        uniforms.opacity = 1
        return uniforms
    }
}

/// The renderer that draws every mesh with a ``ToonMaterial``, then its outline.
///
/// Meshes cast and receive shadows like Blinn-Phong meshes. Skinned and morphed meshes are drawn at rest.
public struct ToonRenderer: MaterialRenderer {
    /// Creates a toon renderer.
    public init() {
        // This line intentionally left blank.
    }

    public var materialType: any SceneMaterial.Type {
        ToonMaterial.self
    }

    // swiftlint:disable:next unneeded_throws_rethrows - the protocol requirement throws
    public func makeElement(entries: [SceneGraph.MeshEntry], context: RenderContext) throws -> AnyElement {
        let inFrustum = meshEntriesInFrustum(entries, projectionMatrix: context.projectionMatrix, cameraMatrix: context.cameraMatrix)
        let draws = zip(entries, inFrustum).compactMap { entry, isInFrustum -> (entry: SceneGraph.MeshEntry, material: ToonMaterial)? in
            guard isInFrustum, let material = entry.material as? ToonMaterial else {
                return nil
            }
            return (entry, material)
        }
        return ToonElement(draws: draws, shading: BlinnPhongShading(context: context, ambientLightColor: .zero), stereoViews: context.stereoViews)
            .eraseToAnyElement()
    }
}

// An element so it can read the submission index (for the shadow map) and the render target size (for the outline).
private struct ToonElement: Element {
    var draws: [(entry: SceneGraph.MeshEntry, material: ToonMaterial)]
    var shading: BlinnPhongShading
    var stereoViews: StereoViews?

    @MSEnvironment(\.submissionIndex)
    private var submissionIndex

    @MSEnvironment(\.renderPassDescriptor)
    private var renderPassDescriptor

    var body: some Element {
        get throws {
            let shaders = try ToonShaders.shared()
            let fragmentShader = shading.shadow == nil ? shaders.fragment : shaders.shadowedFragment
            let shadowBinding = shading.shadowBinding(submissionIndex: submissionIndex)
            let target = renderPassDescriptor?.colorAttachments[0].texture
            let viewportSize = SIMD2<Float>(Float(target?.width ?? 1), Float(target?.height ?? 1))
            let shading = shading
            let stereoViews = stereoViews
            let viewCount = stereoViews?.count ?? 1
            return ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
                let mesh = draw.entry.mesh
                let submesh = mesh.submeshes[draw.entry.submeshIndex]
                let world = draw.entry.worldTransform
                let translation = SIMD3<Double>(SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)) - SIMD3<Double>(shading.cameraPosition)
                let modelMatrix = simd_float4x4(world.columns.0, world.columns.1, world.columns.2, SIMD4(SIMD3<Float>(translation), 1))
                let linear = simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z), SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z), SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
                let normalMatrix = linear.inverse.transpose
                let isMirrored = linear.determinant < 0
                let uniforms = draw.material.uniforms(receivesShadow: draw.entry.receivesShadow)
                let descriptor = mesh.vertexDescriptor.mtlVertexDescriptor

                try RenderPipeline(label: "Toon", vertexShader: shaders.vertex, fragmentShader: fragmentShader) {
                    Self.bindShadows(
                        materialDraw(submesh, cullMode: .back, isMirrored: isMirrored, stereoViews: stereoViews)
                            .vertexBuffers(mesh.vertexBuffers)
                            .parameter("frame", value: shading.frame)
                            .parameter("modelMatrix", functionType: .vertex, value: modelMatrix)
                            .parameter("normalMatrix", functionType: .vertex, value: normalMatrix)
                            .parameter("lights", functionType: .fragment, values: shading.lights)
                            .parameter("material", functionType: .fragment, value: uniforms),
                        shadowBinding: shadowBinding
                    )
                }
                .vertexDescriptor(descriptor)
                .depthCompare(function: .greater, writes: true)
                .vertexAmplification(count: viewCount)

                if draw.material.outlineWidth > 0 {
                    // Back faces only, so the pushed-out hull shows just around the silhouette.
                    try RenderPipeline(label: "Toon Outline", vertexShader: shaders.outlineVertex, fragmentShader: shaders.outlineFragment) {
                        materialDraw(submesh, cullMode: .front, isMirrored: isMirrored, stereoViews: stereoViews)
                            .vertexBuffers(mesh.vertexBuffers)
                            .parameter("frame", functionType: .vertex, value: shading.frame)
                            .parameter("modelMatrix", functionType: .vertex, value: modelMatrix)
                            .parameter("normalMatrix", functionType: .vertex, value: normalMatrix)
                            .parameter("outline", value: ToonOutlineUniforms(color: draw.material.outlineColor, width: draw.material.outlineWidth, viewportSize: viewportSize))
                    }
                    .vertexDescriptor(descriptor)
                    .depthCompare(function: .greater, writes: true)
                    .vertexAmplification(count: viewCount)
                }
            }
        }
    }

    static func bindShadows(_ element: some Element, shadowBinding: (texture: MTLTexture, sampler: MTLSamplerState, uniforms: BlinnPhongShadowUniforms)?) -> AnyElement {
        guard let shadowBinding else {
            return element.eraseToAnyElement()
        }
        return element
            .parameter("shadowMap", texture: shadowBinding.texture)
            .parameter("shadowSampler", samplerState: shadowBinding.sampler)
            .parameter("shadow", functionType: .fragment, value: shadowBinding.uniforms)
            .eraseToAnyElement()
    }
}

// From Toon.metal, loaded once.
private struct ToonShaders {
    var vertex: VertexShader
    var fragment: FragmentShader
    var shadowedFragment: FragmentShader
    var outlineVertex: VertexShader
    var outlineFragment: FragmentShader

    nonisolated(unsafe) private static var cached: Self?
    private static let lock = NSLock()

    static func shared() throws -> Self {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let library = try ShaderLibrary(bundle: .sceneSprocketsToonShaders()).namespaced("Toon")
        func fragment(shadows: Bool) throws -> FragmentShader {
            var constants = FunctionConstants()
            constants["HAS_SHADOWS"] = .bool(shadows)
            return try library.function(named: "fragment_main", type: FragmentShader.self, constants: constants)
        }
        let shaders = Self(
            vertex: try library.function(named: "vertex_main", type: VertexShader.self),
            fragment: try fragment(shadows: false),
            shadowedFragment: try fragment(shadows: true),
            outlineVertex: try library.function(named: "outline_vertex", type: VertexShader.self),
            outlineFragment: try library.function(named: "outline_fragment", type: FragmentShader.self)
        )
        cached = shaders
        return shaders
    }
}
