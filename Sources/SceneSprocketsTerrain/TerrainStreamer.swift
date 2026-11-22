import Metal
import MetalSprockets
import simd

/// Owns the clipmap levels and keeps them filled from a `TerrainHeightSource`.
///
/// A bounded source gets one fixed level covering its extent, filled once. An unbounded source gets two levels that
/// follow the camera: level 0 at full detail and a coarser outer level (at least `outerLevelScale` times wider, growing
/// with altitude). When the camera is more than a chunk from a level's center, the level moves by whole chunks and the
/// source fills only the chunks that came into view.
public final class TerrainStreamer {
    /// Finest first.
    public let levels: [ClipLevel]
    public let source: TerrainHeightSource
    public let heightScale: Float
    /// Level 0's size when streaming; the minimum for the outer level is `outerLevelScale` times this.
    let baseSize: Float
    let library: ShaderLibrary

    /// The outer level is at least this many times wider than level 0.
    public static let outerLevelScale = 4
    /// Higher up, the outer level doubles until the terrain reaches this many times the altitude.
    public static let viewDistancePerAltitude: Float = 10

    /// What `stream(around:)` changed.
    public struct Changes: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Some level moved or was refilled.
        public static let levels = Self(rawValue: 1)
        /// The outer level moved or resized; anything laid over it (like the CBT) is now out of place.
        public static let outerLevel = Self(rawValue: 2)
    }

    /// - Parameter baseSize: Level 0's side in meters for an unbounded source; a bounded source uses its extent.
    init(source: TerrainHeightSource, baseSize: Float, heightScale: Float, device: MTLDevice, library: ShaderLibrary) throws {
        self.source = source
        self.baseSize = baseSize
        self.heightScale = heightScale
        self.library = library
        func makeLevel(resolution: SIMD2<Int>, size: Float) throws -> ClipLevel {
            let moments = try Heightmap.makeTexture(device: device, width: resolution.x, height: resolution.y)
            return ClipLevel(moments: moments, heights: try Heightmap.heights(from: moments, library: library), size: size)
        }
        if let extent = source.extent {
            levels = [try makeLevel(resolution: source.resolution, size: extent)]
        } else {
            let outerResolution = SIMD2<Int>(repeating: max(source.resolution.x / 2, 256))
            levels = [
                try makeLevel(resolution: source.resolution, size: baseSize),
                try makeLevel(resolution: outerResolution, size: baseSize * Float(Self.outerLevelScale))
            ]
        }
        let runner = try Runner(configuration: MetalContextConfiguration(device: device))
        for level in levels {
            let resolution = SIMD2(level.moments.width, level.moments.height)
            try fill([.init(start: SIMD2(-resolution.x / 2, -resolution.y / 2), count: resolution)], of: level, runner: runner)
        }
    }

    /// The coarsest level.
    public var outerLevel: ClipLevel {
        levels[levels.count - 1]
    }

    /// Whether the levels follow the camera.
    public var isStreaming: Bool {
        source.extent == nil
    }

    /// Distance in meters from `position` to the nearest edge of the area the levels cover; nothing exists beyond it.
    public func viewDistance(from position: SIMD3<Float>) -> Float {
        let offset = abs(SIMD2(position.x, position.z) - outerLevel.origin)
        return outerLevel.size / 2 - max(offset.x, offset.y)
    }

    /// Moves the levels so `position` stays within one chunk of their centers, filling the new chunks. No-op for a
    /// bounded source.
    @discardableResult
    public func stream(around position: SIMD3<Float>) throws -> Changes {
        guard isStreaming else {
            return []
        }
        let xz = SIMD2(position.x, position.z)
        let runner = try Runner(configuration: MetalContextConfiguration(device: levels[0].moments.device))
        var changes: Changes = []
        for level in levels.dropLast() where try follow(xz, level: level, runner: runner) {
            changes.insert(.levels)
        }
        let resized = try resizeOuterLevel(for: position, runner: runner)
        if try follow(xz, level: outerLevel, runner: runner) || resized {
            changes.formUnion([.levels, .outerLevel])
        }
        return changes
    }

    /// Size of the outer level for a camera at `position`: the base size, doubled until even the worst case (camera a
    /// chunk off center, 3/8 of the size from the edge) reaches `viewDistancePerAltitude` times the altitude.
    /// Shrinking waits until the half size would do with a factor of 2 to spare, so small climbs don't flip it.
    private func outerLevelSize(for position: SIMD3<Float>) -> Float {
        let base = baseSize * Float(Self.outerLevelScale)
        let needed = max(position.y, 0) * Self.viewDistancePerAltitude
        var size = max(outerLevel.size, base)
        while size * 3 / 8 < needed {
            size *= 2
        }
        while size > base, (size / 2) * 3 / 8 >= needed * 2 {
            size /= 2
        }
        return size
    }

    /// Refills the whole outer level at a new size if the altitude calls for one. Returns whether it changed.
    private func resizeOuterLevel(for position: SIMD3<Float>, runner: Runner) throws -> Bool {
        let level = outerLevel
        let size = outerLevelSize(for: position)
        guard size != level.size else {
            return false
        }
        let chunkSize = size / Float(ClipLevel.chunksPerSide)
        level.size = size
        level.origin = (SIMD2(position.x, position.z) / chunkSize).rounded(.toNearestOrAwayFromZero) * chunkSize
        let start = texels(level.origin, level: level) &- level.resolution / 2
        try fill([.init(start: start, count: SIMD2(repeating: level.resolution))], of: level, runner: runner)
        return true
    }

    /// Moves one level if `xz` is more than a chunk from its center, filling the strips that came into view.
    private func follow(_ xz: SIMD2<Float>, level: ClipLevel, runner: Runner) throws -> Bool {
        let chunkSize = level.chunkSize
        let offset = xz - level.origin
        // Hysteresis: only move once the camera is more than a whole chunk from the center.
        guard abs(offset.x) > chunkSize || abs(offset.y) > chunkSize else {
            return false
        }
        let chunks = SIMD2<Int>((offset / chunkSize).rounded(.toNearestOrAwayFromZero))
        let size = level.resolution
        let half = SIMD2<Int>(repeating: size / 2)
        let newOrigin = level.origin + SIMD2<Float>(chunks) * chunkSize
        let oldStart = texels(level.origin, level: level) &- half
        let newStart = texels(newOrigin, level: level) &- half
        let shift = chunks &* (size / ClipLevel.chunksPerSide)

        var regions: [TerrainGenerator.TexelRegion] = []
        if abs(shift.x) >= size || abs(shift.y) >= size {
            regions.append(.init(start: newStart, count: SIMD2(repeating: size)))
        } else {
            // Columns that entered (full new height), then rows that entered (full new width).
            if shift.x != 0 {
                let x = shift.x > 0 ? oldStart.x + size : newStart.x
                regions.append(.init(start: SIMD2(x, newStart.y), count: SIMD2(abs(shift.x), size)))
            }
            if shift.y != 0 {
                let y = shift.y > 0 ? oldStart.y + size : newStart.y
                regions.append(.init(start: SIMD2(newStart.x, y), count: SIMD2(size, abs(shift.y))))
            }
        }
        level.origin = newOrigin
        try fill(regions, of: level, runner: runner)
        return true
    }

    /// Has the source fill `regions`, then rebuilds the level's mips and heights copy.
    private func fill(_ regions: [TerrainGenerator.TexelRegion], of level: ClipLevel, runner: Runner) throws {
        try source.fill(regions, of: level, heightScale: heightScale, runner: runner)
        try Heightmap.refresh(moments: level.moments, heights: level.heights, library: library, runner: runner)
    }

    /// A chunk-aligned world position in the level's texel coordinates.
    private func texels(_ position: SIMD2<Float>, level: ClipLevel) -> SIMD2<Int> {
        let scaled = (position * Float(level.resolution) / level.size).rounded(.toNearestOrAwayFromZero)
        return SIMD2<Int>(Int(scaled.x), Int(scaled.y))
    }
}
