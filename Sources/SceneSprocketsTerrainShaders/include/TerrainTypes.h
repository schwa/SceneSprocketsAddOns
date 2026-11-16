#pragma once

#include <simd/simd.h>

// Maximum depth of the concurrent binary tree. Leaves at this depth are single bits.
#define CBT_MAX_DEPTH 25
// libcbt's bit-packed heap is 2^(D-1) bytes.
#define CBT_HEAP_WORD_COUNT (1 << (CBT_MAX_DEPTH - 3))
// The reduction prepass handles leaf bits in groups of 256 words (8192 leaves) and skips groups whose bits did not
// change. One dirty bit per group.
#define CBT_PREPASS_GROUP_SHIFT 13
#define CBT_DIRTY_WORD_COUNT ((1 << (CBT_MAX_DEPTH - CBT_PREPASS_GROUP_SHIFT)) / 32)

// Capacity of the per-frame leaf and visible-leaf lists.
#define CBT_MAX_LEAVES (1 << 21)

// Layout of the indirect arguments buffer (in uint32 units).
#define CBT_ARGS_DISPATCH 0
#define CBT_ARGS_DRAW 4
// Previous frame's finished counts for display: the live counters are reset and rebuilt during each frame.
#define CBT_ARGS_STATS_VISIBLE 9
#define CBT_ARGS_STATS_LEAVES 10
#define CBT_ARGS_COUNT 12 // DRAW holds MTLDrawIndexedPrimitivesIndirectArguments (5 uints)

// One surface material. Its weight is the product of an altitude band and a slope band, each given as
// (fade in start, full start, full end, fade out end); use large magnitudes (e.g. +/-100) for open ends. Altitudes
// are fractions of the height scale; slopes are the normal's y component (1 = flat, 0 = vertical).
typedef struct TerrainLayer {
    simd_float3 color;
    simd_float4 altitudeBand;
    simd_float4 slopeBand;
    // Curvature: blurred height (~32 m) minus height, per meter of blur radius. > 0 in gullies, < 0 on ridges.
    simd_float4 curvatureBand;
    // Valley depth: blurred height (~512 m) minus height, as a fraction of the height scale. > 0 in valleys.
    // A cheap stand-in for wetness / flow accumulation.
    simd_float4 valleyBand;
    // Aspect: how much the slope faces `aspectAzimuth` (degrees, 0 = -z, clockwise from above), from -1 (away)
    // to 1 (toward), scaled by steepness so flat ground is 0.
    simd_float4 aspectBand;
    float aspectAzimuth;
    float altitudeNoise;           // altitude amplitude of the boundary noise for this layer
    float slopeNoise;              // slope amplitude of the boundary noise for this layer
    float opacity;
    float colorVariation;          // +/- fraction of brightness varied by the detail noise
    uint32_t usesColorMap;         // 1: color comes from the terrain's color map image instead of `color`
    int32_t maskChannel;           // 0-3: opacity is multiplied by this channel of the mask map image; -1: no mask
    // Derived before upload (TerrainStyle.prepared()). 1 / fade width for each band's (in, out) fades, in the
    // order altitude, slope, curvature, valley, aspect; a hard edge uses a very large value.
    simd_float4 fadeScale;
    simd_float4 featureFadeScale;
    simd_float2 aspectFadeScale;
    simd_float2 aspectDirection;   // unit (x, z) toward aspectAzimuth
    uint32_t featureMask;          // 1 curvature, 2 valley, 4 aspect, 8 color map, 16 mask map
} TerrainLayer;

// Everything that controls the terrain's look except the layers, which are bound as their own buffer
// (`constant TerrainLayer *layers`) and painted in order, each over the result of the ones before.
typedef struct TerrainMaterial {
    uint32_t layerCount;           // number of entries in the layers buffer, set before upload
    uint32_t featureMask;          // union of the layers' feature masks, derived before upload
    float boundaryNoiseScale;      // meters per noise cell; a second octave is 4x finer
    // Close-up surface detail from a baked noise texture, sampled triplanar so cliffs don't stretch.
    float detailScale;             // meters per detail noise cell
    float detailStrength;          // bump strength (slope change per unit noise slope); 0 disables bumps
    float detailDistance;          // meters at which detail has faded out

    simd_float3 sunColor;
    simd_float3 skyZenithColor;
    simd_float3 skyHorizonColor;
    float sunIntensity;
    float skyLightIntensity;
    float fogDensity;              // per meter at sea level
    float fogFalloff;              // per meter of altitude
    simd_float3 fogColor;          // color fog fades to where fogSkyBlend is below 1
    float fogSkyBlend;             // 1: fog fades to the built-in sky color; 0: to fogColor (for a custom sky)
    float exposure;
    // Where the color and mask properties lie: (origin x, origin z, extent, unused) in meters. Set by the renderer
    // from its TerrainData.
    simd_float4 colorMapPlacement;
    simd_float4 maskMapPlacement;
    // Contour lines at fixed true altitudes (ignoring height exaggeration); every 5th is thicker.
    float contourInterval;         // meters between lines; 0 turns them off
    float contourOpacity;          // how much a line darkens the terrain, 0...1
} TerrainMaterial;

typedef struct TerrainUniforms {
    simd_float4x4 viewProjection;
    simd_float4x4 inverseViewProjection;
    simd_float4 frustumPlanes[4];
    simd_float3 cameraPosition;
    simd_float3 sunDirection;
    float cbtSize;               // meters; side of the square the CBT covers (the outer clipmap level)
    float heightScale;
    float targetEdgePixels;
    float projectionScale;
    float minHeightVariance; // m²; flatter triangles do not split
    uint32_t updateMode; // 0 = split, 1 = merge, 2 = frozen
    uint32_t wireframe;
    uint32_t meshletSubdivision; // each leaf is drawn as a grid of 4^n triangles
    uint32_t debugMode;          // TerrainDebugMode raw value; 0 = normal shading
    uint32_t debugLayer;         // layer shown by the layer-weight debug mode
    simd_float2 cbtOrigin;       // meters; center of the CBT square (moves with the camera when streaming)
    simd_float2 detailOrigin;    // meters; center of clipmap level 0
    float detailSize;            // meters; side of clipmap level 0
    float heightExaggeration;    // multiplies every stored height; heightScale above already includes it
    uint32_t hasHeightFloor;     // 1: stored heights below heightFloor are raised to it after filtering
    float heightFloor;           // meters, before exaggeration
} TerrainUniforms;
