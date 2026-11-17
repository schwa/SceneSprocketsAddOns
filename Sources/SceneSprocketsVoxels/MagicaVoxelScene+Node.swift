import GeometryLite3D
import Metal
import SceneSprockets
import SceneSprocketsBlinnPhong
import simd

public extension MagicaVoxelScene {
    /// A node with one child per instance, placed as in the file. Instances of the same model share one texture.
    func makeNode(voxelSize: Float = 1, surface: VoxelMaterial.Surface = .blinnPhong(BlinnPhongSceneMaterial(color: [1, 1, 1])), device: MTLDevice) throws -> SceneGraph.Node {
        let materials = try models.map { VoxelMaterial(texture: try $0.makeTexture(device: device), voxelSize: voxelSize, surface: surface) }
        let root = SceneGraph.Node(label: "MagicaVoxel Scene")
        for instance in instances {
            var matrix = instance.transform
            matrix.columns.3 = SIMD4(SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) * voxelSize, 1)
            let node = SceneGraph.Node(label: instance.name ?? "Model \(instance.model)")
            node.transform = .init(storing: matrix)
            node.setVoxels(materials[instance.model], device: device)
            root.addChild(node)
        }
        return root
    }
}
