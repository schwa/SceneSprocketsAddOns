import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsAddOnsShaders
import simd
import SwiftMesh

public extension Terrain {
    /// A node that draws this terrain, labeled "Terrain". The view needs a ``TerrainRenderer``.
    ///
    /// The terrain lies in the node's x/z plane with heights along y. Its mesh is only a box of corner points for
    /// bounds and selection; the renderer tessellates the terrain each frame.
    func makeNode(settings: TerrainSettings = TerrainSettings(), drawsSky: Bool = false) -> SceneGraph.Node {
        let node = SceneGraph.Node(label: "Terrain")
        let half = (isStreaming ? outerLevel.size : worldSize) / 2
        let corners: [SIMD3<Float>] = [-1, 1].flatMap { x in
            [-1, 1].flatMap { y in
                [-1, 1].map { z in SIMD3<Float>(x * half, y * heightScale, z * half) }
            }
        }
        let mesh = MetalMesh(
            device: data.device,
            attributes: [.positions(corners)],
            submeshes: [MetalMesh.SubmeshIndices(label: "Bounds", indices: corners.indices.map { UInt32($0) }, primitiveType: .point)],
            label: "Terrain"
        )
        let material = TerrainSceneMaterial(terrain: self, settings: settings, drawsSky: drawsSky)
        node.content = .mesh(mesh, materials: [material], castsShadow: false, receivesShadow: false)
        return node
    }
}

/// The material of a terrain node: the terrain and how to draw it. A ``TerrainRenderer`` draws it.
public struct TerrainSceneMaterial: SceneMaterial {
    public var terrain: Terrain
    public var settings: TerrainSettings
    /// Takes the sun direction from the scene's first directional light, when there is one, instead of
    /// `settings.sunDirection`.
    public var usesSceneLight: Bool
    /// Draws the terrain's built-in sky where nothing has been drawn yet. Meshes drawn later still cover it.
    public var drawsSky: Bool
    /// Moves the streamed clipmap with the camera. Has no effect on bounded (image) terrain.
    public var streams: Bool

    public init(terrain: Terrain, settings: TerrainSettings = TerrainSettings(), usesSceneLight: Bool = true, drawsSky: Bool = false, streams: Bool = true) {
        self.terrain = terrain
        self.settings = settings
        self.usesSceneLight = usesSceneLight
        self.drawsSky = drawsSky
        self.streams = streams
    }
}

/// The renderer that draws every node with a ``TerrainSceneMaterial``.
///
/// Before the scene pass it streams each terrain around the camera and updates its tessellation in compute passes;
/// in the scene pass it draws the tessellated terrain with reversed depth. Add one instance to the renderers of a
/// `SceneView` or `SceneGraphElement`. Stereo views draw the center camera's tessellation.
public struct TerrainRenderer: MaterialRenderer, PrePassRenderer {
    // Uniforms made in the pre-pass, reused by the scene pass of the same frame.
    private final class FrameState {
        var uniforms: [ObjectIdentifier: TerrainUniforms] = [:]
    }

    private let state = FrameState()

    public init() {
        // Uniforms are made per terrain each frame.
    }

    public var materialType: any SceneMaterial.Type {
        TerrainSceneMaterial.self
    }

    public func makePrePassElement(entries: [SceneGraph.MeshEntry], context: RenderContext, viewSize: (width: Int, height: Int), otherOpaqueContent _: () throws -> AnyElement?) throws -> AnyElement? {
        state.uniforms = [:]
        let updates: [AnyElement] = try entries.compactMap { entry in
            guard let material = entry.material as? TerrainSceneMaterial else {
                return nil
            }
            let terrain = material.terrain
            let worldToTerrain = entry.worldTransform.inverse
            let camera = worldToTerrain * context.cameraMatrix.columns.3
            let cameraPosition = SIMD3(camera.x, camera.y, camera.z)
            if material.streams {
                try terrain.stream(around: cameraPosition)
            }
            var settings = material.settings
            if material.usesSceneLight, let sun = Self.sunDirection(context: context, worldToTerrain: worldToTerrain) {
                settings.sunDirection = sun
            }
            let uniforms = terrain.makeUniforms(
                viewProjection: context.projectionMatrix * context.viewMatrix * entry.worldTransform,
                cameraPosition: cameraPosition,
                focalLength: abs(context.projectionMatrix.columns.1.y),
                viewportHeight: Float(viewSize.height),
                settings: settings
            )
            state.uniforms[ObjectIdentifier(terrain)] = uniforms
            return try terrain.updateWork(uniforms: uniforms).eraseToAnyElement()
        }
        guard !updates.isEmpty else {
            return nil
        }
        return ForEach(Array(updates.enumerated()), id: \.offset) { _, update in
            update
        }
        .eraseToAnyElement()
    }

    public func makeElement(entries: [SceneGraph.MeshEntry], context _: RenderContext) throws -> AnyElement {
        let draws: [AnyElement] = try entries.compactMap { entry in
            guard let material = entry.material as? TerrainSceneMaterial, let uniforms = state.uniforms[ObjectIdentifier(material.terrain)] else {
                return nil
            }
            let terrain = material.terrain
            let style = material.settings.style
            if material.drawsSky {
                return try MetalSprockets.Group {
                    try terrain.terrainWork(uniforms: uniforms, style: style)
                    try terrain.skyWork(uniforms: uniforms, style: style)
                }
                .eraseToAnyElement()
            }
            return try terrain.terrainWork(uniforms: uniforms, style: style).eraseToAnyElement()
        }
        return ForEach(Array(draws.enumerated()), id: \.offset) { _, draw in
            draw
        }
        .eraseToAnyElement()
    }

    // Toward the first directional light, in terrain space. Lights point down their node's -Z axis.
    private static func sunDirection(context: RenderContext, worldToTerrain: simd_float4x4) -> SIMD3<Float>? {
        guard let light = context.lights.first(where: { $0.light.type == .directional }) else {
            return nil
        }
        let toward = worldToTerrain * SIMD4(light.worldTransform.columns.2.x, light.worldTransform.columns.2.y, light.worldTransform.columns.2.z, 0)
        let direction = SIMD3(toward.x, toward.y, toward.z)
        return length(direction) > 0 ? normalize(direction) : nil
    }
}
