#include "TerrainNoise.h"

// Bakes a rectangle of the procedural terrain into a heightmap level: (height, height squared) in meters. `start` is
// the rectangle's first texel in world texel coordinates (texel g covers x from g to g + 1 texels, 0 at world x = 0).
// Texel g is stored at (g + size / 2) mod size, so the texture can hold any square of the world and wrap.
kernel void heightmap_bake(
    texture2d<float, access::write> heightmap [[texture(0)]],
    constant float &worldSize [[buffer(0)]],
    constant float &heightScale [[buffer(1)]],
    constant uint &octaves [[buffer(2)]],
    constant int2 &start [[buffer(3)]],
    constant uint2 &count [[buffer(4)]],
    constant OctaveOrigin *origins [[buffer(5)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= count)) {
        return;
    }
    int2 size = int2(heightmap.get_width(), heightmap.get_height());
    int2 texel = start + int2(gid);
    // Relative to the region's first texel corner, which `origins` were computed for; small, so float is precise.
    float2 offset = (float2(gid) + 0.5) * worldSize / float2(size);
    float h = terrainHeight(offset, origins, octaves, heightScale);
    int2 stored = ((texel + size / 2) % size + size) % size;
    heightmap.write(float4(h, h * h, 0, 0), uint2(stored));
}
