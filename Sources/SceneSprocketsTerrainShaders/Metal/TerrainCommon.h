#pragma once

#include <metal_stdlib>
#include "TerrainTypes.h"
#include "TerrainNoise.h"

using namespace metal;

// Filmic tone map (Narkowicz ACES fit) and gamma, shared by sky and terrain so they match.
inline float4 displayColor(float3 color, constant TerrainMaterial &material) {
    color *= material.exposure;
    color = saturate((color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14));
    return float4(pow(color, 1.0 / 2.2), 1);
}

// Texture coordinate of world `xz` in a property texture with `placement` (origin x, origin z, extent, unused).
inline float2 propertyCoordinate(float2 xz, float4 placement) {
    return (xz - placement.xy) / placement.z + 0.5;
}

// MARK: - Concurrent binary tree

// Port of libcbt (cbt.glsl). Node IDs use heap numbering: root is 1, children of n are 2n and 2n+1, and depth is
// the index of the top bit. Everything lives in one bit-packed uint array: a node at depth d stores its leaf count
// in D - d + 1 bits, and depth D is the leaf bitfield. heap[0] has bit D set and holds no node.

constant uint kMaxDepth = CBT_MAX_DEPTH;
constant uint kHeapWordCount = CBT_HEAP_WORD_COUNT;

inline uint nodeDepth(uint id) {
    return 31 - clz(id);
}

// cbt__NodeBitID: 2^(d+1) + id * (D + 1 - d).
inline uint nodeBitID(uint id, uint depth) {
    return (2u << depth) + id * (1 + kMaxDepth - depth);
}

inline uint nodeBitSize(uint depth) {
    return kMaxDepth - depth + 1;
}

struct TreeHeap {
    device atomic_uint *heap;
    // Optional. When set, leaf-bit writes mark their prepass group dirty.
    device atomic_uint *dirty = nullptr;

    // Plain load. Every read targets words that no thread of the same dispatch writes: the reduction reads levels
    // written by an earlier dispatch, and the leaf kernel's split/merge writes only touch leaf bits below nodes the
    // reduction counts as single leaves, which decoding never descends into.
    uint word(uint index) const {
        return ((device const uint *)heap)[index];
    }

    // cbt__BitFieldInsert: concurrent writers can share a word, so both halves are atomic.
    void bitFieldInsert(uint index, uint bitOffset, uint bitCount, uint bitData) const {
        uint mask = ~(~(0xFFFFFFFFu << bitCount) << bitOffset);
        atomic_fetch_and_explicit(&heap[index], mask, memory_order_relaxed);
        atomic_fetch_or_explicit(&heap[index], bitData << bitOffset, memory_order_relaxed);
    }

    // cbt__HeapWriteExplicit / cbt__HeapReadExplicit: a field can straddle two words.
    void writeExplicit(uint id, uint depth, uint bitCount, uint bitData) const {
        uint offset = nodeBitID(id, depth);
        uint lsbIndex = offset >> 5;
        uint msbIndex = min(lsbIndex + 1, kHeapWordCount - 1);
        uint lsbOffset = offset & 31u;
        uint lsbCount = min(32u - lsbOffset, bitCount);
        uint msbCount = bitCount - lsbCount;
        bitFieldInsert(lsbIndex, lsbOffset, lsbCount, bitData);
        bitFieldInsert(msbIndex, 0, msbCount, bitData >> lsbCount);
    }

    uint read(uint id) const {
        uint depth = nodeDepth(id);
        uint bitCount = nodeBitSize(depth);
        uint offset = nodeBitID(id, depth);
        uint lsbIndex = offset >> 5;
        uint msbIndex = min(lsbIndex + 1, kHeapWordCount - 1);
        uint lsbOffset = offset & 31u;
        uint lsbCount = min(32u - lsbOffset, bitCount);
        uint msbCount = bitCount - lsbCount;
        uint lsb = (word(lsbIndex) >> lsbOffset) & ~(0xFFFFFFFFu << lsbCount);
        uint msb = word(msbIndex) & ~(0xFFFFFFFFu << msbCount);
        return lsb | (msb << lsbCount);
    }

    void write(uint id, uint value) const {
        uint depth = nodeDepth(id);
        writeExplicit(id, depth, nodeBitSize(depth), value);
    }

