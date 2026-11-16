#pragma once

#include "TerrainCommon.h"

// The built-in sky: a horizon-to-zenith gradient with a sun disc and glow. Drawn by sky_fragment, and the default fog
// color for terrain (TerrainMaterial.fogSkyBlend). Callers with their own sky can skip Terrain.skyWork and set
// fogSkyBlend to 0 and fogColor to match.

struct SkyOut {
    float4 position [[position]];
    float2 ndc;
};

inline float3 skyColor(float3 direction, float3 sun, constant TerrainMaterial &material) {
    float up = saturate(direction.y);
    float3 color = mix(material.skyHorizonColor, material.skyZenithColor, pow(up, 0.5));
    float sunAmount = saturate(dot(direction, sun));
    color += material.sunColor * (pow(sunAmount, 800.0) * 4.0 + pow(sunAmount, 8.0) * 0.25);
    return color;
}
