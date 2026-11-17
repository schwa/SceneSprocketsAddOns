import Foundation
import simd

// https://github.com/ephtracy/voxel-model/blob/master/MagicaVoxel-file-format-vox.txt

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

public extension VoxelGrid {
    /// Reads every model in a MagicaVoxel .vox file. The scene graph in the file (transforms, groups, layers) and its
    /// materials are ignored.
    ///
    /// MagicaVoxel is z-up; the grids are y-up, with MagicaVoxel's +y toward -z.
    static func magicaVoxelModels(data: Data) throws -> [Self] {
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
        var children = Reader(bytes: main.children)
        while !children.isAtEnd {
            let chunk = try children.chunk()
            var content = Reader(bytes: chunk.content)
            switch chunk.id {
            case "SIZE":
                sizes.append(SIMD3(Int(try content.uint32()), Int(try content.uint32()), Int(try content.uint32())))
            case "XYZI":
                let count = Int(try content.uint32())
                voxelLists.append(try (0..<count).map { _ in
                    let bytes = try content.bytes(4)
                    return (SIMD3(Int(bytes[0]), Int(bytes[1]), Int(bytes[2])), Int(bytes[3]))
                })
            case "RGBA":
                palette = try (0..<256).map { _ in
                    let bytes = try content.bytes(4)
                    return SIMD4(bytes[0], bytes[1], bytes[2], bytes[3])
                }
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
        return try zip(sizes, voxelLists).map { size, voxels in
            guard all(size .> 0) else {
                throw MagicaVoxelError.malformed("Model size \(size) is empty")
            }
            var grid = VoxelGrid(size: SIMD3(size.x, size.z, size.y))
            for voxel in voxels {
                guard all(voxel.position .< size), voxel.colorIndex > 0 else {
                    throw MagicaVoxelError.malformed("Voxel at \(voxel.position) with color \(voxel.colorIndex) is outside a \(size) model")
                }
                // Color index i is palette entry i - 1. Without a palette the voxels are gray.
                var color = palette.isEmpty ? SIMD4(200, 200, 200, 255) : palette[voxel.colorIndex - 1]
                color.w = 255
                grid[SIMD3(voxel.position.x, voxel.position.z, size.y - 1 - voxel.position.y)] = color
            }
            return grid
        }
    }

    /// Reads the first model in a MagicaVoxel .vox file. See ``magicaVoxelModels(data:)``.
    init(magicaVoxelContentsOf url: URL) throws {
        // swiftlint:disable:next force_unwrapping - magicaVoxelModels throws when there are none
        self = try Self.magicaVoxelModels(data: Data(contentsOf: url)).first!
    }
}

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

    mutating func chunk() throws -> (id: String, content: [UInt8], children: [UInt8]) {
        let id = String(bytes: try bytes(4), encoding: .ascii) ?? ""
        let contentSize = Int(try uint32())
        let childrenSize = Int(try uint32())
        return (id, try bytes(contentSize), try bytes(childrenSize))
    }
}