    // cbt__HeapWrite_BitField: sets the leaf bit of the node's ceil node (its leftmost depth-D descendant).
    void writeLeafBit(uint id, uint value) const {
        uint ceil = id << (kMaxDepth - nodeDepth(id));
        uint bit = nodeBitID(ceil, kMaxDepth);
        atomic_fetch_and_explicit(&heap[bit >> 5], ~(1u << (bit & 31u)), memory_order_relaxed);
        atomic_fetch_or_explicit(&heap[bit >> 5], value << (bit & 31u), memory_order_relaxed);
        if (dirty) {
            uint group = (ceil - (1u << kMaxDepth)) >> CBT_PREPASS_GROUP_SHIFT;
            atomic_fetch_or_explicit(&dirty[group >> 5], 1u << (group & 31u), memory_order_relaxed);
        }
    }

    uint leafCount() const {
        return read(1);
    }

    // cbt_SplitNode: sets the right child's bit. cbt_MergeNode: clears the right sibling's bit.
    void splitNode(uint id) const {
        if (nodeDepth(id) < kMaxDepth) {
            writeLeafBit(2 * id + 1, 1);
        }
    }

    void mergeNode(uint id) const {
        if (id > 1) {
            writeLeafBit(id | 1u, 0);
        }
    }

    // cbt_DecodeNode: the k-th leaf.
    uint decodeLeaf(uint k) const {
        uint id = 1;
        while (read(id) > 1) {
            uint left = read(2 * id);
            uint b = k < left ? 0 : 1;
            id = 2 * id | b;
            k -= left * b;
        }
        return id;
    }
};

// MARK: - Longest edge bisection over a square (two base triangles, IDs 2 and 3)

inline uint bitValue(uint id, int bit) {
    return (id >> uint(bit)) & 1u;
}

struct Triangle {
    float2 v0; // hypotenuse is v0-v2, apex is v1
    float2 v1;
    float2 v2;
};

// Unit-square vertices of a node.
inline Triangle decodeTriangle(uint id) {
    int depth = int(nodeDepth(id));
    Triangle t;
    if (bitValue(id, depth - 1) == 0) {
        t = { float2(0, 1), float2(0, 0), float2(1, 0) };
    } else {
        t = { float2(1, 0), float2(1, 1), float2(0, 1) };
    }
    for (int bit = depth - 2; bit >= 0; --bit) {
        float2 mid = (t.v0 + t.v2) * 0.5;
        if (bitValue(id, bit) == 0) {
            t = { t.v0, mid, t.v1 };
        } else {
            t = { t.v1, mid, t.v2 };
        }
    }
    return t;
}

// Same-depth neighbors. 0 means none (boundary). left shares v1-v2, right shares v0-v1, edge shares v0-v2.
struct NeighborIDs {
    uint left;
    uint right;
    uint edge;
    uint node;
};

inline NeighborIDs splitNeighborIDs(NeighborIDs n, uint bit) {
    uint rightBit = n.right == 0 ? 0 : 1;
    uint edgeBit = n.edge == 0 ? 0 : 1;
    if (bit == 0) {
        return { n.node << 1 | 1, n.edge << 1 | edgeBit, n.right << 1 | rightBit, n.node << 1 };
    }
    return { n.edge << 1, n.node << 1, n.left << 1, n.node << 1 | 1 };
}

inline uint edgeNeighbor(uint id) {
    int depth = int(nodeDepth(id));
    uint base = bitValue(id, depth - 1);
    NeighborIDs n = { 0, 0, 3 - base, 2 + base };
    for (int bit = depth - 2; bit >= 0; --bit) {
        n = splitNeighborIDs(n, bitValue(id, bit));
    }
    return n.edge;
}

// Heights come from two clipmap levels (ClipLevel), each a pair of textures: `moments` (height, height²) in meters
// with mipmaps that average both (the demo's dmap moments) and `heights`, a single-channel copy of mip 0. Level 0
// (detailSize around detailOrigin) is fine; the outer level ("far") is coarser and covers the whole CBT square, so
// distant terrain exists. Each texture is addressed by world position, coordinate = xz / levelSize + 0.5, and wraps
// when streaming (each texel holds the world position that maps onto it modulo the size), so samplers repeat. An image
// heightmap is a single level, bound as both.
constexpr sampler heightSampler(filter::linear, mip_filter::linear, address::repeat);

