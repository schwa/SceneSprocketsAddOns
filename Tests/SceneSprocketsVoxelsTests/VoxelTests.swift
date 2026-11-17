import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsBlinnPhong
import SceneSprocketsPBR
import SceneSprocketsVoxels
import simd
import Testing

// MARK: MagicaVoxel

private func chunk(_ id: String, content: [UInt8], children: [UInt8] = []) -> [UInt8] {
    Array(id.utf8) + uint32(content.count) + uint32(children.count) + content + children
}

private func uint32(_ value: Int) -> [UInt8] {
    withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)
}

// A 2x3x4 model (z-up) with two voxels and a palette whose entry i - 1 is (i, 0, 0).
private func voxFile(palette: Bool = true) -> Data {
    var children = chunk("SIZE", content: uint32(2) + uint32(3) + uint32(4))
    children += chunk("XYZI", content: uint32(2) + [0, 0, 0, 1] + [1, 2, 3, 5])
    if palette {
        children += chunk("RGBA", content: (1...256).flatMap { [UInt8($0 & 255), 0, 0, 255] })
    }
    return Data(Array("VOX ".utf8) + uint32(150) + chunk("MAIN", content: [], children: children))
}

@Test
func readsMagicaVoxelAsYUp() throws {
    let grids = try VoxelGrid.magicaVoxelModels(data: voxFile())
    #expect(grids.count == 1)
    let grid = try #require(grids.first)
    #expect(grid.size == [2, 4, 3])
    #expect(grid.filledCount == 2)
    // MagicaVoxel (x, y, z) is grid (x, z, sizeY - 1 - y); color index i is palette entry i - 1.
    #expect(grid[[0, 0, 2]] == [1, 0, 0, 255])
    #expect(grid[[1, 3, 0]] == [5, 0, 0, 255])
}

@Test
func magicaVoxelWithoutPaletteUsesTheDefaultPalette() throws {
    let grid = try #require(try VoxelGrid.magicaVoxelModels(data: voxFile(palette: false)).first)
    #expect(grid[[0, 0, 2]] == [255, 255, 255, 255])
    #expect(grid[[1, 3, 0]] == [255, 255, 51, 255])
}

private func string(_ value: String) -> [UInt8] {
    uint32(value.utf8.count) + Array(value.utf8)
}

private func dictionary(_ pairs: [(String, String)]) -> [UInt8] {
    uint32(pairs.count) + pairs.flatMap { string($0.0) + string($0.1) }
}

// Two 2x2x2 models under a group: "left" at (-10, 0, 0), and "turned" at (0, 20, 5) turned 90 degrees about z.
// A third transform is hidden, and a fourth is on a hidden layer.
private func voxSceneFile() -> Data {
    var children: [UInt8] = []
    for _ in 0..<2 {
        children += chunk("SIZE", content: uint32(2) + uint32(2) + uint32(2))
        children += chunk("XYZI", content: uint32(1) + [0, 0, 0, 1])
    }
    func transform(_ node: Int, child: Int, layer: Int = 0, attributes: [(String, String)] = [], frame: [(String, String)] = []) -> [UInt8] {
        chunk("nTRN", content: uint32(node) + dictionary(attributes) + uint32(child) + uint32(-1 & 0xFFFF_FFFF) + uint32(layer) + uint32(1) + dictionary(frame))
    }
    func shape(_ node: Int, model: Int) -> [UInt8] {
        chunk("nSHP", content: uint32(node) + dictionary([]) + uint32(1) + uint32(model) + dictionary([]))
    }
    children += transform(0, child: 1)
    children += chunk("nGRP", content: uint32(1) + dictionary([]) + uint32(4) + uint32(2) + uint32(4) + uint32(6) + uint32(8))
    children += transform(2, child: 3, attributes: [("_name", "left")], frame: [("_t", "-10 0 0")])
    children += shape(3, model: 0)
    // Rotation rows (0 -1 0), (1 0 0), (0 0 1): row 0 in column 1, row 1 in column 0, row 0 negative.
    children += transform(4, child: 5, attributes: [("_name", "turned")], frame: [("_t", "0 20 5"), ("_r", "\(1 | 0 << 2 | 1 << 4)")])
    children += shape(5, model: 1)
    children += transform(6, child: 7, attributes: [("_hidden", "1")])
    children += shape(7, model: 0)
    children += transform(8, child: 9, layer: 3)
    children += shape(9, model: 0)
    children += chunk("LAYR", content: uint32(3) + dictionary([("_hidden", "1")]) + uint32(-1 & 0xFFFF_FFFF))
    return Data(Array("VOX ".utf8) + uint32(150) + chunk("MAIN", content: [], children: children))
}

