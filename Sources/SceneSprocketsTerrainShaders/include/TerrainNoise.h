#pragma once

// Procedural terrain heights, shared with the terrain shaders (for `hash`). Metal only; the guard keeps it out of
// the C module SwiftPM builds from this include directory.
#ifdef __METAL_VERSION__

#include <metal_stdlib>

using namespace metal;

inline float hash(float2 p) {
    uint2 q = uint2(int2(p) + int2(100000));
    uint h = q.x * 1597334677u ^ q.y * 3812015801u;
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h) * (1.0 / 4294967295.0);
}

// hash at an integer lattice cell; matches hash(float2) at integral points.
inline float hashCell(int2 cell) {
    uint2 q = uint2(cell + int2(100000));
    uint h = q.x * 1597334677u ^ q.y * 3812015801u;
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h) * (1.0 / 4294967295.0);
}

// Value noise with analytic derivatives at lattice position `base + x`, `base` an exact integer cell. Returns
// (value in [-1, 1], d/dx, d/dy). Splitting off `base` keeps `x` small, so the fractional part keeps its precision far
// from the origin.
inline float3 noised(int2 base, float2 x) {
    float2 i = floor(x);
    float2 f = x - i;
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    int2 cell = base + int2(i);
    float a = hashCell(cell);
    float b = hashCell(cell + int2(1, 0));
    float c = hashCell(cell + int2(0, 1));
    float d = hashCell(cell + int2(1, 1));
    float k1 = b - a;
    float k2 = c - a;
    float k4 = a - b - c + d;
    float value = a + k1 * u.x + k2 * u.y + k4 * u.x * u.y;
    float2 derivative = du * (float2(k1, k2) + k4 * u.yx);
    return float3(-1.0 + 2.0 * value, 2.0 * derivative);
}

// Where one octave's lattice coordinates start for a baked region: an exact integer cell plus a fraction in [0, 1).
// TerrainGenerator computes these in double precision from the region's world origin.
struct OctaveOrigin {
    int2 cell;
    float2 fraction;
};

// Eroded-looking fBm: octaves are damped where the accumulated slope is steep. `offset` is the point's position in
// meters relative to the region origin the `origins` were computed for. Octave k samples the lattice at
// (2R)^k (origin + offset) / 1800 with R a fixed rotation; the origin part comes exact from `origins`.
inline float terrainHeight(float2 offset, constant OctaveOrigin *origins, uint octaves, float heightScale) {
    const float2x2 rotation = float2x2(float2(0.8, -0.6), float2(0.6, 0.8));
    float2 p = offset * (1.0 / 1800.0);
    float sum = 0.0;
    float amplitude = 1.0;
    float2 slope = 0.0;
    for (uint i = 0; i < octaves; ++i) {
        float3 n = noised(origins[i].cell, origins[i].fraction + p);
        slope += n.yz;
        sum += amplitude * n.x / (1.0 + dot(slope, slope));
        amplitude *= 0.5;
        p = rotation * p * 2.0;
    }
    return sum * heightScale;
}

#endif
