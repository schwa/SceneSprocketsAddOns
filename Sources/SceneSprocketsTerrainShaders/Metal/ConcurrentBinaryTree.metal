#include "TerrainCommon.h"

// MARK: - Sum reduction

// Ors a bit field into threadgroup words. A field can straddle two words.
inline void packField(threadgroup atomic_uint *words, uint bitOffset, uint bitCount, uint data) {
    uint index = bitOffset >> 5;
    uint shift = bitOffset & 31u;
    atomic_fetch_or_explicit(&words[index], data << shift, memory_order_relaxed);
    if (shift + bitCount > 32) {
        atomic_fetch_or_explicit(&words[index + 1], data >> (32 - shift), memory_order_relaxed);
    }
}

// cbt_SumReductionPrepass, one thread per 32-bit word of leaf bits, in threadgroups of CBT_PREPASS_GROUP.
// SWAR sums give depths D-1 ... D-5. A group's fields at each of those depths cover whole heap words, so they are
// packed in threadgroup memory and stored without device atomics. The group then sums its 256 depth D-5 counts in
// threadgroup memory, filling depths D-6 ... D-13.
constant uint kPrepassGroup = 256;
constant uint kPackedOffset2 = 0;                                       // 24 bits per thread
constant uint kPackedOffset3 = kPackedOffset2 + kPrepassGroup * 24 / 32; // 16 bits
constant uint kPackedOffset4 = kPackedOffset3 + kPrepassGroup * 16 / 32; // 10 bits
constant uint kPackedOffset5 = kPackedOffset4 + kPrepassGroup * 10 / 32; // 6 bits
constant uint kPackedWords = kPackedOffset5 + kPrepassGroup * 6 / 32;

