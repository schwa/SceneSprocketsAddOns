import CoreGraphics
import Foundation
import GeometryLite3D
import Metal
import MetalSprockets
import SceneSprockets
import SceneSprocketsBlinnPhong
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
func magicaVoxelWithoutPaletteIsGray() throws {
    let grid = try #require(try VoxelGrid.magicaVoxelModels(data: voxFile(palette: false)).first)
    #expect(grid[[0, 0, 2]] == [200, 200, 200, 255])
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
