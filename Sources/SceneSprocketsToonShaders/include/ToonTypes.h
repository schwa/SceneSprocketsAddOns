#pragma once

#import <simd/simd.h>

// One toon material, in linear RGB.
struct ToonMaterialUniforms {
    simd_float3 color;
    // Multiplies `color` where a light does not reach.
    simd_float3 shadeColor;
    // Lit steps from shade to full color; 1 is two-tone.
    int bands;
    // Width of the soft edge between bands, as a fraction of a band.
    float bandSoftness;
    simd_float3 highlightColor;
    // Above this N·H the highlight is on; 1 turns it off.
    float highlightThreshold;
    simd_float3 rimColor;
    // Rim light where 1 - N·V is above this; 1 turns it off.
    float rimThreshold;
    // 0 ignores shadows for this mesh.
    int receivesShadow;
    float opacity;
};
typedef struct ToonMaterialUniforms ToonMaterialUniforms;

// The outline pass: the mesh's back faces pushed out along their normals.
struct ToonOutlineUniforms {
    simd_float4 color;
    // In pixels.
    float width;
    simd_float2 viewportSize;
};
typedef struct ToonOutlineUniforms ToonOutlineUniforms;
