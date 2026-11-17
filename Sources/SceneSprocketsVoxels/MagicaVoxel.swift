import Foundation
import simd

// https://github.com/ephtracy/voxel-model/blob/master/MagicaVoxel-file-format-vox.txt
// https://github.com/ephtracy/voxel-model/blob/master/MagicaVoxel-file-format-vox-extension.txt

/// An error reading a MagicaVoxel .vox file.
public enum MagicaVoxelError: Error, Equatable {
    /// The file does not start with "VOX ".
    case notAVoxFile
    /// The file ends inside a chunk.
    case truncated
    /// A chunk is not as the format describes.
    case malformed(String)
    /// The file has no models.
    case noModels
}

/// The models in a MagicaVoxel .vox file and where its scene graph places them.
///
/// MagicaVoxel is z-up; the grids and transforms are y-up, with MagicaVoxel's +y toward -z. Materials (MATL) are
/// ignored, and only the first animation frame is read.
public struct MagicaVoxelScene: Sendable {
    /// One visible placement of a model.
    public struct Instance: Sendable, Equatable {
        /// The index in ``MagicaVoxelScene/models``.
        public var model: Int
        /// The name of the nearest named transform node, if any.
        public var name: String?
        /// Places the grid's center in the scene, in voxel units.
        public var transform: simd_float4x4
    }

    /// The models, in file order.
    public var models: [VoxelGrid]
    /// The visible models. Hidden nodes and hidden layers are left out. A file without a scene graph has one instance
    /// per model, all at the origin.
    public var instances: [Instance]

    /// Reads a .vox file.
    public init(data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Array("VOX ".utf8) else {
            throw MagicaVoxelError.notAVoxFile
        }
        _ = try reader.uint32() // version
        let main = try reader.chunk()
        guard main.id == "MAIN" else {
            throw MagicaVoxelError.malformed("The first chunk is \(main.id), not MAIN")
        }

        var sizes: [SIMD3<Int>] = []
        var voxelLists: [[(position: SIMD3<Int>, colorIndex: Int)]] = []
        var palette: [SIMD4<UInt8>] = []
        var graph = SceneGraphChunks()
        var children = Reader(bytes: main.children)
        while !children.isAtEnd {
            let chunk = try children.chunk()
            var content = Reader(bytes: chunk.content)
            switch chunk.id {
            case "SIZE":
                sizes.append(SIMD3(try content.int(), try content.int(), try content.int()))
            case "XYZI":
                let count = try content.int()
                voxelLists.append(try (0..<count).map { _ in
                    let bytes = try content.bytes(4)
                    return (SIMD3(Int(bytes[0]), Int(bytes[1]), Int(bytes[2])), Int(bytes[3]))
                })
            case "RGBA":
                // Entry i is color index i + 1; pad so the palette is indexed by color index.
                palette = [.zero] + (try (0..<255).map { _ in
                    let bytes = try content.bytes(4)
                    return SIMD4(bytes[0], bytes[1], bytes[2], bytes[3])
                })
            case "nTRN", "nGRP", "nSHP", "LAYR":
                try graph.read(id: chunk.id, content: &content)
            default:
                continue
            }
        }
        guard sizes.count == voxelLists.count else {
            throw MagicaVoxelError.malformed("\(sizes.count) SIZE chunks but \(voxelLists.count) XYZI chunks")
        }
        guard !sizes.isEmpty else {
            throw MagicaVoxelError.noModels
        }
        if palette.isEmpty {
            palette = magicaVoxelDefaultPalette.map { value in
                SIMD4(UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24))
            }
        }
        models = try zip(sizes, voxelLists).map { size, voxels in
            guard all(size .> 0) else {
                throw MagicaVoxelError.malformed("Model size \(size) is empty")
            }
            var grid = VoxelGrid(size: SIMD3(size.x, size.z, size.y))
            for voxel in voxels {
                guard all(voxel.position .< size), voxel.colorIndex > 0 else {
                    throw MagicaVoxelError.malformed("Voxel at \(voxel.position) with color \(voxel.colorIndex) is outside a \(size) model")
                }
                var color = palette[voxel.colorIndex]
                color.w = 255
                grid[SIMD3(voxel.position.x, voxel.position.z, size.y - 1 - voxel.position.y)] = color
            }
            return grid
        }
        if graph.isEmpty {
            instances = models.indices.map { Instance(model: $0, name: nil, transform: matrix_identity_float4x4) }
        } else {
            instances = try graph.instances(sizes: sizes)
        }
    }

    /// Reads a .vox file.
    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }
}

public extension VoxelGrid {
    /// Reads every model in a MagicaVoxel .vox file, ignoring where its scene graph places them. See
    /// ``MagicaVoxelScene``.
    static func magicaVoxelModels(data: Data) throws -> [Self] {
        try MagicaVoxelScene(data: data).models
    }

    /// Reads the first model in a MagicaVoxel .vox file. See ``MagicaVoxelScene``.
    init(magicaVoxelContentsOf url: URL) throws {
        // swiftlint:disable:next force_unwrapping - MagicaVoxelScene throws when there are no models
        self = try MagicaVoxelScene(contentsOf: url).models.first!
    }
}

// MARK: Scene graph

private struct SceneGraphChunks {
    struct Transform {
        var name: String?
        var isHidden: Bool
        var child: Int
        var layer: Int
        var matrix: simd_float4x4
    }

    var transforms: [Int: Transform] = [:]
    var groups: [Int: [Int]] = [:]
    var shapes: [Int: [Int]] = [:]
    var hiddenLayers: Set<Int> = []

