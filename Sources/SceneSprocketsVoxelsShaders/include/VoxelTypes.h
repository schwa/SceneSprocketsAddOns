#pragma once

#import <simd/simd.h>

// One voxel node's draw. Grid space has one unit per voxel, with the grid from 0 to `size`.
struct VoxelUniforms {
    // Grid space to camera-relative world space.
    simd_float4x4 modelMatrix;
    simd_float4x4 inverseModelMatrix;
    // Grid space normals to world space.
    simd_float3x3 normalMatrix;
    simd_int3 size;
};
typedef struct VoxelUniforms VoxelUniforms;
