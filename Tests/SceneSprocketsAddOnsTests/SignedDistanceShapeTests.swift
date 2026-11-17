import CoreGraphics
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsAddOns
import SceneSprocketsAddOnsShaders
import SceneSprocketsBlinnPhong
import SceneSprocketsPBR
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

// MARK: Shadows and PBR

// A camera-to-world pose at `eye` looking at `target`.
private func pose(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
    let forward = simd_normalize(eye - target)
    let right = simd_normalize(simd_cross([0, 1, 0], forward))
    return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(simd_cross(forward, right), 0), SIMD4(forward, 0), SIMD4(eye, 1)))
}

// A gray floor lit by a directional light that shines down and towards -x, and the pixel where a shape floating at
// (0, 1.5, 0) shadows it. Returns the brightness at that pixel.
@MainActor
private func floorBrightness(under shape: SceneGraph.Node, shadows: Bool) throws -> Int {
    let root = SceneGraph.Node()
    let projection = PerspectiveProjection(verticalAngleOfView: .degrees(50))
    root.addChild(SceneGraph.Node(transform: .init(storing: pose(eye: [0, 6, 6], target: .zero)), content: .camera(Camera(projection: projection))))
    root.addChild(SceneGraph.Node(transform: .init(storing: pose(eye: .zero, target: [-0.5, -1, 0])), content: .light(.directional())))
    let floor = BlinnPhongSceneMaterial(ambient: .color(0), diffuse: .color([0.5, 0.5, 0.5]), specular: .color(0), shininess: 1)
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, -0.05, 0], scale: [6, 0.1, 6]), content: .mesh(SceneGraph.Shape.box(width: 1, height: 1, length: 1).metalMesh(), material: floor)))
    shape.transform.translation = [0, 1.5, 0]
    root.addChild(shape)

    let size = 128
    let renderer = try OffscreenRenderer(size: CGSize(width: size, height: size), colorUsage: Shadows.requiredColorUsage, depthUsage: Shadows.requiredDepthUsage)
    let element = SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [SignedDistanceRenderer(), BlinnPhongMaterialRenderer()], shadows: shadows ? Shadows(intensity: 0.8) : nil)
    let texture = try renderer.render(element).texture
    // Where (-1, 0, 0) on the floor lands on screen.
    let view = pose(eye: [0, 6, 6], target: .zero).inverse
    let clip = projection.projectionMatrix(aspectRatio: 1) * view * SIMD4<Float>(-1, 0, 0, 1)
    let ndc = SIMD2(clip.x, clip.y) / clip.w
    let pixel = SIMD2(Int((ndc.x + 1) / 2 * Float(size)), Int((1 - ndc.y) / 2 * Float(size)))
    var value = SIMD4<UInt8>.zero
    texture.getBytes(&value, bytesPerRow: 4, from: MTLRegionMake2D(pixel.x, pixel.y, 1, 1), mipmapLevel: 0)
    return Int(value.x) + Int(value.y) + Int(value.z)
}

@Test
@MainActor
func shapeCastsShadowOnTheFloor() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let sphere = SignedDistanceShape.sphere(radius: 0.6)
    let lit = try floorBrightness(under: try sphere.makeNode(device: device, surface: red), shadows: false)
    let shadowed = try floorBrightness(under: try sphere.makeNode(device: device, surface: red), shadows: true)
    #expect(lit > 30)
    #expect(Double(shadowed) < Double(lit) * 0.6)

    let nonCaster = try sphere.makeNode(device: device, surface: red)
    guard case let .mesh(mesh, materials, _, _) = nonCaster.content else {
        Issue.record("The shape node has no mesh")
        return
    }
    nonCaster.content = .mesh(mesh, materials: materials, castsShadow: false)
    #expect(try floorBrightness(under: nonCaster, shadows: true) == lit)
}

@Test
@MainActor
func shapeDoesNotShadowItselfWhereLit() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    // Lit from the camera, so every visible point faces the light and none is in its own shadow.
    let node = try SignedDistanceShape.sphere(radius: 1).makeNode(device: device, surface: red)
    let root = SceneGraph.Node()
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(45))))))
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .light(.directional())))
    root.addChild(node)
    func pixels(_ shadows: Shadows?) throws -> [SIMD4<UInt8>] {
        let renderer = try OffscreenRenderer(size: CGSize(width: 64, height: 64), colorUsage: Shadows.requiredColorUsage, depthUsage: Shadows.requiredDepthUsage)
        let texture = try renderer.render(SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [SignedDistanceRenderer()], shadows: shadows)).texture
        var pixels = [SIMD4<UInt8>](repeating: .zero, count: 64 * 64)
        texture.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return pixels
    }
    let lit = try pixels(nil)
    let shadowed = try pixels(Shadows(intensity: 0.8))
    let sphere = lit.indices.filter { isRed(lit[$0]) }
    let darkened = sphere.filter { Int(lit[$0].z) - Int(shadowed[$0].z) > 8 }
    #expect(sphere.count > 500)
    #expect(darkened.count < sphere.count / 50, "\(darkened.count) of \(sphere.count) pixels shadow themselves")
}

@Test
@MainActor
func pbrShapeLooksLikeAPBRMesh() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let pbr = PBRMaterialRenderer()
    let material = PBRSceneMaterial(baseColor: [1, 0, 0], metallic: 0, roughness: 0.6)
    func render(_ node: SceneGraph.Node) throws -> [SIMD4<UInt8>] {
        let root = SceneGraph.Node()
        root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(45))))))
        root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .light(.directional())))
        root.addChild(node)
        let renderer = try OffscreenRenderer(size: CGSize(width: 32, height: 32))
        let texture = try renderer.render(SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [SignedDistanceRenderer(pbr: pbr), pbr])).texture
        var pixels = [SIMD4<UInt8>](repeating: .zero, count: 32 * 32)
        texture.getBytes(&pixels, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
        return pixels
    }
    let shape = try render(try SignedDistanceShape.sphere(radius: 1).makeNode(device: device, surface: .pbr(material)))
    let mesh = try render(SceneGraph.Node(content: .mesh(SceneGraph.Shape.sphere(radius: 1).metalMesh(), material: material)))
    let shapePixels = covered(shape, where: isRed)
    let meshPixels = covered(mesh, where: isRed)
    #expect(!shapePixels.isEmpty)
    #expect(shapePixels.symmetricDifference(meshPixels).count <= meshPixels.count / 10)
    // Same lighting: the centers match closely.
    let center = 16 * 32 + 16
    let difference = SIMD4<Int>(truncatingIfNeeded: shape[center]) &- SIMD4<Int>(truncatingIfNeeded: mesh[center])
    #expect(abs(difference.x) <= 6 && abs(difference.y) <= 6 && abs(difference.z) <= 6, "\(shape[center]) vs \(mesh[center])")
}
