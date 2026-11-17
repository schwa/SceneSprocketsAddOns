import CoreGraphics
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsBlinnPhong
import SceneSprocketsToon
import simd
import Testing

private let side = 64

// BGRA pixels of a unit sphere seen from z = 4, lit by a directional light from the upper left.
@MainActor
private func render(_ material: ToonMaterial) throws -> [SIMD4<UInt8>] {
    let root = SceneGraph.Node()
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(45))))))
    root.addChild(SceneGraph.Node(transform: .init(position: [-1, 1, 1], lookingAt: .zero), content: .light(.directional())))
    root.addChild(SceneGraph.Node(content: .mesh(SceneGraph.Shape.sphere(radius: 1).metalMesh(), material: material)))
    let renderer = try OffscreenRenderer(size: CGSize(width: side, height: side))
    let texture = try renderer.render(SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [ToonRenderer()])).texture
    var pixels = [SIMD4<UInt8>](repeating: .zero, count: side * side)
    texture.getBytes(&pixels, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
    return pixels
}

private func isDrawn(_ pixel: SIMD4<UInt8>) -> Bool {
    pixel.x > 8 || pixel.y > 8 || pixel.z > 8
}

@Test
@MainActor
func hardBandsGiveFewDistinctColors() throws {
    let pixels = try render(ToonMaterial(color: [1, 0.2, 0.1], bands: 2, bandSoftness: 0, highlightSize: 0, outlineWidth: 0))
    let colors = Set(pixels.filter(isDrawn).map { SIMD3($0.x, $0.y, $0.z) })
    // Shade, two lit bands, and a few edge pixels from multisampling or the mesh's facets.
    #expect(colors.count >= 3)
    #expect(colors.count <= 6, "\(colors.count) colors")
}

@Test
@MainActor
func outlineDrawsDarkPixelsAroundTheSilhouette() throws {
    let plain = try render(ToonMaterial(color: [1, 1, 1], highlightSize: 0, outlineWidth: 0))
    let outlined = try render(ToonMaterial(color: [1, 1, 1], highlightSize: 0, outlineColor: [1, 0, 0, 1], outlineWidth: 3))
    // BGRA: z is red. Red-only pixels appear where the plain render had none.
    let outline = outlined.indices.filter { outlined[$0].z > 200 && outlined[$0].x < 40 && !isDrawn(plain[$0]) }
    #expect(outline.count > 40)
    // The sphere itself is not covered by the outline.
    let center = side / 2 * side + side / 2
    #expect(outlined[center].x > 100)
}

@Test
@MainActor
func noOutlineAtZeroWidth() throws {
    let pixels = try render(ToonMaterial(color: [0, 0, 1], outlineColor: [1, 0, 0, 1], outlineWidth: 0))
    #expect(!pixels.contains { $0.z > 200 && $0.x < 40 })
}

@Test
@MainActor
func toonMeshesReceiveShadows() throws {
    let root = SceneGraph.Node()
    let eye = SIMD3<Float>(0, 6, 6)
    root.addChild(SceneGraph.Node(transform: .init(position: eye, lookingAt: .zero), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(50))))))
    root.addChild(SceneGraph.Node(transform: .init(position: .zero, lookingAt: [0, -1, 0.001]), content: .light(.directional())))
    let material = ToonMaterial(color: [1, 1, 1], shadeColor: [0.2, 0.2, 0.2], highlightSize: 0, outlineWidth: 0)
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, -0.05, 0]), content: .mesh(SceneGraph.Shape.box(width: 6, height: 0.1, length: 6).metalMesh(), material: material)))
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, 1.5, 0]), content: .mesh(SceneGraph.Shape.sphere(radius: 0.6).metalMesh(), material: BlinnPhongSceneMaterial(color: [1, 1, 1]))))
    func centerBrightness(_ shadows: Shadows?) throws -> Int {
        let renderer = try OffscreenRenderer(size: CGSize(width: side, height: side), colorUsage: Shadows.requiredColorUsage, depthUsage: Shadows.requiredDepthUsage)
        let texture = try renderer.render(SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [ToonRenderer(), BlinnPhongMaterialRenderer()], shadows: shadows)).texture
        // The floor directly below the sphere, where (0, 0, 0) lands on screen.
        let projection = PerspectiveProjection(verticalAngleOfView: .degrees(50))
        let clip = projection.projectionMatrix(aspectRatio: 1) * Transform3D(position: eye, lookingAt: .zero).matrix.inverse * SIMD4<Float>(0, 0, 0, 1)
        let ndc = SIMD2(clip.x, clip.y) / clip.w
        let pixel = SIMD2(Int((ndc.x + 1) / 2 * Float(side)), Int((1 - ndc.y) / 2 * Float(side)))
        var value = SIMD4<UInt8>.zero
        texture.getBytes(&value, bytesPerRow: 4, from: MTLRegionMake2D(pixel.x, pixel.y, 1, 1), mipmapLevel: 0)
        return Int(value.x) + Int(value.y) + Int(value.z)
    }
    let lit = try centerBrightness(nil)
    let shadowed = try centerBrightness(Shadows(intensity: 1))
    #expect(lit > 300)
    #expect(Double(shadowed) < Double(lit) * 0.5)
}