private func isClose(_ a: simd_float4x4, _ b: simd_float4x4) -> Bool {
    (0..<4).allSatisfy { simd_distance(a[$0], b[$0]) < 1e-5 }
}

@Test
func readsTheMagicaVoxelSceneGraph() throws {
    let scene = try MagicaVoxelScene(data: voxSceneFile())
    #expect(scene.models.count == 2)
    #expect(scene.instances.map(\.name) == ["left", "turned"])
    #expect(scene.instances.map(\.model) == [0, 1])
    // z-up (x, y, z) is y-up (x, z, -y). Even sizes have no pivot offset.
    var left = matrix_identity_float4x4
    left.columns.3 = [-10, 0, 0, 1]
    #expect(isClose(scene.instances[0].transform, left))
    // 90 degrees about z-up's z is 90 degrees about y-up's y.
    let turned = simd_float4x4(SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 5, -20, 1))
    #expect(isClose(scene.instances[1].transform, turned))
}

@Test
func fileWithoutASceneGraphHasOneInstancePerModel() throws {
    let scene = try MagicaVoxelScene(data: voxFile())
    #expect(scene.instances.count == 1)
    #expect(scene.instances.first?.model == 0)
    #expect(scene.instances.first?.transform == matrix_identity_float4x4)
}

@Test
func badMagicaVoxelFilesThrow() {
    #expect(throws: MagicaVoxelError.notAVoxFile) {
        try VoxelGrid.magicaVoxelModels(data: Data("NOPE0000".utf8))
    }
    #expect(throws: MagicaVoxelError.truncated) {
        try VoxelGrid.magicaVoxelModels(data: voxFile().dropLast(3))
    }
    let empty = Data(Array("VOX ".utf8) + uint32(150) + chunk("MAIN", content: []))
    #expect(throws: MagicaVoxelError.noModels) {
        try VoxelGrid.magicaVoxelModels(data: empty)
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
    let element = SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [VoxelRenderer(), BlinnPhongMaterialRenderer()])
    let texture = try renderer.render(element).texture
    var pixels = [SIMD4<UInt8>](repeating: .zero, count: 32 * 32)
    texture.getBytes(&pixels, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
    return pixels
}

private func covered(_ pixels: [SIMD4<UInt8>], where test: (SIMD4<UInt8>) -> Bool) -> Set<Int> {
    Set(pixels.indices.filter { test(pixels[$0]) })
}

// BGRA: z is red, y green.
private func isRed(_ pixel: SIMD4<UInt8>) -> Bool {
    Int(pixel.z) > Int(pixel.y) + 40 && Int(pixel.z) > Int(pixel.x) + 40
}

private func isGreen(_ pixel: SIMD4<UInt8>) -> Bool {
    Int(pixel.y) > Int(pixel.z) + 40 && Int(pixel.y) > Int(pixel.x) + 40
}

private func filledGrid(size: SIMD3<Int>, color: SIMD4<UInt8> = [255, 0, 0, 255]) -> VoxelGrid {
    var grid = VoxelGrid(size: size)
    for z in 0..<size.z {
        for y in 0..<size.y {
            for x in 0..<size.x {
                grid[[x, y, z]] = color
            }
        }
    }
    return grid
}

@MainActor
private func voxelNode(_ grid: VoxelGrid, voxelSize: Float) throws -> SceneGraph.Node {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let node = SceneGraph.Node()
    try node.setVoxels(grid, voxelSize: voxelSize, device: device)
    return node
}

@Test
@MainActor
func voxelCubeCoversTheSamePixelsAsAMeshBox() throws {
    let voxelPixels = covered(try render([try voxelNode(filledGrid(size: [4, 4, 4]), voxelSize: 0.5)]), where: isRed)
    let mesh = SceneGraph.Node(content: .mesh(SceneGraph.Shape.box(width: 2, height: 2, length: 2).metalMesh(), material: BlinnPhongSceneMaterial(color: [1, 0, 0])))
    let meshPixels = covered(try render([mesh]), where: isRed)
    #expect(!voxelPixels.isEmpty)
    #expect(voxelPixels.symmetricDifference(meshPixels).count <= meshPixels.count / 20)
}

@Test
@MainActor
func emptyVoxelsAreSeeThrough() throws {
    // One red voxel in the +x corner; the rest of the box is empty.
    var grid = VoxelGrid(size: [2, 1, 1])
    grid[[1, 0, 0]] = [255, 0, 0, 255]
    let pixels = covered(try render([try voxelNode(grid, voxelSize: 1)]), where: isRed)
    #expect(!pixels.isEmpty)
    #expect(pixels.allSatisfy { $0 % 32 >= 16 })
}

