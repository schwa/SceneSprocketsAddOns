#include "TerrainCommon.h"

// Copies the height channel of mip 0 into a single-channel texture, halving bandwidth for displacement and shading.
kernel void heightmap_extract(
    texture2d<float, access::read> moments [[texture(0)]],
    texture2d<float, access::write> heights [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uint2(heights.get_width(), heights.get_height()))) {
        return;
    }
    heights.write(float4(moments.read(gid).r), gid);
}

// Tileable two-octave value noise in [-1, 1] for blend-boundary variation: 16 cells across, plus a 4x finer octave.
// Lattice coordinates wrap, so the texture repeats seamlessly.
kernel void blend_noise_bake(
    texture2d<float, access::write> noise [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint size = noise.get_width();
    if (any(gid >= uint2(size))) {
        return;
    }
    float2 unit = (float2(gid) + 0.5) / float(size);
    float value = 0;
    const float weights[2] = { 0.7, 0.3 };
    const float periods[2] = { 16, 64 };
    for (int octave = 0; octave < 2; ++octave) {
        float period = periods[octave];
        float2 x = unit * period;
        float2 i = floor(x);
        float2 f = x - i;
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float a = hash(fmod(i, period));
        float b = hash(fmod(i + float2(1, 0), period));
        float c = hash(fmod(i + float2(0, 1), period));
        float d = hash(fmod(i + float2(1, 1), period));
        value += weights[octave] * (-1.0 + 2.0 * mix(mix(a, b, u.x), mix(c, d, u.x), u.y));
    }
    noise.write(float4(value), gid);
}

// Tileable two-octave value noise with its derivative, for close-up surface detail: (value, d/du, d/dv) where u and
// v are measured in noise cells. 32 cells across, plus a 4x finer octave at low weight (its slopes are 4x steeper,
// so a larger weight makes the bumps follow its grid).
kernel void detail_noise_bake(
    texture2d<float, access::write> noise [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint size = noise.get_width();
    if (any(gid >= uint2(size))) {
        return;
    }
    float2 unit = (float2(gid) + 0.5) / float(size);
    float3 result = 0;
    const float weights[2] = { 0.85, 0.15 };
    const float periods[2] = { 32, 128 };
    for (int octave = 0; octave < 2; ++octave) {
        float period = periods[octave];
        float2 x = unit * period;
        float2 i = floor(x);
        float2 f = x - i;
        float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
        float2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
        float a = hash(fmod(i, period));
        float b = hash(fmod(i + float2(1, 0), period));
        float c = hash(fmod(i + float2(0, 1), period));
        float d = hash(fmod(i + float2(1, 1), period));
        float k1 = b - a;
        float k2 = c - a;
        float k4 = a - b - c + d;
        float value = -1.0 + 2.0 * (a + k1 * u.x + k2 * u.y + k4 * u.x * u.y);
        // Derivative per cell of the base octave (finer octaves change faster).
        float2 derivative = 2.0 * du * (float2(k1, k2) + k4 * u.yx) * (period / periods[0]);
        result += weights[octave] * float3(value, derivative);
    }
    noise.write(float4(result, 0), gid);
}

// Box-filters one mip level into the next. Averaging both moments keeps the variance correct.
kernel void heightmap_downsample(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (any(gid >= uint2(destination.get_width(), destination.get_height()))) {
        return;
    }
    uint2 maximum = uint2(source.get_width(), source.get_height()) - 1;
    uint2 base = gid * 2;
    float4 sum = source.read(min(base, maximum))
        + source.read(min(base + uint2(1, 0), maximum))
        + source.read(min(base + uint2(0, 1), maximum))
        + source.read(min(base + uint2(1, 1), maximum));
    destination.write(sum * 0.25, gid);
}
