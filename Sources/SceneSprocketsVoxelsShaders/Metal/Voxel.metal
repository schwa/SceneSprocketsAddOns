#include <metal_stdlib>
#include "SceneSprocketsVoxelsShaders.h"
#include "BlinnPhongLighting.h"

using namespace metal;

// Voxel grids traced in the fragment shader. Each node draws the back faces of its grid's box; the fragment shader
// walks the voxels along the view ray (Amanatides and Woo), then lights the first filled voxel with the Blinn-Phong
// model and writes its depth.
namespace Voxel {

    // True when a shadow map is bound.
    constant bool HAS_SHADOWS [[function_constant(0)]];

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

    [[vertex]] Fragment vertex_main(
        uint vertexID [[vertex_id]],
        ushort view [[amplification_id]],
        constant BlinnPhongFrame &frame [[buffer(1)]],
        constant VoxelUniforms &uniforms [[buffer(2)]]
    ) {
        ushort corner = boxIndices[vertexID];
        float3 select = float3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        float4 world = uniforms.modelMatrix * float4(select * float3(uniforms.size), 1);
        Fragment out;
        out.position = frame.viewProjections[view] * world;
        out.worldPosition = world.xyz / world.w;
        out.view = view;
        return out;
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
        float3 origin = (uniforms.inverseModelMatrix * float4(camera, 1)).xyz;
        float3 direction = normalize((uniforms.inverseModelMatrix * float4(in.worldPosition - camera, 0)).xyz);
        float3 size = float3(uniforms.size);

        // Where the ray is inside the box. Behind the camera does not count.
        float3 inverseDirection = 1.0 / direction;
        float3 t0 = -origin * inverseDirection;
        float3 t1 = (size - origin) * inverseDirection;
        float3 nearT = min(t0, t1);
        float3 farT = max(t0, t1);
        float enter = max(max(max(nearT.x, nearT.y), nearT.z), 0.0);
        float exit = min(min(farT.x, farT.y), farT.z);
        if (enter >= exit) {
            discard_fragment();
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
        bool hit = false;
        int maxSteps = uniforms.size.x + uniforms.size.y + uniforms.size.z;
        float4 color;
        for (int index = 0; index < maxSteps; index++) {
            color = voxels.read(uint3(cell));
            if (color.a > 0) {
                hit = true;
                break;
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
        if (!hit) {
            discard_fragment();
        }

        float3 local = origin + direction * t;
        float4 world4 = uniforms.modelMatrix * float4(local, 1);
        float3 world = world4.xyz / world4.w;
        float4 clip = frame.viewProjections[in.view] * float4(world, 1);
        float depth = clip.z / clip.w;
        // In front of the near plane (reversed depth: near is 1).
        if (depth > 1.0 || depth < 0.0) {
            discard_fragment();
        }
        float3 localNormal = -direction;
        if (axis >= 0) {
            localNormal = float3(0);
            localNormal[axis] = -float(step[axis]);
        }
        float3 normal = normalize(uniforms.normalMatrix * localNormal);

        BlinnPhong::Surface surface = { material.ambient * color.rgb, material.diffuse * color.rgb, material.specular, material.emission, material.shininess, material.opacity, material.receivesShadow != 0 };
        Output out;
        out.depth = depth;
        if (BlinnPhong::channelColor(surface, frame.materialChannel, out.color)) {
            return out;
        }
        uint2 occlusionSize = uint2(ambientOcclusion.get_width(), ambientOcclusion.get_height());
        float occlusion = ambientOcclusion.read(min(uint2(in.position.xy), occlusionSize - 1)).r;
        out.color = BlinnPhong::shade(surface, world, normal, camera, frame, lights, occlusion, HAS_SHADOWS, shadowMap, shadowSampler, shadow);
        return out;
    }

}