@Test
@MainActor
func voxelsAndMeshesHideEachOtherByDepth() throws {
    let green = BlinnPhongSceneMaterial(color: [0, 1, 0])
    let center = 16 * 32 + 16
    let front = SceneGraph.Node(transform: .init(translation: [0, 0, 1.5]), content: .mesh(SceneGraph.Shape.box(width: 0.5, height: 0.5, length: 0.5).metalMesh(), material: green))
    #expect(isGreen(try render([try voxelNode(filledGrid(size: [2, 2, 2]), voxelSize: 1), front])[center]))
    let back = SceneGraph.Node(transform: .init(translation: [0, 0, -1.5]), content: .mesh(SceneGraph.Shape.box(width: 0.5, height: 0.5, length: 0.5).metalMesh(), material: green))
    #expect(isRed(try render([try voxelNode(filledGrid(size: [2, 2, 2]), voxelSize: 1), back])[center]))
}

@Test
@MainActor
func voxelsDrawWithTheCameraInsideTheGrid() throws {
    // A hollow 5x5x5 shell; the camera at the origin is in the empty middle voxel.
    var grid = filledGrid(size: [5, 5, 5])
    for z in 1..<4 {
        for y in 1..<4 {
            for x in 1..<4 {
                grid[[x, y, z]] = .zero
            }
        }
    }
    let pixels = try render([try voxelNode(grid, voxelSize: 1)], cameraZ: 0)
    #expect(covered(pixels, where: isRed).count == pixels.count)
}

// MARK: Shadows and PBR

// A camera-to-world pose at `eye` looking at `target`.
private func pose(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
    let forward = simd_normalize(eye - target)
    let right = simd_normalize(simd_cross([0, 1, 0], forward))
    return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(simd_cross(forward, right), 0), SIMD4(forward, 0), SIMD4(eye, 1)))
}

// The brightness of a gray floor where a node floating at (0, 1.5, 0) shadows it, lit by a directional light that
// shines down and towards -x.
@MainActor
private func floorBrightness(under node: SceneGraph.Node, shadows: Bool) throws -> Int {
    let root = SceneGraph.Node()
    let projection = PerspectiveProjection(verticalAngleOfView: .degrees(50))
    let camera = pose(eye: [0, 6, 6], target: .zero)
    root.addChild(SceneGraph.Node(transform: .init(storing: camera), content: .camera(Camera(projection: projection))))
    root.addChild(SceneGraph.Node(transform: .init(storing: pose(eye: .zero, target: [-0.5, -1, 0])), content: .light(.directional())))
    let floor = BlinnPhongSceneMaterial(ambient: .color(0), diffuse: .color([0.5, 0.5, 0.5]), specular: .color(0), shininess: 1)
    root.addChild(SceneGraph.Node(transform: .init(translation: [0, -0.05, 0], scale: [6, 0.1, 6]), content: .mesh(SceneGraph.Shape.box(width: 1, height: 1, length: 1).metalMesh(), material: floor)))
    node.transform.translation = [0, 1.5, 0]
    root.addChild(node)

    let size = 128
    let renderer = try OffscreenRenderer(size: CGSize(width: size, height: size), colorUsage: Shadows.requiredColorUsage, depthUsage: Shadows.requiredDepthUsage)
    let element = SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [VoxelRenderer(), BlinnPhongMaterialRenderer()], shadows: shadows ? Shadows(intensity: 0.8) : nil)
    let texture = try renderer.render(element).texture
    let clip = projection.projectionMatrix(aspectRatio: 1) * camera.inverse * SIMD4<Float>(-1, 0, 0, 1)
    let ndc = SIMD2(clip.x, clip.y) / clip.w
    let pixel = SIMD2(Int((ndc.x + 1) / 2 * Float(size)), Int((1 - ndc.y) / 2 * Float(size)))
    var value = SIMD4<UInt8>.zero
    texture.getBytes(&value, bytesPerRow: 4, from: MTLRegionMake2D(pixel.x, pixel.y, 1, 1), mipmapLevel: 0)
    return Int(value.x) + Int(value.y) + Int(value.z)
}

@Test
@MainActor
func voxelsCastShadowsOnTheFloor() throws {
    let grid = filledGrid(size: [4, 4, 4])
    let lit = try floorBrightness(under: try voxelNode(grid, voxelSize: 0.3), shadows: false)
    let shadowed = try floorBrightness(under: try voxelNode(grid, voxelSize: 0.3), shadows: true)
    #expect(lit > 30)
    #expect(Double(shadowed) < Double(lit) * 0.6)

    let nonCaster = try voxelNode(grid, voxelSize: 0.3)
    guard case let .mesh(mesh, materials, _, _) = nonCaster.content else {
        Issue.record("The voxel node has no mesh")
        return
    }
    nonCaster.content = .mesh(mesh, materials: materials, castsShadow: false)
    #expect(try floorBrightness(under: nonCaster, shadows: true) == lit)
}

