#include <metal_stdlib>
#include "SceneSprocketsAddOnsShaders.h"
#include "BlinnPhongLighting.h"

using namespace metal;

// Raymarched signed distance shapes. Each node draws the back faces of its proxy box; the fragment shader marches the
// part of the view ray inside the box, then lights the hit with the Blinn-Phong model and writes its depth.
namespace SignedDistance {

    // True when a shadow map is bound.
    constant bool HAS_SHADOWS [[function_constant(0)]];

    // Polynomial smooth minimum (Inigo Quilez). It is at most k / 4 below min(a, b).
    inline float smoothMin(float a, float b, float k) {
        if (k <= 0) {
            return min(a, b);
        }
        float h = max(k - abs(a - b), 0.0) / k;
        return min(a, b) - h * h * k * 0.25;
    }

    inline float smoothMax(float a, float b, float k) {
        return -smoothMin(-a, -b, k);
    }

    inline float primitiveDistance(SignedDistanceInstruction instruction, float3 position) {
        float3 local = (instruction.inverseTransform * float4(position, 1)).xyz;
        float distance;
        switch (instruction.operation) {
            case SIGNED_DISTANCE_OP_SPHERE:
                distance = length(local) - instruction.parameters.x;
                break;
            case SIGNED_DISTANCE_OP_ROUNDED_BOX: {
                float radius = instruction.parameters.w;
                float3 q = abs(local) - instruction.parameters.xyz + radius;
                distance = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - radius;
                break;
            }
            default: {
                float3 start = instruction.parameters.xyz;
                float3 axis = instruction.end.xyz - start;
                float3 offset = local - start;
                float along = saturate(dot(offset, axis) / max(dot(axis, axis), 1e-12));
                distance = length(offset - axis * along) - instruction.parameters.w;
                break;
            }
        }
        return distance * instruction.scale;
    }

    // The shape's distance at a shape-space position.
    inline float shapeDistance(constant SignedDistanceInstruction *instructions, int count, float3 position) {
        float stack[kSignedDistanceMaxStackDepth];
        int depth = 0;
        for (int index = 0; index < count; index++) {
            SignedDistanceInstruction instruction = instructions[index];
            switch (instruction.operation) {
                case SIGNED_DISTANCE_OP_SMOOTH_UNION:
                    depth -= 1;
                    stack[depth - 1] = smoothMin(stack[depth - 1], stack[depth], instruction.smoothing);
                    break;
                case SIGNED_DISTANCE_OP_SMOOTH_SUBTRACTION:
                    depth -= 1;
                    stack[depth - 1] = smoothMax(stack[depth - 1], -stack[depth], instruction.smoothing);
                    break;
                case SIGNED_DISTANCE_OP_SMOOTH_INTERSECTION:
                    depth -= 1;
                    stack[depth - 1] = smoothMax(stack[depth - 1], stack[depth], instruction.smoothing);
                    break;
                default:
                    stack[depth] = primitiveDistance(instruction, position);
                    depth += 1;
                    break;
            }
        }
        return depth > 0 ? stack[0] : INFINITY;
    }

    // Tetrahedral gradient (four samples instead of six).
    inline float3 shapeNormal(constant SignedDistanceInstruction *instructions, int count, float3 position, float epsilon) {
        const float2 k = float2(1, -1);
        float3 gradient = k.xyy * shapeDistance(instructions, count, position + k.xyy * epsilon)
            + k.yyx * shapeDistance(instructions, count, position + k.yyx * epsilon)
            + k.yxy * shapeDistance(instructions, count, position + k.yxy * epsilon)
            + k.xxx * shapeDistance(instructions, count, position + k.xxx * epsilon);
        return length_squared(gradient) > 0 ? normalize(gradient) : float3(0, 1, 0);
    }

    struct Fragment {
        float4 position [[position]];
        // Camera-relative world position on the proxy box.
        float3 worldPosition;
        uint view [[flat]];
    };

    struct Output {
        float4 color [[color(0)]];
        float depth [[depth(any)]];
    };

    // 36 corner indices of the proxy box, counter-clockwise seen from outside. Corner i is (i & 1, i & 2, i & 4).
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
        constant SignedDistanceUniforms &uniforms [[buffer(2)]]
    ) {
        ushort corner = boxIndices[vertexID];
        float3 select = float3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        float3 local = mix(uniforms.boundsMin, uniforms.boundsMax, select);
        float4 world = uniforms.modelMatrix * float4(local, 1);
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
        constant SignedDistanceUniforms &uniforms [[buffer(4)]],
        constant SignedDistanceInstruction *instructions [[buffer(5)]],
        // Screen-space ambient visibility; 1x1 white when off.
        texture2d<float, access::read> ambientOcclusion [[texture(6)]],
        depth2d_array<float, access::sample> shadowMap [[texture(3), function_constant(HAS_SHADOWS)]],
        sampler shadowSampler [[sampler(1), function_constant(HAS_SHADOWS)]],
        constant BlinnPhongShadowUniforms &shadow [[buffer(3), function_constant(HAS_SHADOWS)]]
    ) {
        // The ray in shape space, with a unit direction so marched distances are shape-space distances.
        float3 camera = frame.cameraPositions[in.view];
        float3 worldDirection = normalize(in.worldPosition - camera);
        float3 origin = (uniforms.inverseModelMatrix * float4(camera, 1)).xyz;
        float3 direction = normalize((uniforms.inverseModelMatrix * float4(worldDirection, 0)).xyz);

        // Where the ray is inside the proxy box. Behind the camera does not count.
        float3 inverseDirection = 1.0 / direction;
        float3 t0 = (uniforms.boundsMin - origin) * inverseDirection;
        float3 t1 = (uniforms.boundsMax - origin) * inverseDirection;
        float3 nearT = min(t0, t1);
        float3 farT = max(t0, t1);
        float enter = max(max(max(nearT.x, nearT.y), nearT.z), 0.0);
        float exit = min(min(farT.x, farT.y), farT.z);
        if (enter >= exit) {
            discard_fragment();
        }

        float t = enter;
        bool hit = false;
        for (int step = 0; step < uniforms.maxSteps && t <= exit; step++) {
            float distance = shapeDistance(instructions, uniforms.instructionCount, origin + direction * t);
            if (distance < uniforms.hitThreshold * max(t, 1e-3)) {
                hit = true;
                break;
            }
            t += distance * uniforms.stepScale;
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
        float3 localNormal = shapeNormal(instructions, uniforms.instructionCount, local, max(uniforms.hitThreshold * t, 1e-4));
        float3 normal = normalize(uniforms.normalMatrix * localNormal);

        BlinnPhong::Surface surface = { material.ambient, material.diffuse, material.specular, material.emission, material.shininess, material.opacity, material.receivesShadow != 0 };
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
