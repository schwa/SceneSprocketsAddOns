import Metal
import MetalSprockets
import SceneSprocketsTerrainShaders
import simd

/// Renders a `TerrainData` as a mesh tessellated by a concurrent binary tree with longest-edge bisection. It only reads
/// the data: heights from the clipmap levels and the property maps. The tree covers the outer level.
public final class TerrainTessellator {
    /// The terrain this renderer draws.
    public let data: TerrainData
    let maxDepth = Int(CBT_MAX_DEPTH)
    /// libcbt's bit-packed tree: sum-reduction levels and the leaf bitfield in one array.
    let heap: MTLBuffer
    /// One bit per reduction-prepass group whose leaf bits changed since it was last reduced.
    let dirtyGroups: MTLBuffer
    let visibleIDs: MTLBuffer
    let arguments: MTLBuffer
    /// Index buffers for meshlet subdivision levels 0...5, sharing vertices between a leaf's triangles.
    let meshletIndices: [MTLBuffer]
    let blendNoise: MTLTexture
    let detailNoise: MTLTexture
    /// The outer level's size and origin when the tree was last updated; when they change, the tree is laid over a
    /// different square and runs extra passes to catch up.
    var lastOuterLevel: (size: Float, origin: SIMD2<Float>)?

    let reduceWords: ComputeKernel
    let reduceLevel: ComputeKernel
    let prepareArguments: ComputeKernel
    let update: ComputeKernel
    let skyVertex: VertexShader
    let skyFragment: FragmentShader
    let mapFragment: FragmentShader
    let mapContourFragment: FragmentShader
    let terrainVertex: VertexShader
    let terrainFragment: FragmentShader
    let terrainWireframeFragment: FragmentShader
    let terrainDebugFragment: FragmentShader

    private var frameIndex = 0