// 1 near the camera, fading to 0 further out, where only the outer level is used. The fade is centered on the camera,
// not on level 0, so it moves smoothly instead of jumping when level 0 moves by a chunk. The camera stays within one
// chunk (1/8 of the level) of level 0's center, so the fade ends inside it.
inline float detailWeight(float2 xz, constant TerrainUniforms &uniforms) {
    float2 offset = abs(xz - uniforms.cameraPosition.xz) / uniforms.detailSize;
    return 1.0 - smoothstep(0.27, 0.37, max(offset.x, offset.y));
}

// The lowest drawn height (uniforms.heightFloor), or -infinity for none. Applied after filtering, so where signed
// stored heights cross the floor the contour is smooth instead of following the texel grid.
inline float heightFloorOf(constant TerrainUniforms &uniforms) {
    return uniforms.hasHeightFloor ? uniforms.heightFloor : -INFINITY;
}

inline float sampleHeight(texture2d<float> heights, float2 xz, float levelSize, float floor) {
    return max(heights.sample(heightSampler, xz / levelSize + 0.5, level(0)).r, floor);
}

inline float terrainHeightAt(float2 xz, texture2d<float> heights, texture2d<float> farHeights, constant TerrainUniforms &uniforms) {
    float weight = detailWeight(xz, uniforms);
    float floor = heightFloorOf(uniforms);
    float far = weight < 1.0 ? sampleHeight(farHeights, xz, uniforms.cbtSize, floor) : 0.0;
    float near = weight > 0.0 ? sampleHeight(heights, xz, uniforms.detailSize, floor) : 0.0;
    return mix(far, near, weight) * uniforms.heightExaggeration;
}

struct SurfaceSample {
    float height;
    float3 normal;
};

// Height and normal from one level, the normal by central differences one texel apart. Heights are multiplied by
// `exaggeration`.
inline SurfaceSample levelSurface(float2 xz, texture2d<float> heights, float levelSize, float exaggeration, float floor) {
    float texelMeters = levelSize / float(heights.get_width());
    float h = sampleHeight(heights, xz, levelSize, floor);
    float dx = sampleHeight(heights, xz + float2(texelMeters, 0), levelSize, floor) - sampleHeight(heights, xz - float2(texelMeters, 0), levelSize, floor);
    float dz = sampleHeight(heights, xz + float2(0, texelMeters), levelSize, floor) - sampleHeight(heights, xz - float2(0, texelMeters), levelSize, floor);
    return { h * exaggeration, normalize(float3(-dx * exaggeration, 2.0 * texelMeters, -dz * exaggeration)) };
}

// Height and normal at the heightmap's resolution, so shading does not depend on the mesh LOD.
inline SurfaceSample terrainSurface(float2 xz, texture2d<float> heights, texture2d<float> farHeights, constant TerrainUniforms &uniforms) {
    float weight = detailWeight(xz, uniforms);
    if (weight >= 1.0) {
        return levelSurface(xz, heights, uniforms.detailSize, uniforms.heightExaggeration, heightFloorOf(uniforms));
    }
    SurfaceSample far = levelSurface(xz, farHeights, uniforms.cbtSize, uniforms.heightExaggeration, heightFloorOf(uniforms));
    if (weight <= 0.0) {
        return far;
    }
    SurfaceSample near = levelSurface(xz, heights, uniforms.detailSize, uniforms.heightExaggeration, heightFloorOf(uniforms));
    return { mix(far.height, near.height, weight), normalize(mix(far.normal, near.normal, weight)) };
}

inline float3 worldPosition(float2 unit, texture2d<float> heights, texture2d<float> farHeights, constant TerrainUniforms &uniforms) {
    float2 xz = (unit - 0.5) * uniforms.cbtSize + uniforms.cbtOrigin;
    // Keep edge vertices within the outer texel centers, so linear filtering doesn't wrap to the far edge.
    float halfTexel = 0.5 / float(farHeights.get_width());
    float2 inside = (clamp(unit, halfTexel, 1.0 - halfTexel) - 0.5) * uniforms.cbtSize + uniforms.cbtOrigin;
    return float3(xz.x, terrainHeightAt(inside, heights, farHeights, uniforms), xz.y);
}
