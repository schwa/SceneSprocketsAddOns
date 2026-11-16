import CoreGraphics
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsAddOns
import simd
import Testing

@MainActor
private func render(_ root: SceneGraph.Node, size: Int = 64) throws -> [SIMD4<UInt8>] {
    let renderer = try OffscreenRenderer(size: CGSize(width: size, height: size))
    let element = SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [TerrainRenderer()])
    // Two frames: the first only splits from the two base triangles.
    _ = try renderer.render(element)
    let texture = try renderer.render(element).texture
    var pixels = [SIMD4<UInt8>](repeating: .zero, count: size * size)
    texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
    return pixels
}

@MainActor
private func scene(terrain: Terrain, cameraY: Float, pitch: Float, drawsSky: Bool = false) -> SceneGraph.Node {
    let root = SceneGraph.Node()
    let camera = SceneGraph.Node(content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(60), depthMode: .standard(zClip: 1 ... 100_000)))))
    camera.transform = .init(translation: [0, cameraY, 0], rotation: simd_quatf(angle: pitch, axis: [1, 0, 0]))
    root.addChild(camera)
    root.addChild(terrain.makeNode(drawsSky: drawsSky))
    return root
}

@Test
@MainActor
func terrainNodeDrawsGroundBelowTheCamera() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let terrain = try Terrain(device: device, heightSource: .procedural(size: 512))
    let height = terrain.height(at: .zero)
    // Looking straight down from 500 m above the ground.
    let pixels = try render(scene(terrain: terrain, cameraY: height + 500, pitch: -.pi / 2))
    let drawn = pixels.filter { $0.x > 0 || $0.y > 0 || $0.z > 0 }
    #expect(drawn.count > pixels.count * 9 / 10)
}

@Test
@MainActor
func terrainNodeDrawsSkyWhenAsked() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let terrain = try Terrain(device: device, heightSource: .procedural(size: 512))
    let height = terrain.height(at: .zero)
    // Looking straight up: only sky.
    let withoutSky = try render(scene(terrain: terrain, cameraY: height + 500, pitch: .pi / 2))
    let withSky = try render(scene(terrain: terrain, cameraY: height + 500, pitch: .pi / 2, drawsSky: true))
    // BGRA: blue sky has more blue (x) than red (z).
    #expect(withSky.allSatisfy { $0.x > $0.z })
    #expect(withSky[32 * 64 + 32] != withoutSky[32 * 64 + 32])
}
