#include "Sky.h"

// Full-screen triangle; also used by the mini-map.
[[vertex]] SkyOut sky_vertex(uint vertexID [[vertex_id]]) {
    float2 ndc = float2((vertexID << 1) & 2, vertexID & 2) * 2.0 - 1.0;
    return { float4(ndc, 0.0, 1.0), ndc };
}

[[fragment]] float4 sky_fragment(
    SkyOut in [[stage_in]],
    constant TerrainUniforms &uniforms [[buffer(0)]],
    constant TerrainMaterial &material [[buffer(1)]]
) {
    float4 far = uniforms.inverseViewProjection * float4(in.ndc, 0.0001, 1.0);
    float3 direction = normalize(far.xyz / far.w - uniforms.cameraPosition);
    return displayColor(skyColor(direction, uniforms.sunDirection, material), material);
}