    var isEmpty: Bool {
        transforms.isEmpty && groups.isEmpty && shapes.isEmpty
    }

    mutating func read(id: String, content: inout Reader) throws {
        switch id {
        case "nTRN":
            let node = try content.int()
            let attributes = try content.dictionary()
            let child = try content.int()
            _ = try content.int() // reserved
            let layer = try content.int()
            let frameCount = try content.int()
            let frames = try (0..<max(frameCount, 0)).map { _ in try content.dictionary() }
            let frame = frames.first { ($0["_f"].flatMap(Int.init) ?? 0) == 0 } ?? frames.first ?? [:]
            transforms[node] = Transform(name: attributes["_name"], isHidden: attributes["_hidden"] == "1", child: child, layer: layer, matrix: try Self.matrix(frame))
        case "nGRP":
            let node = try content.int()
            _ = try content.dictionary()
            let count = try content.int()
            groups[node] = try (0..<max(count, 0)).map { _ in try content.int() }
        case "nSHP":
            let node = try content.int()
            _ = try content.dictionary()
            let count = try content.int()
            shapes[node] = try (0..<max(count, 0)).map { _ in
                let model = try content.int()
                _ = try content.dictionary()
                return model
            }
        default: // LAYR
            let layer = try content.int()
            if try content.dictionary()["_hidden"] == "1" {
                hiddenLayers.insert(layer)
            }
        }
    }

    // A frame's rotation and translation, in MagicaVoxel's z-up space.
    static func matrix(_ frame: [String: String]) throws -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        if let rotation = frame["_r"] {
            guard let bits = Int(rotation) else {
                throw MagicaVoxelError.malformed("Rotation \(rotation) is not a number")
            }
            let first = bits & 3
            let second = (bits >> 2) & 3
            guard first != second, first < 3, second < 3 else {
                throw MagicaVoxelError.malformed("Rotation \(bits) is not a rotation")
            }
            // Row r has its non-zero entry in column `columns[r]`.
            let columns = [first, second, 3 - first - second]
            var rotationMatrix = simd_float3x3()
            for row in 0..<3 {
                rotationMatrix[columns[row]][row] = (bits >> (4 + row)) & 1 == 0 ? 1 : -1
            }
            matrix = simd_float4x4(SIMD4(rotationMatrix[0], 0), SIMD4(rotationMatrix[1], 0), SIMD4(rotationMatrix[2], 0), SIMD4(0, 0, 0, 1))
        }
        if let translation = frame["_t"] {
            let values = translation.split(separator: " ").compactMap { Float($0) }
            guard values.count == 3 else {
                throw MagicaVoxelError.malformed("Translation \(translation) is not three numbers")
            }
            matrix.columns.3 = SIMD4(values[0], values[1], values[2], 1)
        }
        return matrix
    }

    func instances(sizes: [SIMD3<Int>]) throws -> [MagicaVoxelScene.Instance] {
        // z-up (x, y, z) to y-up (x, z, -y).
        let toYUp = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1))
        var instances: [MagicaVoxelScene.Instance] = []
        var visited: Set<Int> = []
        func visit(_ node: Int, matrix: simd_float4x4, name: String?) throws {
            guard visited.insert(node).inserted else {
                throw MagicaVoxelError.malformed("Scene node \(node) is in the graph twice")
            }
            if let transform = transforms[node] {
                guard !transform.isHidden, !hiddenLayers.contains(transform.layer) else {
                    return
                }
                try visit(transform.child, matrix: matrix * transform.matrix, name: transform.name ?? name)
            } else if let children = groups[node] {
                for child in children {
                    try visit(child, matrix: matrix, name: name)
                }
            } else if let models = shapes[node] {
                for model in models.prefix(1) {
                    guard sizes.indices.contains(model) else {
                        throw MagicaVoxelError.malformed("Shape node \(node) uses missing model \(model)")
                    }
                    // MagicaVoxel's pivot is the voxel at size / 2, rounded down; the grid's is its exact center.
                    let size = SIMD3<Float>(sizes[model])
                    let pivotOffset = size / 2 - (size / 2).rounded(.down)
                    let centered = matrix * simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(pivotOffset, 1))
                    instances.append(.init(model: model, name: name, transform: toYUp * centered * toYUp.transpose))
                }
            } else {
                throw MagicaVoxelError.malformed("Scene node \(node) is missing")
            }
        }
        try visit(0, matrix: matrix_identity_float4x4, name: nil)
        return instances
    }
}

// MARK: Reading

private struct Reader {
    let bytes: [UInt8]
    var offset = 0

    var isAtEnd: Bool {
        offset >= bytes.count
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - offset else {
            throw MagicaVoxelError.truncated
        }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func uint32() throws -> UInt32 {
        try bytes(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func int() throws -> Int {
        Int(Int32(bitPattern: try uint32()))
    }

    mutating func string() throws -> String {
        String(bytes: try bytes(try int()), encoding: .utf8) ?? ""
    }

    mutating func dictionary() throws -> [String: String] {
        var result: [String: String] = [:]
        for _ in 0..<max(try int(), 0) {
            let key = try string()
            result[key] = try string()
        }
        return result
    }

    mutating func chunk() throws -> (id: String, content: [UInt8], children: [UInt8]) {
        let id = String(bytes: try bytes(4), encoding: .ascii) ?? ""
        let contentSize = try int()
        let childrenSize = try int()
        return (id, try bytes(contentSize), try bytes(childrenSize))
    }
}
