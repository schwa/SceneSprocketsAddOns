import CoreGraphics
import Metal
import MetalSprockets
@testable import SceneSprocketsTerrain
import SceneSprocketsTerrainShaders
import simd
import Testing

@Suite(.serialized)
struct TerrainTreeTests {
    @Test func subdivisionStaysConforming() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device)
        let runner = try Runner(configuration: MetalContextConfiguration(device: device))
        let camera = FlyCamera()
        camera.position = [0, 600, 0]

        for frame in 0 ..< 80 {
            // Move the camera partway through so merges happen too.
            if frame == 50 {
                camera.position = [4_000, 900, 4_000]
                camera.yaw = 2
            }
            let uniforms = makeUniforms(terrain: terrain, camera: camera)
            try runner.run(try terrain.tessellator.updatePass(uniforms: uniforms))
        }
        // One more reduction so the heap matches the final bits.
        var uniforms = makeUniforms(terrain: terrain, camera: camera)
        uniforms.updateMode = 2
        try runner.run(try terrain.tessellator.updatePass(uniforms: uniforms))

        let leaves = cpuLeaves(terrain)
        #expect(leaves.count == terrain.leafCount)
        #expect(leaves.count > 1_000)

        let area = leaves.reduce(0.0) { $0 + pow(0.5, Double(depth($1))) }
        #expect(abs(area - 1) < 1e-9)

        // Geometry from a port of libleb's matrix decode, independent of the shader's decodeTriangle.
        let triangles = leaves.map(libLEBTriangle)
        let geometricArea = triangles.reduce(0.0) { sum, t in
            sum + abs(simd_cross(SIMD3(t[1] - t[0], 0), SIMD3(t[2] - t[0], 0)).z) / 2
        }
        #expect(abs(geometricArea - 1) < 1e-9)

        // The shader's decode must produce the same vertex set as libleb.
        let mismatches = leaves.filter { Set(shaderTriangle($0)) != Set(libLEBTriangle($0)) }
        #expect(mismatches.isEmpty)

        // Conforming: no edge midpoint is a vertex of another triangle (a T-junction).
        let vertices = Set(triangles.flatMap(\.self))
        var tJunctions = 0
        for t in triangles {
            for (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])] where vertices.contains((a + b) / 2) {
                tJunctions += 1
            }
        }
        #expect(tJunctions == 0)
    }

    private func libLEBTriangle(_ id: UInt32) -> [SIMD2<Double>] {
        func bit(_ index: Int) -> Double {
            Double((id >> UInt32(index)) & 1)
        }
        let depth = depth(id)
        var b = bit(max(0, depth - 1))
        var c = 1 - b
        var transform = simd_double3x3(rows: [[c, 0, b], [b, c, b], [b, 0, c]])
        var index = depth - 2
        while index >= 0 {
            b = bit(index)
            c = 1 - b
            transform = simd_double3x3(rows: [[c, b, 0], [0.5, 0, 0.5], [0, c, b]]) * transform
            index -= 1
        }
        let mirror = Double((depth ^ 1) & 1)
        let winding = simd_double3x3(rows: [[1 - mirror, 0, mirror], [0, 1, 0], [mirror, 0, 1 - mirror]])
        transform = winding * transform
        let x = transform * SIMD3<Double>(0, 0, 1)
        let y = transform * SIMD3<Double>(1, 0, 0)
        return [SIMD2(x.x, y.x), SIMD2(x.y, y.y), SIMD2(x.z, y.z)]
    }

    // Swift copy of decodeTriangle in TerrainCommon.h.
    private func shaderTriangle(_ id: UInt32) -> [SIMD2<Double>] {
        let depth = depth(id)
        var t: [SIMD2<Double>] = (id >> UInt32(depth - 1)) & 1 == 0 ? [[0, 1], [0, 0], [1, 0]] : [[1, 0], [1, 1], [0, 1]]
        var index = depth - 2
        while index >= 0 {
            let mid = (t[0] + t[2]) / 2
            t = (id >> UInt32(index)) & 1 == 0 ? [t[0], mid, t[1]] : [t[1], mid, t[2]]
            index -= 1
        }
        return t
    }

    // A square 16-bit linear gray image, row-major.
    private func grayImage(_ pixels: [UInt16], width: Int) throws -> CGImage {
        var pixels = pixels
        let space = try #require(CGColorSpace(name: CGColorSpace.linearGray))
        let image = pixels.withUnsafeMutableBytes { bytes in
            CGContext(
                data: bytes.baseAddress,
                width: width,
                height: width,
                bitsPerComponent: 16,
                bytesPerRow: width * 2,
                space: space,
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            )?.makeImage()
        }
        return try #require(image)
    }

    @Test func imageHeightmapStoresMoments() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // 4x4 16-bit grayscale, values 0, 1/15, ..., 1 in row-major order.
        let image = try grayImage((0 ..< 16).map { UInt16($0 * 4_369) }, width: 4)
        let terrain = try Terrain(device: device, heightSource: .image(image), heightScale: 15)

        func level(_ index: Int) -> [SIMD2<Float>] {
            let width = max(1, 4 >> index)
            var values = [SIMD2<Float>](repeating: .zero, count: width * width)
            values.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return
                }
                terrain.levels[0].moments.getBytes(baseAddress, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, width), mipmapLevel: index)
            }
            return values
        }
        let base = level(0)
        for (index, value) in base.enumerated() {
            #expect(abs(value.x - Float(index)) < 0.01)
            #expect(abs(value.y - Float(index * index)) < 0.1)
        }
        // Level 1 texel 0 averages heights 0, 1, 4, 5: mean 2.5, mean of squares 10.5.
        let first = level(1)[0]
        #expect(abs(first.x - 2.5) < 0.01)
        #expect(abs(first.y - 10.5) < 0.1)
        // Top level holds the mean and mean square of the whole map.
        let top = level(2)[0]
        #expect(abs(top.x - 7.5) < 0.01)
        #expect(abs(top.y - 77.5) < 0.1)
    }

    @Test func cameraStaysAboveGround() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // 2x2 heights 0, 1/3, 2/3, 1 (row-major), scaled to 0...300 m over a 1000 m world.
        let image = try grayImage([0, 21_845, 43_690, 65_535], width: 2)
        let terrain = try Terrain(device: device, heightSource: .image(image), worldSize: 1_000, heightScale: 300)

        // Texel centers are at x/z = -250 and +250. Between them the height is bilinear; beyond them it clamps.
        #expect(abs(terrain.height(at: [-250, -250]) - 0) < 0.01)
        #expect(abs(terrain.height(at: [250, -250]) - 100) < 0.01)
        #expect(abs(terrain.height(at: [-250, 250]) - 200) < 0.01)
        #expect(abs(terrain.height(at: [0, 0]) - 150) < 0.01)
        #expect(abs(terrain.height(at: [10_000, 10_000]) - 300) < 0.01)

        var below = matrix_identity_float4x4
        below.columns.3 = [0, 50, 0, 1]
        #expect(terrain.keepingAboveGround(below, clearance: 2).columns.3.y == 152)
        var above = matrix_identity_float4x4
        above.columns.3 = [0, 500, 0, 1]
        #expect(terrain.keepingAboveGround(above, clearance: 2) == above)
    }

    @Test func flatTerrainDoesNotSplit() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let image = try grayImage([UInt16](repeating: 30_000, count: 64 * 64), width: 64)
        let runner = try Runner(configuration: MetalContextConfiguration(device: device))
        let camera = FlyCamera()
        camera.position = [0, 900, 0]
        camera.pitch = -1

        func settle(minHeightVariance: Float) throws -> Int {
            let terrain = try Terrain(device: device, heightSource: .image(image))
            for _ in 0 ..< 40 {
                var uniforms = makeUniforms(terrain: terrain, camera: camera)
                uniforms.minHeightVariance = minHeightVariance
                try runner.run(try terrain.tessellator.updatePass(uniforms: uniforms))
            }
            return terrain.leafCount
        }
        #expect(try settle(minHeightVariance: 1) == 2)
        #expect(try settle(minHeightVariance: 0) > 100)
    }

    @Test func leafSubdivisionShrinksTree() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let runner = try Runner(configuration: MetalContextConfiguration(device: device))
        let camera = FlyCamera()
        camera.position = [0, 600, 0]

        func settle(subdivision: UInt32) throws -> (leaves: Int, arguments: [UInt32]) {
            let terrain = try Terrain(device: device)
            for _ in 0 ..< 60 {
                var uniforms = makeUniforms(terrain: terrain, camera: camera)
                uniforms.meshletSubdivision = subdivision
                try runner.run(try terrain.tessellator.updatePass(uniforms: uniforms))
            }
            let arguments = terrain.tessellator.arguments.contents().assumingMemoryBound(to: UInt32.self)
            let draw = (0 ..< 4).map { arguments[Int(CBT_ARGS_DRAW) + $0] }
            return (terrain.leafCount, draw)
        }

        let flat = try settle(subdivision: 0)
        let subdivided = try settle(subdivision: 3)
        #expect(subdivided.leaves * 16 < flat.leaves)
        #expect(flat.arguments[0] == 3)
        #expect(subdivided.arguments[0] == 3 * 64)
        #expect(subdivided.arguments[1] > 0)
        #expect(Int(subdivided.arguments[1]) <= subdivided.leaves)
    }

    private func makeUniforms(terrain: Terrain, camera: FlyCamera) -> TerrainUniforms {
        let viewProjection = camera.projectionMatrix(aspect: 16 / 9) * camera.viewMatrix
        let rows = viewProjection.transpose
        let planes = [rows.columns.3 + rows.columns.0, rows.columns.3 - rows.columns.0, rows.columns.3 + rows.columns.1, rows.columns.3 - rows.columns.1]
            .map { $0 / length(SIMD3($0.x, $0.y, $0.z)) }
        var uniforms = TerrainUniforms()
        uniforms.viewProjection = viewProjection
        uniforms.inverseViewProjection = viewProjection.inverse
        uniforms.frustumPlanes = (planes[0], planes[1], planes[2], planes[3])
        uniforms.cameraPosition = camera.position
        uniforms.cbtSize = terrain.outerLevel.size
        uniforms.detailSize = terrain.levels[0].size
        uniforms.heightScale = terrain.heightScale
        uniforms.heightExaggeration = 1
        uniforms.targetEdgePixels = 10
        uniforms.projectionScale = 540 / tan(camera.fieldOfView / 2)
        uniforms.updateMode = terrain.tessellator.nextUpdateMode(frozen: false)
        return uniforms
    }

    // MARK: - CPU mirror of the shader-side tree

    private func depth(_ id: UInt32) -> Int {
        31 - id.leadingZeroBitCount
    }

    private func heapRead(_ terrain: Terrain, _ id: UInt32) -> UInt32 {
        UInt32(terrain.tessellator.heapRead(Int(id)))
    }

    private func leafBit(_ terrain: Terrain, _ id: UInt32) -> Bool {
        let ceil = Int(id) << (terrain.tessellator.maxDepth - depth(id))
        let bit = TerrainTessellator.nodeBitID(ceil, depth: terrain.tessellator.maxDepth, maxDepth: terrain.tessellator.maxDepth)
        let words = terrain.tessellator.heap.contents().assumingMemoryBound(to: UInt32.self)
        return (words[bit >> 5] >> UInt32(bit & 31)) & 1 == 1
    }

    /// Walks the tree like cbt_DecodeNode and checks the GPU reduction: each count is the sum of its children's,
    /// and every leaf has its bit set in the bitfield.
    private func cpuLeaves(_ terrain: Terrain) -> [UInt32] {
        var leaves: [UInt32] = []
        var stack: [UInt32] = [1]
        while let id = stack.popLast() {
            let count = heapRead(terrain, id)
            if count <= 1 {
                #expect(count == 1 && leafBit(terrain, id), "node \(id)")
                leaves.append(id)
            } else {
                #expect(count == heapRead(terrain, 2 * id) + heapRead(terrain, 2 * id + 1), "node \(id)")
                stack += [2 * id + 1, 2 * id]
            }
        }
        return leaves
    }

    @Test func streamedTerrainReachesFarAway() throws {
        // #21: the visible world ended 6-8 km away, at the edge of the single 16 km heightmap.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
        for x in stride(from: Float(0), through: 40_000, by: 500) {
            let position = SIMD3<Float>(x, 1_000, 0)
            try terrain.stream(around: position)
            #expect(terrain.viewDistance(from: position) >= 20_000, "at x = \(x)")
        }
    }

    @Test func climbingRevealsMoreTerrain() throws {
        // #22: the drawn square stayed the same size at any altitude, so its edges showed from high up.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: .procedural(size: 1_024))
        for altitude in [Float(2_000), 10_000, 40_000, 10_000, 2_000] {
            let position = SIMD3<Float>(3_000, altitude, -1_000)
            try terrain.stream(around: position)
            #expect(terrain.viewDistance(from: position) >= 10 * altitude, "at altitude \(altitude)")
        }
    }

    @Test func streamedHeightmapsMatchAFreshBake() throws {
        // Chunks baked while flying must hold the same heights as baking the final levels from scratch.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let flown = try Terrain(device: device, heightSource: .procedural(size: 1_024))
        var position = SIMD3<Float>(0, 1_000, 0)
        var heading: Float = 0.3
        for step in 0 ..< 400 {
            heading += step.isMultiple(of: 50) ? 1.3 : 0.01
            position += SIMD3(cos(heading), 0, sin(heading)) * 120
            try flown.stream(around: position)
        }
        let fresh = try Terrain(device: device, heightSource: .procedural(size: 1_024))
        // Far away and back: both moves exceed the levels, so the final levels are baked whole.
        try fresh.stream(around: position + SIMD3(1_000_000, 0, 0))
        try fresh.stream(around: position)
        // The levels may sit a chunk apart (hysteresis), so compare heights at world points inside both.
        // Each baked region measures its points from its own origin (#29), so the same point can differ by float
        // rounding depending on which region baked it; that stays far below anything visible.
        var worst: Float = 0
        for z in stride(from: Float(-5_000), through: 5_000, by: 37) {
            for x in stride(from: Float(-5_000), through: 5_000, by: 37) {
                let xz = SIMD2(position.x + x, position.z + z)
                worst = max(worst, abs(flown.height(at: xz) - fresh.height(at: xz)))
            }
        }
        #expect(worst < 0.05, "worst difference \(worst) m")
    }

    @Test func sanFranciscoBayHeightmapLoadsAtTrueScale() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: try .sanFranciscoBay())
        #expect(terrain.levels[0].moments.width == 2_048)
        var highest: Float = 0
        for z in stride(from: Float(-8_000), through: 8_000, by: 100) {
            for x in stride(from: Float(-8_000), through: 8_000, by: 100) {
                highest = max(highest, terrain.height(at: SIMD2(x, z)))
            }
        }
        // The highest point in the area is about 341 m; a 100 m grid lands a little below it.
        #expect(highest > 280 && highest < 345, "highest \(highest)")
        // The middle of the Golden Gate strait (about 37.81 N, 122.48 W) is water, clipped to 0.
        #expect(terrain.height(at: SIMD2(-1_600, 1_300)) < 1)
    }

    @Test func coastlinesDoNotFollowTheTexelGrid() throws {
        // #34: with the bay floor clipped to 0 in the data, bilinear filtering only rises above 0 inside texel cells that
        // have a land corner, so the coastline runs along texel-center lines and diagonal shores become staircases.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let terrain = try Terrain(device: device, heightSource: try .sanFranciscoBay())
        let texelMeters = terrain.levels[0].size / Float(terrain.levels[0].resolution)
        var crossings: [Float] = []
        for z in stride(from: Float(-7_000), through: 7_000, by: 141) {
            var x: Float = -8_000
            var wasLand = terrain.height(at: SIMD2(x, z)) > 0.01
            while x < 8_000 {
                let next = x + texelMeters
                let isLand = terrain.height(at: SIMD2(next, z)) > 0.01
                if isLand != wasLand {
                    // Bisect to the crossing.
                    var low = x
                    var high = next
                    for _ in 0 ..< 10 {
                        let middle = (low + high) / 2
                        if (terrain.height(at: SIMD2(middle, z)) > 0.01) == wasLand {
                            low = middle
                        } else {
                            high = middle
                        }
                    }
                    crossings.append((low + high) / 2)
                }
                wasLand = isLand
                x = next
            }
        }
        // Distance of each crossing from the nearest texel-center line, in texels (0...0.5).
        let offsets = crossings.map { crossing -> Float in
            let texel = (crossing + terrain.levels[0].size / 2) / texelMeters - 0.5
            return abs(texel - texel.rounded())
        }
        // A smooth coastline crosses at any offset (about 10% within 0.05); a staircase almost always on the grid.
        let onGrid = offsets.filter { $0 < 0.05 }.count
        #expect(crossings.count > 100)
        #expect(onGrid * 4 < crossings.count, "\(onGrid) of \(crossings.count) coastline crossings lie on texel centers")
    }
}
