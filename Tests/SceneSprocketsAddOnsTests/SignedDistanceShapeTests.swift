import CoreGraphics
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsAddOns
import SceneSprocketsAddOnsShaders
import SceneSprocketsBlinnPhong
import simd
import Testing

// MARK: CPU

@Test
func primitiveDistances() {
    let sphere = SignedDistanceShape.sphere(radius: 1, transform: .init(translation: [2, 0, 0]))
    #expect(abs(sphere.distance(at: [2, 0, 0]) + 1) < 1e-5)
    #expect(abs(sphere.distance(at: [5, 0, 0]) - 2) < 1e-5)

    let box = SignedDistanceShape.roundedBox(size: [2, 2, 2])
    #expect(abs(box.distance(at: [3, 0, 0]) - 2) < 1e-5)
    #expect(abs(box.distance(at: .zero) + 1) < 1e-5)

    let capsule = SignedDistanceShape.capsule(start: [0, -1, 0], end: [0, 1, 0], radius: 0.5)
    #expect(abs(capsule.distance(at: [1, 0, 0]) - 0.5) < 1e-5)
    #expect(abs(capsule.distance(at: [0, 2, 0]) - 0.5) < 1e-5)
}

@Test
func scaledPrimitiveDistanceDoesNotOvershoot() {
    let sphere = SignedDistanceShape.sphere(radius: 1, transform: .init(scale: [2, 1, 1]))
    // The true distance from (0, 3, 0) to the ellipsoid is 2.
    let distance = sphere.distance(at: [0, 3, 0])
    #expect(distance > 0 && distance <= 2 + 1e-5)
}

@Test
func smoothUnionFillsTheGapBetweenNearbySpheres() {
    let spheres: [SignedDistanceShape] = [.sphere(radius: 0.5, transform: .init(translation: [-0.6, 0, 0])), .sphere(radius: 0.5, transform: .init(translation: [0.6, 0, 0]))]
    // Midway the spheres are 0.1 away; a sharp union leaves a gap there.
    #expect(SignedDistanceShape.smoothUnion(spheres).distance(at: .zero) > 0)
    #expect(SignedDistanceShape.smoothUnion(spheres, smoothing: 0.5).distance(at: .zero) < 0)
}

@Test
func subtractionAndIntersection() {
    let big = SignedDistanceShape.sphere(radius: 1)
    let small = SignedDistanceShape.sphere(radius: 0.5)
    #expect(SignedDistanceShape.smoothSubtraction(big, small).distance(at: .zero) > 0)
    #expect(SignedDistanceShape.smoothSubtraction(big, small).distance(at: [0.75, 0, 0]) < 0)
    let shifted = SignedDistanceShape.sphere(radius: 1, transform: .init(translation: [1.5, 0, 0]))
    #expect(SignedDistanceShape.smoothIntersection(big, shifted).distance(at: [0.75, 0, 0]) < 0)
    #expect(SignedDistanceShape.smoothIntersection(big, shifted).distance(at: [-0.5, 0, 0]) > 0)
}

@Test
func boundsContainTheSurfaceIncludingSmoothing() throws {
    let shape = SignedDistanceShape.smoothUnion([
        .sphere(radius: 0.5, transform: .init(translation: [-1, 0, 0])),
        .roundedBox(size: [1, 1, 1], cornerRadius: 0.2, transform: .init(translation: [1, 0, 0])),
        .capsule(start: [0, -1, 0], end: [0, 1, 0], radius: 0.25)
    ], smoothing: 0.4)
    let bounds = try #require(shape.bounds)
    // Every point outside the bounds is outside the shape.
    for x in stride(from: Float(-3), through: 3, by: 0.25) {
        for y in stride(from: Float(-3), through: 3, by: 0.25) {
            for z in stride(from: Float(-3), through: 3, by: 0.25) {
                let point = SIMD3(x, y, z)
                if any(point .< bounds.min) || any(point .> bounds.max) {
                    #expect(shape.distance(at: point) > 0)
                }
            }
        }
    }
}

@Test
func emptyShapesHaveNoBoundsOrProgram() throws {
    #expect(SignedDistanceShape.smoothUnion([]).bounds == nil)
    #expect(try SignedDistanceShape.smoothUnion([]).instructions().isEmpty)
    let disjoint = SignedDistanceShape.smoothIntersection(.sphere(radius: 1), .sphere(radius: 1, transform: .init(translation: [5, 0, 0])))
    #expect(disjoint.bounds == nil)
}

@Test
func programIsPostfixAndFoldsUnionsPairwise() throws {
    let shape = SignedDistanceShape.smoothUnion([.sphere(radius: 1), .sphere(radius: 2), .capsule(start: .zero, end: [1, 0, 0], radius: 1)], smoothing: 0.5)
    let operations = try shape.instructions().map(\.operation)
    #expect(operations == [
        SIGNED_DISTANCE_OP_SPHERE, SIGNED_DISTANCE_OP_SPHERE, SIGNED_DISTANCE_OP_SMOOTH_UNION,
        SIGNED_DISTANCE_OP_CAPSULE, SIGNED_DISTANCE_OP_SMOOTH_UNION
    ])
}

@Test
func manyShapesInOneUnionNeedAShallowStack() throws {
    let spheres = (0..<100).map { SignedDistanceShape.sphere(radius: 0.1, transform: .init(translation: [Float($0), 0, 0])) }
    #expect(try SignedDistanceShape.smoothUnion(spheres).instructions().count == 199)
}