    public init(data: TerrainData) throws {
        let device = data.device
        let library = try ShaderLibrary(bundle: .sceneSprocketsTerrainShaders(), device: device)
        self.data = data
        blendNoise = try Heightmap.blendNoise(device: device, library: library)
        detailNoise = try Heightmap.detailNoise(device: device, library: library)
        reduceWords = try library.cbt_reduce_words
        reduceLevel = try library.cbt_reduce_level
        prepareArguments = try library.cbt_prepare_arguments
        update = try library.cbt_update
        skyVertex = try library.sky_vertex
        skyFragment = try library.sky_fragment
        mapFragment = try library.map_fragment
        mapContourFragment = try library.map_contour_fragment
        terrainVertex = try library.terrain_vertex
        terrainFragment = try library.terrain_fragment
        terrainWireframeFragment = try library.terrain_fragment_wireframe
        terrainDebugFragment = try library.terrain_fragment_debug

        func makeBuffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw TerrainError.allocationFailed(label)
            }
            buffer.label = label
            memset(buffer.contents(), 0, length)
            return buffer
        }
        // cbt__HeapByteSize: 2^(D-1) bytes. Matches CBT_HEAP_WORD_COUNT, which Swift can't import.
        heap = try makeBuffer(1 << (maxDepth - 1), "CBT Heap")
        visibleIDs = try makeBuffer(Int(CBT_MAX_LEAVES) * 4, "CBT Visible IDs")
        arguments = try makeBuffer(Int(CBT_ARGS_COUNT) * 4, "CBT Arguments")
        meshletIndices = try (0 ... 5).map { level in
            let indices = Self.meshletIndices(subdivision: level)
            guard let buffer = device.makeBuffer(bytes: indices, length: indices.count * 2, options: .storageModeShared) else {
                throw TerrainError.allocationFailed("Meshlet indices")
            }
            buffer.label = "Meshlet Indices \(level)"
            return buffer
        }

        // cbt_CreateAtDepth(D, 1): heap[0] records the max depth; the two base triangles (nodes 2 and 3) are leaves.
        // Everything is reduced on the first frame.
        dirtyGroups = try makeBuffer((1 << (maxDepth - Int(CBT_PREPASS_GROUP_SHIFT))) / 8, "CBT Dirty Groups")
        memset(dirtyGroups.contents(), 0xFF, dirtyGroups.length)

        let words = heap.contents().assumingMemoryBound(to: UInt32.self)
        words[0] = 1 << UInt32(maxDepth)
        for node in [2, 3] {
            let bit = Self.nodeBitID(node << (maxDepth - 1), depth: maxDepth, maxDepth: maxDepth)
            words[bit >> 5] |= 1 << UInt32(bit & 31)
        }
    }

    /// Triangles of an n x n meshlet (n = 2^subdivision) as lattice-vertex indices. Row r lies between a + b = r and
    /// a + b = r + 1 and holds 2r + 1 triangles, in the same order and winding as the non-indexed layout.
    static func meshletIndices(subdivision: Int) -> [UInt16] {
        let n = 1 << subdivision
        func index(_ a: Int, _ b: Int) -> UInt16 {
            let s = a + b
            return UInt16(s * (s + 1) / 2 + a)
        }
        var indices: [UInt16] = []
        for row in 0 ..< n {
            for k in 0 ..< 2 * row + 1 {
                let m = k / 2
                if k.isMultiple(of: 2) {
                    indices += [index(m, row - m), index(m, row + 1 - m), index(m + 1, row - m)]
                } else {
                    indices += [index(m, row - m), index(m + 1, row - m), index(m + 1, row - m - 1)]
                }
            }
        }
        return indices
    }

    static func nodeBitID(_ id: Int, depth: Int, maxDepth: Int) -> Int {
        (2 << depth) + id * (1 + maxDepth - depth)
    }

    /// cbt_HeapRead on the CPU. Read without synchronization.
    func heapRead(_ id: Int) -> Int {
        let words = heap.contents().assumingMemoryBound(to: UInt32.self)
        let depth = Int.bitWidth - 1 - id.leadingZeroBitCount
        let bitCount = maxDepth - depth + 1
        var value = 0
        for index in 0 ..< bitCount {
            let bit = Self.nodeBitID(id, depth: depth, maxDepth: maxDepth) + index
            value |= Int((words[bit >> 5] >> UInt32(bit & 31)) & 1) << index
        }
        return value
    }

    /// Leaf count from the most recent reduction. Read without synchronization; for display only.
    public var leafCount: Int {
        Int(arguments.contents().assumingMemoryBound(to: UInt32.self)[Int(CBT_ARGS_STATS_LEAVES)])
    }

    public var visibleCount: Int {
        Int(arguments.contents().assumingMemoryBound(to: UInt32.self)[Int(CBT_ARGS_STATS_VISIBLE)])
    }

    /// Alternates split and merge passes each frame.
    func nextUpdateMode(frozen: Bool) -> UInt32 {
        defer { frameIndex += 1 }
        return frozen ? 2 : UInt32(frameIndex & 1)
    }

    /// One CBT update pass: split or merge (uniforms.updateMode), culling and the visible leaf list.
    @ElementBuilder
    func updatePass(uniforms: TerrainUniforms) throws -> some Element {
        let wordCount = (1 << maxDepth) / 32
        // The prepass fills depths D-1 ... D-13. Bottom level of each later dispatch: 11 (11...3), 2 (2...0).
        let reductionLevels = Array(stride(from: maxDepth - 14, through: 0, by: -9))
        let leafDispatchOffset = Int(CBT_ARGS_DISPATCH) * 4

        try ComputePass(label: "CBT") {
            // Earlier frames read these buffers in vertex/fragment stages and wrote the leaf bits.
            QueueBarrier(after: [.dispatch, .vertex, .fragment], before: .dispatch)

            try ComputePipeline(label: "Reduce Words", computeKernel: reduceWords) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: wordCount, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            }
            .parameter("heap", buffer: heap)
            .parameter("dirty", buffer: dirtyGroups)
            EncoderBarrier(after: .dispatch, before: .dispatch)

            try ComputePipeline(label: "Reduce Level", computeKernel: reduceLevel) {
                ForEach(reductionLevels, id: \.self) { level in
                    // Each dispatch fills levels `level` down to `level - log2(group)`.
                    let group = min(256, 1 << level)
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: 1 << level, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: group, height: 1, depth: 1)
                    )
                    .parameter("level", value: UInt32(level))
                    EncoderBarrier(after: .dispatch, before: .dispatch)
                }
            }
            .parameter("heap", buffer: heap)

            try ComputePipeline(label: "Prepare Arguments", computeKernel: prepareArguments) {
                try ComputeDispatch(threadsPerGrid: MTLSize(width: 1, height: 1, depth: 1))
            }
            .parameter("arguments", buffer: arguments)
            .parameter("heap", buffer: heap)
            .parameter("uniforms", value: uniforms)
            EncoderBarrier(after: .dispatch, before: .dispatch)

            try ComputePipeline(label: "Update", computeKernel: update) {
                try ComputeDispatch(indirectBuffer: arguments, indirectBufferOffset: leafDispatchOffset, threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            }
            .parameter("visibleIDs", buffer: visibleIDs)
            .parameter("arguments", buffer: arguments)
            .parameter("uniforms", value: uniforms)
            .parameter("heights", texture: data.levels[0].heights)
            .parameter("moments", texture: data.levels[0].moments)
            .parameter("farHeights", texture: data.outerLevel.heights)
            .parameter("farMoments", texture: data.outerLevel.moments)
            .parameter("heap", buffer: heap)
            .parameter("dirty", buffer: dirtyGroups)
        }
    }

    /// Draws the terrain. Put it in a render pass with a depth32Float attachment cleared to 0: depth is reversed (near is
    /// 1) and this pipeline writes depth with `.greater`. Needs `updateWork` earlier in the same frame.
    @ElementBuilder
    public func terrainWork(uniforms: TerrainUniforms, style: TerrainStyle) throws -> some Element {
        let prepared = prepared(style)
        let drawOffset = UInt64(Int(CBT_ARGS_DRAW) * 4)
        let arguments = arguments
        let indices = meshletIndices[Int(uniforms.meshletSubdivision)]
        // The update pass wrote the draw arguments and visible leaf list.
        QueueBarrier(after: .dispatch, before: .vertex)

        try RenderPipeline(label: "Terrain", vertexShader: terrainVertex, fragmentShader: terrainFragment(for: uniforms)) {
            Draw { encoder in
                // A heightfield seen from above: back faces are always hidden by front faces.
                encoder.setFrontFacing(.counterClockwise)
                encoder.setCullMode(.back)
                encoder.drawIndexedPrimitives(
                    primitiveType: .triangle,
                    indexType: .uint16,
                    indexBuffer: indices.gpuAddress,
                    indexBufferLength: indices.length,
                    indirectBuffer: arguments.gpuAddress + drawOffset
                )
            }
        }
        .useResource(indices, usage: .read, stages: .vertex)
        .parameter("uniforms", value: uniforms)
        .parameter("material", value: prepared.material)
        .parameter("visibleIDs", buffer: visibleIDs)
        .parameter("heights", texture: data.levels[0].heights)
        .parameter("layers", values: Self.nonEmpty(prepared.layers))
        .parameter("blendNoise", texture: blendNoise)
        .parameter("moments", texture: data.levels[0].moments)
        .parameter("colorMap", texture: data.color.texture)
        .parameter("maskMap", texture: data.mask.texture)
        .parameter("detailNoise", texture: detailNoise)
        .parameter("farHeights", texture: data.outerLevel.heights)
        .parameter("farMoments", texture: data.outerLevel.moments)
        .useResource(arguments, usage: .read, stages: .vertex)
        .depthCompare(function: .greater, writes: true)
    }

    /// The built-in sky, drawn only where depth still has its clear value (0), so it goes after everything else in the
    /// same render pass. Leave it out to draw your own sky.
    public func skyWork(uniforms: TerrainUniforms, style: TerrainStyle) throws -> some Element {
        try RenderPipeline(label: "Sky", vertexShader: skyVertex, fragmentShader: skyFragment) {
            Draw { encoder in
                encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        .parameter("uniforms", value: uniforms)
        .parameter("material", value: prepared(style).material)
        .depthCompare(function: .equal, writes: false)
    }
}

extension TerrainTessellator {
    /// Top-down map of clipmap level 0 filling the render target: shaded with `style` and lit from a fixed direction,
    /// or, with `contoursOnly`, plain contour lines on paper.
    /// - Parameter contourInterval: Meters between contour lines on the map, independent of the main view; nil uses the
    ///   style's interval. 0 turns them off.
    @ElementBuilder
    public func mapWork(style: TerrainStyle, heightExaggeration: Float = 1, contourInterval: Float? = nil, contoursOnly: Bool = false) throws -> some Element {
        let prepared = prepared(style)
        let material = {
            var material = prepared.material
            material.contourInterval = contourInterval ?? material.contourInterval
            return material
        }()
        let uniforms = {
            var uniforms = TerrainUniforms()
            uniforms.detailSize = data.levels[0].size
            uniforms.detailOrigin = data.levels[0].origin
            uniforms.heightScale = data.heightScale * heightExaggeration
            uniforms.heightExaggeration = heightExaggeration
            uniforms.hasHeightFloor = data.heightFloor == nil ? 0 : 1
            uniforms.heightFloor = data.heightFloor ?? 0
            return uniforms
        }()
        if contoursOnly {
            // Contour lines are drawn at true altitude, so exaggeration doesn't matter here.
            try RenderPass(label: "Mini-map") {
                try RenderPipeline(label: "Contour Map", vertexShader: skyVertex, fragmentShader: mapContourFragment) {
                    Draw { encoder in
                        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                }
                .parameter("uniforms", value: uniforms)
                .parameter("material", value: material)
                .parameter("moments", texture: data.levels[0].moments)
            }
        } else {
            try RenderPass(label: "Mini-map") {
                try RenderPipeline(label: "Map", vertexShader: skyVertex, fragmentShader: mapFragment) {
                    Draw { encoder in
                        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
                    }
                }
                .parameter("uniforms", value: uniforms)
                .parameter("material", value: material)
                .parameter("layers", values: Self.nonEmpty(prepared.layers))
                .parameter("moments", texture: data.levels[0].moments)
                .parameter("blendNoise", texture: blendNoise)
                .parameter("colorMap", texture: data.color.texture)
                .parameter("maskMap", texture: data.mask.texture)
            }
        }
    }
}

extension TerrainTessellator {
    /// `style` with its derived fields filled in and the color and mask placements of this renderer's data.
    func prepared(_ style: TerrainStyle) -> (material: TerrainMaterial, layers: [TerrainLayer]) {
        var prepared = style.prepared()
        prepared.material.colorMapPlacement = data.color.placement
        prepared.material.maskMapPlacement = data.mask.placement
        return prepared
    }

    /// Debug modes take precedence over wireframe.
    func terrainFragment(for uniforms: TerrainUniforms) -> FragmentShader {
        if uniforms.debugMode != 0 {
            return terrainDebugFragment
        }
        return uniforms.wireframe != 0 ? terrainWireframeFragment : terrainFragment
    }

    /// GPU buffers can't be empty; with no layers, bind one unused entry (the material's layerCount stays 0).
    static func nonEmpty(_ layers: [TerrainLayer]) -> [TerrainLayer] {
        layers.isEmpty ? [TerrainLayer()] : layers
    }
}

enum TerrainError: Error {
    case allocationFailed(String)
}
