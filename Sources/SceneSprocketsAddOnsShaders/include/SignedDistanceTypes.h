#pragma once

#import <simd/simd.h>

// Signed distance shapes as a postfix program: primitives push a distance, combine ops pop two and push one.
#define SIGNED_DISTANCE_OP_SPHERE 0
#define SIGNED_DISTANCE_OP_ROUNDED_BOX 1
#define SIGNED_DISTANCE_OP_CAPSULE 2
#define SIGNED_DISTANCE_OP_SMOOTH_UNION 3
// The second operand is cut out of the first.
#define SIGNED_DISTANCE_OP_SMOOTH_SUBTRACTION 4
#define SIGNED_DISTANCE_OP_SMOOTH_INTERSECTION 5

// The deepest stack a program may need.
#define kSignedDistanceMaxStackDepth 16

struct SignedDistanceInstruction {
    // Primitives: shape space to the primitive's own space.
    simd_float4x4 inverseTransform;
    // Sphere: radius in x. Rounded box: half size in xyz, corner radius in w. Capsule: start in xyz, radius in w.
    simd_float4 parameters;
    // Capsule: end in xyz.
    simd_float4 end;
    int operation;
    // Combine ops: the blend distance; 0 is a sharp edge.
    float smoothing;
    // Primitives: the transform's smallest axis scale, which keeps distances from overshooting.
    float scale;
    int padding;
};
typedef struct SignedDistanceInstruction SignedDistanceInstruction;

// One SDF node's draw.
struct SignedDistanceUniforms {
    // Shape space to camera-relative world space.
    simd_float4x4 modelMatrix;
    simd_float4x4 inverseModelMatrix;
    // Shape space normals to world space.
    simd_float3x3 normalMatrix;
    // The proxy box, in shape space.
    simd_float3 boundsMin;
    simd_float3 boundsMax;
    int instructionCount;
    int maxSteps;
    // A hit is closer than this times the distance along the ray.
    float hitThreshold;
    // Below 1 for shapes whose distances overshoot.
    float stepScale;
};
typedef struct SignedDistanceUniforms SignedDistanceUniforms;
