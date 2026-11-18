#include <metal_stdlib>
#include "SceneSprocketsVoxelsShaders.h"
#include "BlinnPhongLighting.h"
#include "PBRLighting.h"

using namespace metal;

// Voxel grids traced in the fragment shader. Each node draws the back faces of its grid's box; the fragment shader
// walks the voxels along the view ray (Amanatides and Woo), then lights the first filled voxel (Blinn-Phong or PBR)
// and writes its depth. The shadow pass walks rays from the light the same way and writes only depth.
namespace Voxel {

    // True when a shadow map is bound.
    constant bool HAS_SHADOWS [[function_constant(0)]];

    struct Hit {
        bool hit;
        // Grid space.
        float3 position;
        float3 normal;
        // Linear.
        float4 color;
    };

    // Walks a camera-relative world ray through the grid. `worldDirection` need not be normalized.
    inline Hit trace(float3 worldOrigin, float3 worldDirection, constant VoxelUniforms &uniforms, texture3d<float, access::read> voxels) {
        float3 origin = (uniforms.inverseModelMatrix * float4(worldOrigin, 1)).xyz;
        float3 direction = normalize((uniforms.inverseModelMatrix * float4(worldDirection, 0)).xyz);
        float3 size = float3(uniforms.size);
        Hit result = { false, float3(0), float3(0), float4(0) };

        // Where the ray is inside the box. Behind the origin does not count.
        float3 inverseDirection = 1.0 / direction;
        float3 t0 = -origin * inverseDirection;
        float3 t1 = (size - origin) * inverseDirection;
        float3 nearT = min(t0, t1);
        float3 farT = max(t0, t1);
        float enter = max(max(max(nearT.x, nearT.y), nearT.z), 0.0);
        float exit = min(min(farT.x, farT.y), farT.z);
        if (enter >= exit) {
            return result;
        }

        int3 step = int3(sign(direction));
        int3 cell = clamp(int3(floor(origin + direction * enter)), int3(0), uniforms.size - 1);
        float3 tDelta = abs(inverseDirection);
        float3 tMax = (float3(cell) + float3(step > 0) - origin) * inverseDirection;
        tMax = select(tMax, float3(INFINITY), step == 0);

        // The axis of the face the ray last crossed; -1 when it starts inside the box.
        int axis = -1;
        if (enter > 0) {
            axis = nearT.x >= nearT.y && nearT.x >= nearT.z ? 0 : (nearT.y >= nearT.z ? 1 : 2);
        }
        float t = enter;
        int maxSteps = uniforms.size.x + uniforms.size.y + uniforms.size.z;
        for (int index = 0; index < maxSteps; index++) {
            float4 color = voxels.read(uint3(cell));
            if (color.a > 0) {
                float3 normal = -direction;
                if (axis >= 0) {
                    normal = float3(0);
                    normal[axis] = -float(step[axis]);
                }
                result = { true, origin + direction * t, normal, color };
                return result;
            }
            axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2);
            t = tMax[axis];
            if (t > exit) {
                break;
            }
            cell[axis] += step[axis];
            tMax[axis] += tDelta[axis];
            if (any(cell < 0) || any(cell >= uniforms.size)) {
                break;
            }
        }
        return result;
    }

    struct Fragment {
        float4 position [[position]];
        // Camera-relative world position on the box.
        float3 worldPosition;
        uint view [[flat]];
    };

    struct Output {
        float4 color [[color(0)]];
        float depth [[depth(any)]];
    };

    // 36 corner indices of the box, counter-clockwise seen from outside. Corner i is (i & 1, i & 2, i & 4).
    constant ushort boxIndices[36] = {
        0, 4, 6, 0, 6, 2, // -X
        1, 3, 7, 1, 7, 5, // +X
        0, 1, 5, 0, 5, 4, // -Y
        2, 6, 7, 2, 7, 3, // +Y
        0, 2, 3, 0, 3, 1, // -Z
        4, 5, 7, 4, 7, 6, // +Z
    };

    inline float4 boxCorner(uint vertexID, constant VoxelUniforms &uniforms) {
        ushort corner = boxIndices[vertexID];
        float3 select = float3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        return uniforms.modelMatrix * float4(select * float3(uniforms.size), 1);
    }

    [[vertex]] Fragment vertex_main(
        uint vertexID [[vertex_id]],
        ushort view [[amplification_id]],
        constant BlinnPhongFrame &viewFrame [[buffer(1)]],
        constant VoxelUniforms &uniforms [[buffer(2)]]
    ) {
        float4 world = boxCorner(vertexID, uniforms);
        Fragment out;
        out.position = viewFrame.viewProjections[view] * world;
        out.worldPosition = world.xyz / world.w;
        out.view = view;
        return out;
    }

    // The camera-relative world hit and its depth, or false when the ray misses or the hit is outside the view.
    inline bool viewHit(Fragment in, float3 camera, float4x4 viewProjection, constant VoxelUniforms &uniforms, texture3d<float, access::read> voxels, thread float3 &world, thread float3 &normal, thread float4 &color, thread float &depth) {
        Hit hit = trace(camera, in.worldPosition - camera, uniforms, voxels);
        if (!hit.hit) {
            return false;
        }
        float4 world4 = uniforms.modelMatrix * float4(hit.position, 1);
        world = world4.xyz / world4.w;
        float4 clip = viewProjection * float4(world, 1);
        depth = clip.z / clip.w;
        // In front of the near plane (reversed depth: near is 1).
        if (depth > 1.0 || depth < 0.0) {
            return false;
        }
        normal = normalize(uniforms.normalMatrix * hit.normal);
        color = hit.color;
        return true;
    }

    [[fragment]] Output fragment_main(
        Fragment in [[stage_in]],
        constant BlinnPhongFrame &frame [[buffer(0)]],
        constant BlinnPhongLight *lights [[buffer(1)]],
        constant BlinnPhongMaterialUniforms &material [[buffer(2)]],
        constant VoxelUniforms &uniforms [[buffer(4)]],
        // Linear colors; alpha 0 is empty.
        texture3d<float, access::read> voxels [[texture(0)]],
        // Screen-space ambient visibility; 1x1 white when off.
        texture2d<float, access::read> ambientOcclusion [[texture(6)]],
        depth2d_array<float, access::sample> shadowMap [[texture(3), function_constant(HAS_SHADOWS)]],
        sampler shadowSampler [[sampler(1), function_constant(HAS_SHADOWS)]],
        constant BlinnPhongShadowUniforms &shadow [[buffer(3), function_constant(HAS_SHADOWS)]]
    ) {
        float3 camera = frame.cameraPositions[in.view];
        float3 world;
        float3 normal;
        float4 color;
        Output out;
        if (!viewHit(in, camera, frame.viewProjections[in.view], uniforms, voxels, world, normal, color, out.depth)) {
            discard_fragment();
        }
        BlinnPhong::Surface surface = { material.ambient * color.rgb, material.diffuse * color.rgb, material.specular, material.emission, material.shininess, material.opacity, material.receivesShadow != 0 };
        if (BlinnPhong::channelColor(surface, frame.materialChannel, out.color)) {
            return out;
        }
        uint2 occlusionSize = uint2(ambientOcclusion.get_width(), ambientOcclusion.get_height());
        float occlusion = ambientOcclusion.read(min(uint2(in.position.xy), occlusionSize - 1)).r;
        out.color = BlinnPhong::shade(surface, world, normal, camera, frame, lights, occlusion, HAS_SHADOWS, shadowMap, shadowSampler, shadow);
        return out;
    }

    [[fragment]] Output fragment_pbr(
        Fragment in [[stage_in]],
        constant PBRMaterialUniforms &material [[buffer(0)]],
        constant PBRFrameUniforms &frame [[buffer(1)]],
        constant LightingLight *lights [[buffer(2)]],
        constant PBRMaterialResources &materialResources [[buffer(3)]],
        constant LightingShadowUniforms &shadow [[buffer(4)]],
        constant VoxelUniforms &uniforms [[buffer(5)]],
        constant PBRFrameResources &frameResources [[buffer(6)]],
        texture3d<float, access::read> voxels [[texture(6)]]
    ) {
        float3 camera = frame.cameraPositions[in.view];
        float3 world;
        float3 normal;
        float4 color;
        Output out;
        if (!viewHit(in, camera, frame.viewProjectionMatrices[in.view], uniforms, voxels, world, normal, color, out.depth)) {
            discard_fragment();
        }
        PBR::Fragment surface;
        surface.position = in.position;
        surface.worldPosition = world;
        surface.normal = normal;
        surface.tangent = float4(0);
        surface.texCoord0 = float2(0);
        surface.texCoord1 = float2(0);
        // Multiplies the base color factor.
        surface.color = float4(color.rgb, 1);
        surface.modelScale = 1;
        surface.record = 0;
        surface.eye = in.view;
        out.color = PBR::shade(surface, true, material, frame, lights, materialResources, shadow, frameResources);
        return out;
    }

    // MARK: Shadow casting

    struct ShadowFragment {
        float4 position [[position]];
        float3 worldPosition;
    };

    struct ShadowOutput {
        float depth [[depth(any)]];
    };

    [[vertex]] ShadowFragment shadow_vertex(
        uint vertexID [[vertex_id]],
        constant float4x4 &lightViewProjection [[buffer(1)]],
        constant VoxelUniforms &uniforms [[buffer(2)]]
    ) {
        float4 world = boxCorner(vertexID, uniforms);
        ShadowFragment out;
        out.position = lightViewProjection * world;
        out.worldPosition = world.xyz / world.w;
        return out;
    }

    [[fragment]] ShadowOutput shadow_fragment(
        ShadowFragment in [[stage_in]],
        constant float4x4 &lightViewProjection [[buffer(1)]],
        constant VoxelUniforms &uniforms [[buffer(2)]],
        texture3d<float, access::read> voxels [[texture(0)]],
        constant float &shadowMapSize [[buffer(4)]],
        constant float4x4 &inverseViewProjection [[buffer(5)]]
    ) {
        // The light ray through this texel, for orthographic and perspective light views alike. Reversed depth: the
        // near plane is 1; 0.5 stays finite for an infinite far plane.
        float4 clip = lightViewProjection * float4(in.worldPosition, 1);
        float2 ndc = clip.xy / clip.w;
        float4 nearPoint = inverseViewProjection * float4(ndc, 1, 1);
        float4 midPoint = inverseViewProjection * float4(ndc, 0.5, 1);
        float3 origin = nearPoint.xyz / nearPoint.w;
        float3 direction = normalize(midPoint.xyz / midPoint.w - origin);
        Hit hit = trace(origin, direction, uniforms, voxels);
        if (!hit.hit) {
            discard_fragment();
        }
        float4 world4 = uniforms.modelMatrix * float4(hit.position, 1);
        float3 world = world4.xyz / world4.w;
        // The hardware depth bias does not apply to written depth: push the hit away from the light by 1.5 texels,
        // more on surfaces the light grazes.
        float4 hitClip = lightViewProjection * float4(world, 1);
        float4 neighbor = inverseViewProjection * float4(hitClip.xy / hitClip.w + float2(2.0 / shadowMapSize, 0), hitClip.z / hitClip.w, 1);
        float texel = distance(neighbor.xyz / neighbor.w, world);
        float facing = max(abs(dot(normalize(uniforms.normalMatrix * hit.normal), direction)), 0.1);
        float4 biased = lightViewProjection * float4(world + direction * 1.5 * texel / facing, 1);
        return { saturate(biased.z / biased.w) };
    }
}