@Test
@MainActor
func voxelsShadowThemselvesButNotTheirLitFaces() throws {
    // An L: a tall column with a step in front of it, lit from above and behind, so the column shadows the step.
    var grid = VoxelGrid(size: [1, 3, 2])
    for y in 0..<3 {
        grid[[0, y, 0]] = [255, 0, 0, 255]
    }
    grid[[0, 0, 1]] = [255, 0, 0, 255]
    let node = try voxelNode(grid, voxelSize: 1)
    let root = SceneGraph.Node()
    let camera = pose(eye: [4, 1, 3], target: [0, 0, 0])
    root.addChild(SceneGraph.Node(transform: .init(storing: camera), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(45))))))
    // From above and slightly behind (-z): the top of the step (z = 0.5..1.5, y = -0.5) is behind the column.
    root.addChild(SceneGraph.Node(transform: .init(storing: pose(eye: .zero, target: [0, -1, 0.3])), content: .light(.directional())))
    root.addChild(node)
    func pixels(_ shadows: Shadows?) throws -> [SIMD4<UInt8>] {
        let renderer = try OffscreenRenderer(size: CGSize(width: 64, height: 64), colorUsage: Shadows.requiredColorUsage, depthUsage: Shadows.requiredDepthUsage)
        let texture = try renderer.render(SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [VoxelRenderer()], shadows: shadows)).texture
        var pixels = [SIMD4<UInt8>](repeating: .zero, count: 64 * 64)
        texture.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return pixels
    }
    let lit = try pixels(nil)
    let shadowed = try pixels(Shadows(intensity: 0.8))
    let red = lit.indices.filter { isRed(lit[$0]) }
    let darkened = red.filter { Int(lit[$0].z) - Int(shadowed[$0].z) > 20 }
    // The step's top is shadowed; the column's top and the faces turned from the light are not darkened further.
    #expect(!darkened.isEmpty)
    #expect(darkened.count < red.count / 2)
}

@Test
@MainActor
func pbrVoxelsLookLikeAPBRBox() throws {
    let pbr = PBRMaterialRenderer()
    let material = PBRSceneMaterial(baseColor: [1, 0, 0], metallic: 0, roughness: 0.6)
    func render(_ node: SceneGraph.Node) throws -> [SIMD4<UInt8>] {
        let root = SceneGraph.Node()
        root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .camera(Camera(projection: PerspectiveProjection(verticalAngleOfView: .degrees(45))))))
        root.addChild(SceneGraph.Node(transform: .init(translation: [0, 0, 4]), content: .light(.directional())))
        root.addChild(node)
        let renderer = try OffscreenRenderer(size: CGSize(width: 32, height: 32))
        let texture = try renderer.render(SceneGraphElement(sceneGraph: SceneGraph(root: root), aspectRatio: 1, renderers: [VoxelRenderer(pbr: pbr), pbr])).texture
        var pixels = [SIMD4<UInt8>](repeating: .zero, count: 32 * 32)
        texture.getBytes(&pixels, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 32), mipmapLevel: 0)
        return pixels
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    let voxels = SceneGraph.Node()
    // White voxels, so the material's base color is the color.
    try voxels.setVoxels(filledGrid(size: [2, 2, 2], color: [255, 255, 255, 255]), voxelSize: 1, surface: .pbr(material), device: device)
    let voxelPixels = try render(voxels)
    let meshPixels = try render(SceneGraph.Node(content: .mesh(SceneGraph.Shape.box(width: 2, height: 2, length: 2).metalMesh(), material: material)))
    let voxelCovered = covered(voxelPixels, where: isRed)
    let meshCovered = covered(meshPixels, where: isRed)
    #expect(!voxelCovered.isEmpty)
    #expect(voxelCovered.symmetricDifference(meshCovered).count <= meshCovered.count / 20)
    let center = 16 * 32 + 16
    let difference = SIMD4<Int>(truncatingIfNeeded: voxelPixels[center]) &- SIMD4<Int>(truncatingIfNeeded: meshPixels[center])
    #expect(abs(difference.x) <= 6 && abs(difference.y) <= 6 && abs(difference.z) <= 6, "\(voxelPixels[center]) vs \(meshPixels[center])")
}
