#include <metal_stdlib>
#include "SceneSprocketsToonShaders.h"
#include "BlinnPhongLighting.h"

using namespace metal;

// Cel shading: each light's N·L is cut into flat bands between the shade color and the full color, with a hard
// highlight and rim light. The outline pass draws the mesh's back faces pushed out along their normals by a fixed
// number of pixels (an inverted hull).
namespace Toon {

    // True when a shadow map is bound.
    constant bool HAS_SHADOWS [[function_constant(0)]];

    struct Vertex {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
    };

    struct Fragment {
        float4 position [[position]];
        float3 worldPosition;
        float3 normal;
        uint view [[flat]];
    };

    [[vertex]] Fragment vertex_main(
        ushort view [[amplification_id]],
        Vertex in [[stage_in]],
        constant BlinnPhongFrame &frame [[buffer(1)]],
        constant float4x4 &modelMatrix [[buffer(2)]],
        constant float3x3 &normalMatrix [[buffer(3)]]
    ) {
        float4 world = modelMatrix * float4(in.position, 1);
        Fragment out;
        out.position = frame.viewProjections[view] * world;
        out.worldPosition = world.xyz / world.w;
        out.normal = normalMatrix * in.normal;
        out.view = view;
        return out;
    }

    // 0 (shade) to 1 (full color) in `bands` steps, each edge `softness` of a band wide.
    inline float quantize(float value, int bands, float softness) {
        float scaled = saturate(value) * float(bands);
        float step = floor(scaled);
        float edge = softness > 0 ? smoothstep(0.0, softness, scaled - step) : 1.0;
        return saturate((step + edge) / float(bands));
    }

    [[fragment]] float4 fragment_main(
        Fragment in [[stage_in]],
        constant BlinnPhongFrame &frame [[buffer(0)]],
        constant LightingLight *lights [[buffer(1)]],
        constant ToonMaterialUniforms &material [[buffer(2)]],
        depth2d_array<float, access::sample> shadowMap [[texture(3), function_constant(HAS_SHADOWS)]],
        sampler shadowSampler [[sampler(1), function_constant(HAS_SHADOWS)]],
        constant LightingShadowUniforms &shadow [[buffer(3), function_constant(HAS_SHADOWS)]]
    ) {
        float3 normal = length_squared(in.normal) > 1e-8 ? normalize(in.normal) : float3(0, 1, 0);
        float3 toCamera = normalize(frame.cameraPositions[in.view] - in.worldPosition);
        // Lit amount of the shade-to-color range, summed over lights.
        float3 lit = 0;
        float3 highlight = 0;
        for (int index = 0; index < frame.lightCount; index++) {
            const LightingLight light = lights[index];
            const Lighting::LightSample lightSample = Lighting::sample(light, in.worldPosition);
            const float3 toLight = lightSample.toLight;
            float lambertian = max(dot(toLight, normal), 0.0);
            if (lambertian == 0.0 || all(lightSample.radiance == 0.0)) {
                continue;
            }
            // One visibility value, not a tinted color: it is banded with the diffuse term.
            float visible = 1;
            if (HAS_SHADOWS && material.receivesShadow != 0 && light.shadowSliceCount > 0) {
                const int end = min(light.shadowSliceStart + light.shadowSliceCount, kLightingMaxShadowSliceCount);
                for (int slice = max(light.shadowSliceStart, 0); slice < end; slice++) {
                    visible *= Lighting::sliceShadow(in.worldPosition, shadow.sliceViewProjections[slice], shadow.mapSize, shadow.radius, shadowMap, shadowSampler, uint(slice));
                }
                visible = mix(1.0, visible, shadow.intensity);
            }
            float band = quantize(lambertian * visible, material.bands, material.bandSoftness);
            lit += lightSample.radiance * band;
            if (material.highlightThreshold < 1 && visible > 0.5) {
                float specular = dot(normalize(toLight + toCamera), normal);
                highlight += lightSample.radiance * step(material.highlightThreshold, specular);
            }
        }
        float3 color = material.color * mix(material.shadeColor, float3(1), saturate(lit));
        color += material.highlightColor * highlight;
        if (material.rimThreshold < 1) {
            float rim = 1.0 - max(dot(normal, toCamera), 0.0);
            color += material.rimColor * smoothstep(material.rimThreshold, material.rimThreshold + 0.02, rim);
        }
        // The scene's exposure and tone mapping, as every renderer applies them.
        return float4(frame.linearOutput ? color : Lighting::toneMap(color * frame.exposure, frame.toneMapping), material.opacity);
    }

    // MARK: Outline

    struct OutlineFragment {
        float4 position [[position]];
    };

    [[vertex]] OutlineFragment outline_vertex(
        ushort view [[amplification_id]],
        Vertex in [[stage_in]],
        constant BlinnPhongFrame &frame [[buffer(1)]],
        constant float4x4 &modelMatrix [[buffer(2)]],
        constant float3x3 &normalMatrix [[buffer(3)]],
        constant ToonOutlineUniforms &outline [[buffer(4)]]
    ) {
        float4x4 viewProjection = frame.viewProjections[view];
        float4 clip = viewProjection * (modelMatrix * float4(in.position, 1));
        // The normal's direction on screen; the push is a fixed size in pixels at any distance.
        float2 screenNormal = (viewProjection * float4(normalMatrix * in.normal, 0)).xy;
        if (length_squared(screenNormal) > 1e-12) {
            clip.xy += normalize(screenNormal) * outline.width * 2.0 / outline.viewportSize * clip.w;
        }
        OutlineFragment out;
        out.position = clip;
        return out;
    }

    [[fragment]] float4 outline_fragment(
        OutlineFragment in [[stage_in]],
        constant ToonOutlineUniforms &outline [[buffer(4)]]
    ) {
        return outline.color;
    }
}
