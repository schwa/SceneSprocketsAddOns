#include <metal_stdlib>
#include "SceneSprocketsAddOnsShaders.h"
#include "BlinnPhongLighting.h"
#include "PBRLighting.h"

using namespace metal;

// Raymarched signed distance shapes. Each node draws the back faces of its proxy box; the fragment shader marches the
// part of the view ray inside the box, then lights the hit (Blinn-Phong or PBR) and writes its depth. The shadow
// pass marches rays from the light the same way and writes only depth.
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

    struct Hit {
        bool hit;
        // Along the shape-space ray, which has a unit direction.
        float t;
        // Shape space.
        float3 position;
    };

    // Marches a camera-relative world ray through the shape. `worldDirection` need not be normalized.
    inline Hit march(float3 worldOrigin, float3 worldDirection, constant SignedDistanceUniforms &uniforms, constant SignedDistanceInstruction *instructions) {
        float3 origin = (uniforms.inverseModelMatrix * float4(worldOrigin, 1)).xyz;
        float3 direction = normalize((uniforms.inverseModelMatrix * float4(worldDirection, 0)).xyz);

        // Where the ray is inside the proxy box. Behind the origin does not count.
        float3 inverseDirection = 1.0 / direction;
        float3 t0 = (uniforms.boundsMin - origin) * inverseDirection;
        float3 t1 = (uniforms.boundsMax - origin) * inverseDirection;
        float3 nearT = min(t0, t1);
        float3 farT = max(t0, t1);
        float enter = max(max(max(nearT.x, nearT.y), nearT.z), 0.0);
        float exit = min(min(farT.x, farT.y), farT.z);
        Hit result = { false, 0, float3(0) };
        if (enter >= exit) {
            return result;
        }
        float t = enter;
        for (int step = 0; step < uniforms.maxSteps && t <= exit; step++) {
            float distance = shapeDistance(instructions, uniforms.instructionCount, origin + direction * t);
            if (distance < uniforms.hitThreshold * max(t, 1e-3)) {
                result = { true, t, origin + direction * t };
                return result;
            }
            t += distance * uniforms.stepScale;
        }
        return result;
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

    inline float4 boxCorner(uint vertexID, constant SignedDistanceUniforms &uniforms) {
        ushort corner = boxIndices[vertexID];
        float3 select = float3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);
        return uniforms.modelMatrix * float4(mix(uniforms.boundsMin, uniforms.boundsMax, select), 1);
    }

    [[vertex]] Fragment vertex_main(
        uint vertexID [[vertex_id]],
        ushort view [[amplification_id]],
        constant BlinnPhongFrame &viewFrame [[buffer(1)]],
        constant SignedDistanceUniforms &uniforms [[buffer(2)]]
    ) {
        float4 world = boxCorner(vertexID, uniforms);
        Fragment out;
        out.position = viewFrame.viewProjections[view] * world;
        out.worldPosition = world.xyz / world.w;
        out.view = view;
        return out;
    }

    // The camera-relative world hit and its depth, or false when the ray misses or the hit is outside the view.
    inline bool viewHit(Fragment in, float3 camera, float4x4 viewProjection, constant SignedDistanceUniforms &uniforms, constant SignedDistanceInstruction *instructions, thread float3 &world, thread float3 &normal, thread float &depth) {
        Hit hit = march(camera, in.worldPosition - camera, uniforms, instructions);
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
        float3 localNormal = shapeNormal(instructions, uniforms.instructionCount, hit.position, max(uniforms.hitThreshold * hit.t, 1e-4));
        normal = normalize(uniforms.normalMatrix * localNormal);
        return true;
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
        float3 camera = frame.cameraPositions[in.view];
        float3 world;
        float3 normal;
        Output out;
        if (!viewHit(in, camera, frame.viewProjections[in.view], uniforms, instructions, world, normal, out.depth)) {
            discard_fragment();
        }
        BlinnPhong::Surface surface = { material.ambient, material.diffuse, material.specular, material.emission, material.shininess, material.opacity, material.receivesShadow != 0 };
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
        constant SignedDistanceUniforms &uniforms [[buffer(5)]],
        constant SignedDistanceInstruction *instructions [[buffer(6)]],
        constant PBRFrameResources &frameResources [[buffer(7)]]
    ) {
        float3 camera = frame.cameraPositions[in.view];
        float3 world;
        float3 normal;
        Output out;
        if (!viewHit(in, camera, frame.viewProjectionMatrices[in.view], uniforms, instructions, world, normal, out.depth)) {
            discard_fragment();
        }
        PBR::Fragment surface;
        surface.position = in.position;
        surface.worldPosition = world;
        surface.normal = normal;
        surface.tangent = float4(0);
        surface.texCoord0 = float2(0);
        surface.texCoord1 = float2(0);
        surface.color = float4(1);
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

    [[vertex]] ShadowFragment shadow_vertex(
        uint vertexID [[vertex_id]],
        constant float4x4 &lightViewProjection [[buffer(1)]],
        constant SignedDistanceUniforms &uniforms [[buffer(2)]]
    ) {
        float4 world = boxCorner(vertexID, uniforms);
        ShadowFragment out;
        out.position = lightViewProjection * world;
        out.worldPosition = world.xyz / world.w;
        return out;
    }

    struct ShadowOutput {
        float depth [[depth(any)]];
    };

    [[fragment]] ShadowOutput shadow_fragment(
        ShadowFragment in [[stage_in]],
        constant float4x4 &lightViewProjection [[buffer(1)]],
        constant SignedDistanceUniforms &uniforms [[buffer(2)]],
        constant SignedDistanceInstruction *instructions [[buffer(3)]],
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
        Hit hit = march(origin, direction, uniforms, instructions);
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
        float3 localNormal = shapeNormal(instructions, uniforms.instructionCount, hit.position, max(uniforms.hitThreshold * hit.t, 1e-4));
        float facing = max(abs(dot(normalize(uniforms.normalMatrix * localNormal), direction)), 0.1);
        // A hit is up to `hitThreshold * t` off the surface, in both this pass and the scene pass.
        float tolerance = uniforms.hitThreshold * hit.t * length(uniforms.modelMatrix[0].xyz);
        float4 biased = lightViewProjection * float4(world + direction * (1.5 * texel + 2 * tolerance) / facing, 1);
        return { saturate(biased.z / biased.w) };
    }
}