kernel void cbt_reduce_words(
    device atomic_uint *heap [[buffer(0)]],
    device atomic_uint *dirty [[buffer(1)]],
    uint word [[thread_position_in_grid]],
    uint local [[thread_position_in_threadgroup]],
    uint groupIndex [[threadgroup_position_in_grid]]
) {
    threadgroup atomic_uint packed[kPackedWords];
    threadgroup uint sums[kPrepassGroup];

    // Unchanged leaf bits leave this group's heap fields (depths D-1 ... D-13) valid from an earlier frame.
    uint dirtyBit = 1u << (groupIndex & 31u);
    if ((atomic_load_explicit(&dirty[groupIndex >> 5], memory_order_relaxed) & dirtyBit) == 0) {
        return;
    }
    threadgroup_barrier(mem_flags::mem_device);
    if (local == 0) {
        atomic_fetch_and_explicit(&dirty[groupIndex >> 5], ~dirtyBit, memory_order_relaxed);
    }
    for (uint i = local; i < kPackedWords; i += kPrepassGroup) {
        atomic_store_explicit(&packed[i], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    TreeHeap tree = { heap };
    uint count = 1u << kMaxDepth;
    uint nodeID = (word << 5) + count;
    uint groupNodeID = ((word - local) << 5) + count;
    uint alignedBitOffset = nodeBitID(nodeID, kMaxDepth);
    uint bitField = tree.word(alignedBitOffset >> 5);

    // 2-bit counts: the 16 nodes at depth D-1 fill one whole word, owned by this thread.
    bitField = (bitField & 0x55555555u) + ((bitField >> 1) & 0x55555555u);
    atomic_store_explicit(&heap[(alignedBitOffset - count) >> 5], bitField, memory_order_relaxed);

    // 3-bit counts
    bitField = (bitField & 0x33333333u) + ((bitField >> 2) & 0x33333333u);
    uint bitData = ((bitField >> 0) & (7u << 0))
        | ((bitField >> 1) & (7u << 3))
        | ((bitField >> 2) & (7u << 6))
        | ((bitField >> 3) & (7u << 9))
        | ((bitField >> 4) & (7u << 12))
        | ((bitField >> 5) & (7u << 15))
        | ((bitField >> 6) & (7u << 18))
        | ((bitField >> 7) & (7u << 21));
    packField(packed + kPackedOffset2, local * 24, 24, bitData);

    // 4-bit counts
    bitField = (bitField & 0x0F0F0F0Fu) + ((bitField >> 4) & 0x0F0F0F0Fu);
    bitData = ((bitField >> 0) & (15u << 0))
        | ((bitField >> 4) & (15u << 4))
        | ((bitField >> 8) & (15u << 8))
        | ((bitField >> 12) & (15u << 12));
    packField(packed + kPackedOffset3, local * 16, 16, bitData);

    // 5-bit counts
    bitField = (bitField & 0x00FF00FFu) + ((bitField >> 8) & 0x00FF00FFu);
    bitData = ((bitField >> 0) & (31u << 0)) | ((bitField >> 11) & (31u << 5));
    packField(packed + kPackedOffset4, local * 10, 10, bitData);

    // 6-bit count
    uint value = (bitField & 0x0000FFFFu) + ((bitField >> 16) & 0x0000FFFFu);
    packField(packed + kPackedOffset5, local * 6, 6, value);
    sums[local] = value;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const uint offsets[5] = { kPackedOffset2, kPackedOffset3, kPackedOffset4, kPackedOffset5, kPackedWords };
    for (uint level = 2; level <= 5; ++level) {
        uint first = offsets[level - 2];
        uint size = offsets[level - 1] - first;
        uint heapWord = nodeBitID(groupNodeID >> level, kMaxDepth - level) >> 5;
        for (uint i = local; i < size; i += kPrepassGroup) {
            uint packedWord = atomic_load_explicit(&packed[first + i], memory_order_relaxed);
            atomic_store_explicit(&heap[heapWord + i], packedWord, memory_order_relaxed);
        }
    }

    // Depths D-6 ... D-13
    for (uint shift = 1; (kPrepassGroup >> shift) > 0; ++shift) {
        uint width = kPrepassGroup >> shift;
        if (local < width) {
            value = sums[2 * local] + sums[2 * local + 1];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (local < width) {
            sums[local] = value;
            tree.write((groupNodeID >> (5 + shift)) + local, value);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// cbt_SumReduction over several levels per dispatch. One thread per node at `level` reads its two children from the
// heap; the threadgroup then sums upward in threadgroup memory, writing each level, until one node per threadgroup
// remains. The threadgroup size must be a power of two that divides 2^level.
kernel void cbt_reduce_level(
    device atomic_uint *heap [[buffer(0)]],
    constant uint &level [[buffer(1)]],
    uint index [[thread_position_in_grid]],
    uint local [[thread_position_in_threadgroup]],
    uint groupSize [[threads_per_threadgroup]]
) {
    threadgroup uint sums[256];
    TreeHeap tree = { heap };
    uint id = (1u << level) + index;
    uint value = tree.read(2 * id) + tree.read(2 * id + 1);
    tree.write(id, value);
    sums[local] = value;
    uint firstID = id - local;
    for (uint shift = 1; (groupSize >> shift) > 0; ++shift) {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        uint width = groupSize >> shift;
        if (local < width) {
            value = sums[2 * local] + sums[2 * local + 1];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (local < width) {
            sums[local] = value;
            tree.write((firstID >> shift) + local, value);
        }
    }
}

// MARK: - Indirect arguments

kernel void cbt_prepare_arguments(
    device atomic_uint *heap [[buffer(0)]],
    device uint *arguments [[buffer(1)]],
    constant TerrainUniforms &uniforms [[buffer(2)]]
) {
    TreeHeap tree = { heap };
    uint leaves = min(tree.leafCount(), uint(CBT_MAX_LEAVES));
    // The draw count is complete here: last frame's leaf kernel finished before this dispatch.
    arguments[CBT_ARGS_STATS_VISIBLE] = arguments[CBT_ARGS_DRAW + 1];
    arguments[CBT_ARGS_STATS_LEAVES] = tree.leafCount();
    arguments[CBT_ARGS_DISPATCH + 0] = (leaves + 63) / 64;
    arguments[CBT_ARGS_DISPATCH + 1] = 1;
    arguments[CBT_ARGS_DISPATCH + 2] = 1;
    arguments[CBT_ARGS_DRAW + 0] = 3u << (2 * uniforms.meshletSubdivision); // indexCount
    arguments[CBT_ARGS_DRAW + 1] = 0; // instanceCount, accumulated by cbt_decode
    arguments[CBT_ARGS_DRAW + 2] = 0; // indexStart
    arguments[CBT_ARGS_DRAW + 3] = 0; // baseVertex
    arguments[CBT_ARGS_DRAW + 4] = 0; // baseInstance
}

// MARK: - Visibility and LOD

struct WorldTriangle {
    float3 p0;
    float3 p1;
    float3 p2;
};

inline WorldTriangle worldTriangle(uint id, texture2d<float> heights, texture2d<float> farHeights, constant TerrainUniforms &uniforms) {
    Triangle t = decodeTriangle(id);
    return {
        worldPosition(t.v0, heights, farHeights, uniforms),
        worldPosition(t.v1, heights, farHeights, uniforms),
        worldPosition(t.v2, heights, farHeights, uniforms),
    };
}

// Conservative: the surface between vertices can rise above them, so pad the box by part of the edge length.
inline bool isVisible(WorldTriangle t, constant TerrainUniforms &uniforms) {
    float edge = distance(t.p0.xz, t.p2.xz);
    float pad = min(edge * 0.5, uniforms.heightScale * 2.0);
    float3 lower = min(min(t.p0, t.p1), t.p2) - float3(0, pad, 0);
    float3 upper = max(max(t.p0, t.p1), t.p2) + float3(0, pad, 0);
    for (int i = 0; i < 4; ++i) {
        float4 plane = uniforms.frustumPlanes[i];
        float3 corner = select(lower, upper, plane.xyz > 0);
        if (dot(plane.xyz, corner) + plane.w < 0) {
            return false;
        }
    }
    return true;
}

// DisplacementVarianceTest from the demo: the mip level matching the triangle's footprint gives the mean of h and
// h² over it, so variance = E[h²] - E[h]².
// The footprint is measured in the level that supplies most of the triangle center's height.
inline bool isRoughEnough(uint id, texture2d<float> moments, texture2d<float> farMoments, constant TerrainUniforms &uniforms) {
    Triangle t = decodeTriangle(id);
    float2 center = ((t.v0 + t.v1 + t.v2) / 3.0 - 0.5) * uniforms.cbtSize + uniforms.cbtOrigin;
    float2 edge0 = t.v0 - t.v1;
    float2 edge1 = t.v2 - t.v1;
    float2 m;
    if (detailWeight(center, uniforms) > 0.5) {
        float scale = uniforms.cbtSize / uniforms.detailSize;
        m = moments.sample(heightSampler, center / uniforms.detailSize + 0.5, gradient2d(edge0 * scale, edge1 * scale)).rg;
    } else {
        m = farMoments.sample(heightSampler, center / uniforms.cbtSize + 0.5, gradient2d(edge0, edge1)).rg;
    }
    float exaggeration = uniforms.heightExaggeration;
    return max(m.y - m.x * m.x, 0.0) * exaggeration * exaggeration >= uniforms.minHeightVariance;
}

inline bool shouldSplit(uint id, texture2d<float> heights, texture2d<float> moments, texture2d<float> farHeights, texture2d<float> farMoments, constant TerrainUniforms &uniforms) {
    WorldTriangle t = worldTriangle(id, heights, farHeights, uniforms);
    if (!isVisible(t, uniforms) || !isRoughEnough(id, moments, farMoments, uniforms)) {
        return false;
    }
    float3 mid = (t.p0 + t.p2) * 0.5;
    float edge = distance(t.p0, t.p2);
    float dist = max(distance(mid, uniforms.cameraPosition), 0.01);
    // As in the demo's computeLodFactor, the target applies to meshlet edges, not leaf edges.
    float target = uniforms.targetEdgePixels * float(1u << uniforms.meshletSubdivision);
    return edge * uniforms.projectionScale / dist > target;
}

// MARK: - Decode leaves

// MARK: - Split / merge

// leb_SplitNode_Square: splits a node and as many neighbors as needed to keep the mesh conforming.
inline void lebSplit(TreeHeap tree, uint id) {
    tree.splitNode(id);
    uint node = edgeNeighbor(id);
    while (node > 1) {
        tree.splitNode(node);
        node >>= 1;
        if (node > 1) {
            tree.splitNode(node);
            node = edgeNeighbor(node);
        }
    }
}

// One thread per leaf: decode it, append it to the draw list if visible, then split or merge it, as in the demo's
// TerrainUpdateCS. Splits and merges only change leaf bits below nodes the reduction counts as single leaves, and
// decoding never descends below those, so threads don't see each other's writes.
kernel void cbt_update(
    device atomic_uint *heap [[buffer(0)]],
    device uint *visibleIDs [[buffer(1)]],
    device atomic_uint *arguments [[buffer(2)]],
    constant TerrainUniforms &uniforms [[buffer(3)]],
    texture2d<float> heights [[texture(0)]],
    texture2d<float> moments [[texture(1)]],
    texture2d<float> farHeights [[texture(2)]],
    texture2d<float> farMoments [[texture(3)]],
    device atomic_uint *dirty [[buffer(4)]],
    uint index [[thread_position_in_grid]]
) {
    TreeHeap tree = { heap, dirty };
    uint leafCount = tree.leafCount();
    if (index >= min(leafCount, uint(CBT_MAX_LEAVES))) {
        return;
    }
    uint id = tree.decodeLeaf(index);
    uint depth = nodeDepth(id);
    if (isVisible(worldTriangle(id, heights, farHeights, uniforms), uniforms)) {
        uint instance = atomic_fetch_add_explicit(&arguments[CBT_ARGS_DRAW + 1], 1, memory_order_relaxed);
        visibleIDs[instance] = id;
    }

    // The leaf cap is ours: visibleIDs has fixed capacity.
    if (uniforms.updateMode == 0) {
        if (depth < kMaxDepth && leafCount < CBT_MAX_LEAVES / 2 && shouldSplit(id, heights, moments, farHeights, farMoments, uniforms)) {
            lebSplit(tree, id);
        }
    } else if (uniforms.updateMode == 1) {
        // leb_MergeNode_Square: each leaf of a diamond merges its own parent once both halves are coarse enough.
        if (depth <= 1) {
            return;
        }
        uint base = id >> 1;
        uint top = edgeNeighbor(base);
        if (top == 0) {
            top = base;
        }
        if (shouldSplit(base, heights, moments, farHeights, farMoments, uniforms) || shouldSplit(top, heights, moments, farHeights, farMoments, uniforms)) {
            return;
        }
        if (tree.read(base) <= 2 && tree.read(top) <= 2) {
            tree.mergeNode(id);
        }
    }
}