@Test
func deeplyNestedShapeThrows() {
    var shape = SignedDistanceShape.sphere(radius: 1)
    for _ in 0..<20 {
        shape = .smoothSubtraction(.sphere(radius: 1), shape)
    }
    #expect(throws: SignedDistanceShapeError.self) {
        try shape.instructions()
    }
}

// MARK: GPU

// BGRA pixels of a 32x32 render, camera at `cameraZ` on the z axis looking down -z, lit from the camera.
@MainActor
private func render(_ nodes: [SceneGraph.Node], cameraZ: Float = 4) throws -> [SIMD4<UInt8>] {
    let root = SceneGraph.Node()
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, cameraZ]), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(45))))))
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, cameraZ]), content: .light(Light(type: .directional, color: [1, 1, 1], intensity: 1))))
    for node in nodes {
        root.addChild(node)
    }
    let renderer = try OffscreenRenderer(size: CGSize(width: 32, height: 32))
    let element = SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [SignedDistanceRenderer(), BlinnPhongMaterialRenderer()])
    let texture = try renderer.render(element).texture
    var pixels = [SIMD4<UInt8>](repeating: .zero, count: 32 * 32)
    texture.getBytes(&pixels, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
    return pixels
}

private func covered(_ pixels: [SIMD4<UInt8>], where test: (SIMD4<UInt8>) -> Bool) -> Set<Int> {
    Set(pixels.indices.filter { test(pixels[$0]) })
}

// BGRA: z is red, y green, x blue. The gray specular highlight adds to every channel, so test for the dominant one.
private func isRed(_ pixel: SIMD4<UInt8>) -> Bool {
    Int(pixel.z) > Int(pixel.y) + 40 && Int(pixel.z) > Int(pixel.x) + 40
}

private func isGreen(_ pixel: SIMD4<UInt8>) -> Bool {
    Int(pixel.y) > Int(pixel.z) + 40 && Int(pixel.y) > Int(pixel.x) + 40
}

private var red: SignedDistanceMaterial.Surface {
    .blinnPhong(BlinnPhongSceneMaterial(color: [1, 0, 0]))
}

@Test
@MainActor
func raymarchedSphereCoversTheSamePixelsAsAMeshSphere() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let shapePixels = covered(try render([try SignedDistanceShape.sphere(radius: 1).makeNode(device: device, surface: red)]), where: isRed)
    let mesh = SceneGraph.Node(content: .mesh(SceneGraph.Shape.sphere(radius: 1).metalMesh(), material: BlinnPhongSceneMaterial(color: [1, 0, 0])))
    let meshPixels = covered(try render([mesh]), where: isRed)
    #expect(!shapePixels.isEmpty)
    // Only edge pixels may differ; the mesh sphere is a polygon.
    #expect(shapePixels.symmetricDifference(meshPixels).count <= meshPixels.count / 10)
}

@Test
@MainActor
func shapesAndMeshesHideEachOtherByDepth() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let green = BlinnPhongSceneMaterial(color: [0, 1, 0])
    let center = 16 * 32 + 16
    // A mesh box in front of the shape hides it.
    let front = SceneGraph.Node(transform: .init(translation: [0, 0, 1.5]), content: .mesh(SceneGraph.Shape.box(width: 0.5, height: 0.5, length: 0.5).metalMesh(), material: green))
    let frontPixels = try render([try SignedDistanceShape.sphere(radius: 1).makeNode(device: device, surface: red), front])
    #expect(isGreen(frontPixels[center]))
    // The shape hides a mesh box behind it.
    let back = SceneGraph.Node(transform: .init(translation: [0, 0, -1.5]), content: .mesh(SceneGraph.Shape.box(width: 0.5, height: 0.5, length: 0.5).metalMesh(), material: green))
    let backPixels = try render([try SignedDistanceShape.sphere(radius: 1).makeNode(device: device, surface: red), back])
    #expect(isRed(backPixels[center]))
}

@Test
@MainActor
func shapeDrawsWithTheCameraInsideItsBounds() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    // A hollow shell: the camera at the origin is inside the box and inside the hollow.
    let shell = SignedDistanceShape.smoothSubtraction(.sphere(radius: 2), .sphere(radius: 1.5))
    let pixels = try render([try shell.makeNode(device: device, surface: red)], cameraZ: 0)
    #expect(covered(pixels, where: isRed).count == pixels.count)
}

@Test
@MainActor
func smoothUnionLeavesNoGapBetweenSpheres() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let spheres: [SignedDistanceShape] = [.sphere(radius: 0.5, transform: .init(translation: [-0.6, 0, 0])), .sphere(radius: 0.5, transform: .init(translation: [0.6, 0, 0]))]
    let center = 16 * 32 + 16
    let sharp = try render([try SignedDistanceShape.smoothUnion(spheres).makeNode(device: device, surface: red)])
    #expect(!isRed(sharp[center]))
    let smooth = try render([try SignedDistanceShape.smoothUnion(spheres, smoothing: 0.5).makeNode(device: device, surface: red)])
    #expect(isRed(smooth[center]))
}

@Test
@MainActor
func nodeTransformMovesTheShape() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let node = try SignedDistanceShape.sphere(radius: 0.5).makeNode(device: device, surface: red)
    node.transform.translation = [1, 0, 0]
    let pixels = covered(try render([node]), where: isRed)
    #expect(!pixels.isEmpty)
    #expect(pixels.allSatisfy { $0 % 32 > 16 })
}
