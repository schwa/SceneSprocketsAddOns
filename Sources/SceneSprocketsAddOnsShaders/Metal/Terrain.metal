#include "TerrainCommon.h"
#include "Sky.h"

// MARK: - Terrain

struct TerrainOut {
    float4 position [[position]];
    float3 worldPosition;
    uint leafID [[flat]];
};

[[vertex]] TerrainOut terrain_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    device const uint *visibleIDs [[buffer(0)]],
    constant TerrainUniforms &uniforms [[buffer(1)]],
    texture2d<float> heights [[texture(0)]],
    texture2d<float> farHeights [[texture(1)]]
) {
    uint leafID = visibleIDs[instanceID];
    Triangle t = decodeTriangle(leafID);
    // Bisection flips winding every level (libleb fixes this with its winding matrix). Mirroring the meshlet
    // by swapping v0 and v2 gives every leaf the same winding so back faces can be culled.
    float2 e0 = t.v0 - t.v1;
    float2 e2 = t.v2 - t.v1;
    if (e0.x * e2.y - e0.y * e2.x < 0) {
        t = { t.v2, t.v1, t.v0 };
    }

    // Meshlet vertex on lattice point (a, b), a + b <= n, measured from the apex v1. The index buffer
    // (Terrain.meshletIndices) numbers them by s = a + b, then a: index = s(s+1)/2 + a.
    float n = float(1u << uniforms.meshletSubdivision);
    uint s = uint((sqrt(8.0 * float(vertexID) + 1.0) - 1.0) * 0.5);
    s += (s + 1) * (s + 2) / 2 <= vertexID ? 1 : 0;
    s -= s * (s + 1) / 2 > vertexID ? 1 : 0;
    uint a = vertexID - s * (s + 1) / 2;
    uint2 lattice = uint2(a, s - a);
    float2 unit = t.v1 + (float(lattice.x) / n) * (t.v0 - t.v1) + (float(lattice.y) / n) * (t.v2 - t.v1);
    float3 world = worldPosition(unit, heights, farHeights, uniforms);
    return { uniforms.viewProjection * float4(world, 1), world, leafID };
}

// Shades a terrain fragment in linear color, before tone mapping.
// Material blend and sun/sky lighting for a surface point, before fog and tone mapping.
constexpr sampler blendNoiseSampler(filter::linear, mip_filter::linear, address::repeat);

// 0 outside (band.x, band.w), 1 inside [band.y, band.z], smoothstep between. `scale` holds 1 / fade width for the
// fade in and fade out, so this is branch- and divide-free.
inline float bandWeight(float x, float4 band, float2 scale) {
    float2 t = saturate(float2(x - band.x, band.w - x) * scale);
    t = t * t * (3.0 - 2.0 * t);
    return t.x * t.y;
}

// Terrain shape at a point, from the mipmapped (h, h²) moments: (curvature, valley depth). See TerrainLayer.
// `h` and `heightScale` include the height exaggeration; the stored moments are multiplied by it here.
inline float2 terrainFeatures(float2 xz, float h, texture2d<float> moments, float levelSize, float heightScale, float exaggeration) {
    float2 unit = xz / levelSize + 0.5;
    float metersPerTexel = levelSize / float(moments.get_width());
    float curvatureLevel = max(log2(32.0 / metersPerTexel), 0.0);
    float valleyLevel = max(log2(512.0 / metersPerTexel), 0.0);
    float nearby = moments.sample(heightSampler, unit, level(curvatureLevel)).r * exaggeration;
    float wide = moments.sample(heightSampler, unit, level(valleyLevel)).r * exaggeration;
    float curvatureRadius = metersPerTexel * exp2(curvatureLevel);
    return float2((nearby - h) / curvatureRadius, (wide - h) / heightScale);
}

// terrainFeatures from level 0 and the outer level, blended like the heights.
inline float2 terrainFeaturesAt(float2 xz, float h, texture2d<float> moments, texture2d<float> farMoments, constant TerrainUniforms &uniforms) {
    float weight = detailWeight(xz, uniforms);
    float2 far = weight < 1.0 ? terrainFeatures(xz, h, farMoments, uniforms.cbtSize, uniforms.heightScale, uniforms.heightExaggeration) : float2(0);
    float2 near = weight > 0.0 ? terrainFeatures(xz, h, moments, uniforms.detailSize, uniforms.heightScale, uniforms.heightExaggeration) : float2(0);
    return mix(far, near, weight);
}

// Paints the layer stack. `UsesShape` compiles the curvature/valley/aspect tests in; without them the unrolled loop is
// noticeably cheaper, so callers pick the variant once from the material-wide mask.
// Per-pixel inputs that only some layers use: shape features and the color/mask map samples.
struct TerrainExtras {
    float detail;                  // detail noise value in [-1, 1], 0 when out of range
    float2 features;
    float3 mapColor;
    float4 mask;
};

template <bool UsesShape>
inline float3 terrainAlbedo(
    float altitude,
    float slope,
    float n,
    float3 normal,
    TerrainExtras extras,
    constant TerrainMaterial &material,
    constant TerrainLayer *layers
) {
    float3 albedo = 0;
    for (uint i = 0; i < material.layerCount; ++i) {
        constant TerrainLayer &layer = layers[i];
        float weight = bandWeight(altitude + n * layer.altitudeNoise, layer.altitudeBand, layer.fadeScale.xy)
            * bandWeight(slope + n * layer.slopeNoise, layer.slopeBand, layer.fadeScale.zw)
            * layer.opacity;
        if (UsesShape) {
            // Open-ended shape bands are skipped; the mask is the same for every pixel, so the branches are coherent.
            if (layer.featureMask & 1) {
                weight *= bandWeight(extras.features.x, layer.curvatureBand, layer.featureFadeScale.xy);
            }
            if (layer.featureMask & 2) {
                weight *= bandWeight(extras.features.y, layer.valleyBand, layer.featureFadeScale.zw);
            }
            if (layer.featureMask & 4) {
                weight *= bandWeight(dot(normal.xz, layer.aspectDirection), layer.aspectBand, layer.aspectFadeScale);
            }
            if (layer.featureMask & 16) {
                weight *= extras.mask[layer.maskChannel];
            }
            if (layer.featureMask & 8) {
                albedo = mix(albedo, extras.mapColor, weight);
                continue;
            }
        }
        albedo = mix(albedo, layer.color * (1.0 + extras.detail * layer.colorVariation), weight);
    }
    return albedo;
}

// Mip level for a texture with `metersPerTexel` seen at `metersPerPixel` on the ground. Used instead of the hardware's
// derivative-based selection: at triangle edges those derivatives depended on draw order, so renders weren't
// repeatable (#13).
inline float mipLevel(float metersPerPixel, float metersPerTexel) {
    return max(log2(metersPerPixel / metersPerTexel), 0.0);
}

// Ground size of a pixel along its longer axis: distance over the projection scale, stretched by the viewing angle.
inline float groundMetersPerPixel(float distance, float3 normal, float3 viewDirection, constant TerrainUniforms &uniforms) {
    return distance / uniforms.projectionScale / max(abs(dot(normal, viewDirection)), 0.1);
}

inline float3 litTerrainColor(
    float2 xz,
    float metersPerPixel,          // ground size of a pixel, for texture mip levels
    float altitude,
    float3 normal,
    float2 features,
    float detail,
    float3 lightingNormal,         // normal with surface detail; materials use the smooth `normal`
    float3 sun,
    constant TerrainMaterial &material,
    constant TerrainLayer *layers,
    texture2d<float> blendNoise,
    texture2d<float> colorMap,
    texture2d<float> maskMap
) {
    float slope = normal.y;
    // Color and mask maps span the whole terrain, north (-z) at the top.
    TerrainExtras extras = { detail, features, float3(0), float4(0) };
    if (material.featureMask & 24) {
        constexpr sampler mapSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float colorLevel = mipLevel(metersPerPixel, material.colorMapPlacement.z / float(colorMap.get_width()));
        float maskLevel = mipLevel(metersPerPixel, material.maskMapPlacement.z / float(maskMap.get_width()));
        extras.mapColor = colorMap.sample(mapSampler, propertyCoordinate(xz, material.colorMapPlacement), level(colorLevel)).rgb;
        extras.mask = maskMap.sample(mapSampler, propertyCoordinate(xz, material.maskMapPlacement), level(maskLevel));
    }
    // The baked texture spans 16 noise cells.
    float noiseSpan = 16.0 * material.boundaryNoiseScale;
    float noiseLevel = mipLevel(metersPerPixel, noiseSpan / float(blendNoise.get_width()));
    float n = blendNoise.sample(blendNoiseSampler, xz / noiseSpan, level(noiseLevel)).r;
    float3 albedo = material.featureMask != 0
        ? terrainAlbedo<true>(altitude, slope, n, normal, extras, material, layers)
        : terrainAlbedo<false>(altitude, slope, n, normal, extras, material, layers);

    float diffuse = saturate(dot(lightingNormal, sun));
    float sky = 0.5 + 0.5 * lightingNormal.y;
    float3 lighting = material.sunColor * diffuse * material.sunIntensity + material.skyZenithColor * sky * material.skyLightIntensity;
    return albedo * lighting;
}

// Triplanar detail: noise sampled on the three axis planes, blended by how much the surface faces each axis.
// Returns (bumped normal, noise value).
inline float4 surfaceDetail(float3 position, float3 normal, float metersPerPixel, constant TerrainMaterial &material, texture2d<float> detailNoise) {
    constexpr sampler detailSampler(filter::linear, mip_filter::linear, address::repeat);
    // The baked texture spans 32 cells. Each plane is rotated (by about 37°, a 3-4-5 rotation) so the noise grid doesn't
    // line up with the world axes or the terrain mesh.
    const float2x2 rotation = float2x2(float2(0.8, 0.6), float2(-0.6, 0.8));
    float3 cells = position / material.detailScale;
    float lod = mipLevel(metersPerPixel, 32.0 * material.detailScale / float(detailNoise.get_width()));
    float3 top = detailNoise.sample(detailSampler, rotation * cells.xz / 32.0, level(lod)).rgb;
    float3 front = detailNoise.sample(detailSampler, rotation * cells.xy / 32.0, level(lod)).rgb;
    float3 side = detailNoise.sample(detailSampler, rotation * cells.zy / 32.0, level(lod)).rgb;
    // Rotate the slopes back into each plane's axes.
    top.yz = transpose(rotation) * top.yz;
    front.yz = transpose(rotation) * front.yz;
    side.yz = transpose(rotation) * side.yz;
    float3 weights = pow(abs(normal), 4.0);
    weights /= weights.x + weights.y + weights.z;
    float value = top.x * weights.y + front.x * weights.z + side.x * weights.x;
    // Each plane's noise slope tilts the normal within that plane, scaled down by the cell size in meters.
    float strength = material.detailStrength;
    float3 bump = float3(-top.y, 0, -top.z) * weights.y
        + float3(-front.y, -front.z, 0) * weights.z
        + float3(0, -side.z, -side.y) * weights.x;
    return float4(normalize(normal + bump * strength), value);
}

// Darkens `color` along contour lines of `altitude` (meters). Lines are about a pixel wide, every 5th twice that, and
// fade out where they would be closer than a few pixels.
inline float3 applyContours(float3 color, float altitude, constant TerrainMaterial &material) {
    if (material.contourInterval <= 0) {
        return color;
    }
    float f = altitude / material.contourInterval;
    float width = max(fwidth(f), 1e-5);
    float pixels = abs(fract(f + 0.5) - 0.5) / width;
    float isMajor = abs(fmod(round(f), 5.0)) < 0.5 ? 1.0 : 0.0;
    float line = 1.0 - smoothstep(0.5, 1.5, pixels / (1.0 + isMajor));
    float density = 1.0 - smoothstep(0.15, 0.4, width);
    return color * (1.0 - material.contourOpacity * line * density);
}

inline float3 shadeTerrain(
    TerrainOut in,
    constant TerrainUniforms &uniforms,
    constant TerrainMaterial &material,
    constant TerrainLayer *layers,
    texture2d<float> heights,
    texture2d<float> blendNoise,
    texture2d<float> moments,
    texture2d<float> colorMap,
    texture2d<float> maskMap,
    texture2d<float> detailNoise,
    texture2d<float> farHeights,
    texture2d<float> farMoments
) {
    float3 toCamera = uniforms.cameraPosition - in.worldPosition;
    float dist = length(toCamera);

    float2 xz = in.worldPosition.xz;
    SurfaceSample surface = terrainSurface(xz, heights, farHeights, uniforms);
    float h = surface.height;
    float3 normal = surface.normal;
    float metersPerPixel = groundMetersPerPixel(dist, normal, toCamera / dist, uniforms);

    // Shape features cost two texture reads; skip them when no layer uses them.
    float2 features = material.featureMask & 3 ? terrainFeaturesAt(xz, h, moments, farMoments, uniforms) : float2(0);
    float detail = 0;
    float3 lightingNormal = normal;
    float detailFade = material.detailDistance > 0 ? saturate(1.0 - dist / material.detailDistance) : 0.0;
    if (detailFade > 0) {
        float4 surface = surfaceDetail(in.worldPosition, normal, metersPerPixel, material, detailNoise);
        detail = surface.w * detailFade;
        lightingNormal = normalize(mix(normal, surface.xyz, detailFade));
    }
    float3 color = litTerrainColor(xz, metersPerPixel, h / uniforms.heightScale, normal, features, detail, lightingNormal, uniforms.sunDirection, material, layers, blendNoise, colorMap, maskMap);
    color = applyContours(color, h / uniforms.heightExaggeration, material);
    float3 sun = uniforms.sunDirection;

    float3 viewDirection = -toCamera / dist;
    // Height fog: denser in valleys, thinning with altitude, integrated along the view ray.
    float density = material.fogDensity;
    float falloff = material.fogFalloff;
    float rise = viewDirection.y * dist;
    float opticalDepth = density * dist * exp(-falloff * uniforms.cameraPosition.y);
    opticalDepth *= abs(rise) > 0.01 ? (1.0 - exp(-falloff * rise)) / (falloff * rise) : 1.0;
    float fog = 1.0 - exp(-opticalDepth);
    float3 fogColor = mix(material.fogColor, skyColor(viewDirection, sun, material), material.fogSkyBlend);
    return mix(color, fogColor, fog);
}

// Barycentrics are only requested by the wireframe variant, so the normal path doesn't pay for them.
[[fragment]] float4 terrain_fragment(
    TerrainOut in [[stage_in]],
    constant TerrainUniforms &uniforms [[buffer(0)]],
    constant TerrainMaterial &material [[buffer(1)]],
    constant TerrainLayer *layers [[buffer(2)]],
    texture2d<float> heights [[texture(0)]],
    texture2d<float> blendNoise [[texture(1)]],
    texture2d<float> moments [[texture(2)]],
    texture2d<float> colorMap [[texture(3)]],
    texture2d<float> maskMap [[texture(4)]],
    texture2d<float> detailNoise [[texture(5)]],
    texture2d<float> farHeights [[texture(6)]],
    texture2d<float> farMoments [[texture(7)]]
) {
    return displayColor(shadeTerrain(in, uniforms, material, layers, heights, blendNoise, moments, colorMap, maskMap, detailNoise, farHeights, farMoments), material);
}

[[fragment]] float4 terrain_fragment_wireframe(
    TerrainOut in [[stage_in]],
    float3 barycentric [[barycentric_coord]],
    constant TerrainUniforms &uniforms [[buffer(0)]],
    constant TerrainMaterial &material [[buffer(1)]],
    constant TerrainLayer *layers [[buffer(2)]],
    texture2d<float> heights [[texture(0)]],
    texture2d<float> blendNoise [[texture(1)]],
    texture2d<float> moments [[texture(2)]],
    texture2d<float> colorMap [[texture(3)]],
    texture2d<float> maskMap [[texture(4)]],
    texture2d<float> detailNoise [[texture(5)]],
    texture2d<float> farHeights [[texture(6)]],
    texture2d<float> farMoments [[texture(7)]]
) {
    float3 color = shadeTerrain(in, uniforms, material, layers, heights, blendNoise, moments, colorMap, maskMap, detailNoise, farHeights, farMoments);
    float3 width = fwidth(barycentric);
    float3 edge = smoothstep(float3(0), width * 1.2, barycentric);
    float line = 1.0 - min(min(edge.x, edge.y), edge.z);
    color = mix(color, float3(0.05, 0.05, 0.05), line * 0.8);
    return displayColor(color, material);
}

// MARK: - Mini-map

// Top-down view of clipmap level 0: north (-z) up, +x right. Heights come from the mipmapped moments texture so
// the map is filtered at its own resolution.
[[fragment]] float4 map_fragment(
    SkyOut in [[stage_in]],
    constant TerrainUniforms &uniforms [[buffer(0)]],
    constant TerrainMaterial &material [[buffer(1)]],
    constant TerrainLayer *layers [[buffer(2)]],
    texture2d<float> moments [[texture(0)]],
    texture2d<float> blendNoise [[texture(1)]],
    texture2d<float> colorMap [[texture(2)]],
    texture2d<float> maskMap [[texture(3)]]
) {
    float2 xz = (float2(in.ndc.x, -in.ndc.y) * 0.5) * uniforms.detailSize + uniforms.detailOrigin;
    float2 unit = xz / uniforms.detailSize + 0.5;
    float2 step = fwidth(unit);
    float exaggeration = uniforms.heightExaggeration;
    float floor = heightFloorOf(uniforms);
    auto height = [&](float2 at) { return max(moments.sample(heightSampler, at).r, floor); };
    float h = height(unit) * exaggeration;
    float dx = height(unit + float2(step.x, 0)) - height(unit - float2(step.x, 0));
    float dz = height(unit + float2(0, step.y)) - height(unit - float2(0, step.y));
    float2 spacing = 2.0 * step * uniforms.detailSize;
    float3 normal = normalize(float3(-dx * exaggeration / spacing.x, 1.0, -dz * exaggeration / spacing.y));
    // Shape features cost two texture reads; skip them when no layer uses them.
    float2 features = material.featureMask & 3 ? terrainFeatures(xz, h, moments, uniforms.detailSize, uniforms.heightScale, uniforms.heightExaggeration) : float2(0);
    // Fixed light from the north-west and above, like a shaded-relief map, so the map stays readable at any time of
    // day and doesn't depend on the scene's sun.
    const float3 mapLight = normalize(float3(-1, 1.5, -1));
    // One full-screen triangle, so derivatives are repeatable here.
    float metersPerPixel = max(step.x, step.y) * uniforms.detailSize;
    float3 color = litTerrainColor(xz, metersPerPixel, h / uniforms.heightScale, normal, features, 0.0, normal, mapLight, material, layers, blendNoise, colorMap, maskMap);
    return displayColor(applyContours(color, h / exaggeration, material), material);
}

// Clipmap level 0 as a plain contour map: dark lines on paper, nothing else. Uses material.contourInterval and
// contourOpacity; drawn in display color, without tone mapping.
[[fragment]] float4 map_contour_fragment(
    SkyOut in [[stage_in]],
    constant TerrainUniforms &uniforms [[buffer(0)]],
    constant TerrainMaterial &material [[buffer(1)]],
    texture2d<float> moments [[texture(0)]]
) {
    float2 xz = (float2(in.ndc.x, -in.ndc.y) * 0.5) * uniforms.detailSize + uniforms.detailOrigin;
    float h = max(moments.sample(heightSampler, xz / uniforms.detailSize + 0.5).r, heightFloorOf(uniforms));
    const float3 paper = float3(0.96, 0.94, 0.88);
    const float3 ink = float3(0.35, 0.22, 0.12);
    float3 lines = applyContours(float3(1), h, material);
    return float4(mix(ink, paper, lines), 1);
}

// MARK: - Debug visualization

// Polynomial fit of Google's Turbo colormap; t in [0, 1].
inline float3 turbo(float t) {
    t = saturate(t);
    const float4 kRed4 = float4(0.13572138, 4.61539260, -42.66032258, 132.13108234);
    const float4 kGreen4 = float4(0.09140261, 2.19418839, 4.84296658, -14.18503333);
    const float4 kBlue4 = float4(0.10667330, 12.64194608, -60.58204836, 110.36276771);
    const float2 kRed2 = float2(-152.94239396, 59.28637943);
    const float2 kGreen2 = float2(4.27729857, 2.82956604);
    const float2 kBlue2 = float2(-89.90310912, 27.34824973);
    float4 v4 = float4(1.0, t, t * t, t * t * t);
    float2 v2 = v4.zw * v4.z;
    return float3(dot(v4, kRed4) + dot(v2, kRed2), dot(v4, kGreen4) + dot(v2, kGreen2), dot(v4, kBlue4) + dot(v2, kBlue2));
}

// A stable, distinct color per integer.
inline float3 idColor(uint id) {
    uint h = id * 2654435761u;
    h ^= h >> 15;
    h *= 0x2c1b3c6du;
    h ^= h >> 12;
    return float3(float(h & 255u), float((h >> 8) & 255u), float((h >> 16) & 255u)) / 255.0 * 0.8 + 0.2;
}

// Same values as TerrainDebugMode in Swift.
enum DebugMode : uint {
    DebugHeight = 1, DebugSlope, DebugNormal, DebugAspect, DebugCurvature, DebugValley, DebugBoundaryNoise,
    DebugWinningLayer, DebugLayerWeight, DebugColorMap, DebugMaskMap, DebugDetail, DebugLightingOnly, DebugAlbedoOnly,
    DebugFog, DebugLeafDepth, DebugLeafID, DebugMeshletTriangle, DebugTriangleSize, DebugHeightVariance,
};

// Colors the terrain by one internal quantity instead of shading it (uniforms.debugMode). Output is not tone mapped.
[[fragment]] float4 terrain_fragment_debug(
    TerrainOut in [[stage_in]],
    float3 barycentric [[barycentric_coord]],
    uint primitive [[primitive_id]],
    constant TerrainUniforms &uniforms [[buffer(0)]],
    constant TerrainMaterial &material [[buffer(1)]],
    constant TerrainLayer *layers [[buffer(2)]],
    texture2d<float> heights [[texture(0)]],
    texture2d<float> blendNoise [[texture(1)]],
    texture2d<float> moments [[texture(2)]],
    texture2d<float> colorMap [[texture(3)]],
    texture2d<float> maskMap [[texture(4)]],
    texture2d<float> detailNoise [[texture(5)]],
    texture2d<float> farHeights [[texture(6)]],
    texture2d<float> farMoments [[texture(7)]]
) {
    float2 xz = in.worldPosition.xz;
    SurfaceSample surface = terrainSurface(xz, heights, farHeights, uniforms);
    float h = surface.height;
    float3 normal = surface.normal;
    float2 colorUnit = propertyCoordinate(xz, material.colorMapPlacement);
    float2 maskUnit = propertyCoordinate(xz, material.maskMapPlacement);
    float altitude = h / uniforms.heightScale;
    float3 toCamera = uniforms.cameraPosition - in.worldPosition;
    float metersPerPixel = groundMetersPerPixel(length(toCamera), normal, normalize(toCamera), uniforms);
    float noiseSpan = 16.0 * material.boundaryNoiseScale;
    float n = blendNoise.sample(blendNoiseSampler, xz / noiseSpan, level(mipLevel(metersPerPixel, noiseSpan / float(blendNoise.get_width())))).r;
    constexpr sampler mapSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

    float3 color = 0;
    switch (uniforms.debugMode) {
    case DebugHeight:
        color = turbo(altitude * 0.5 + 0.5);
        break;
    case DebugSlope:
        color = turbo(1.0 - normal.y);
        break;
    case DebugNormal:
        color = normal * 0.5 + 0.5;
        break;
    case DebugAspect: {
        // Hue by facing direction, faded to gray on flat ground.
        float angle = atan2(normal.x, -normal.z) / (2.0 * M_PI_F) + 0.5;
        color = mix(float3(0.5), turbo(angle), saturate(length(normal.xz) * 4.0));
        break;
    }
    case DebugCurvature:
        color = turbo(terrainFeaturesAt(xz, h, moments, farMoments, uniforms).x * 2.0 + 0.5);
        break;
    case DebugValley:
        color = turbo(terrainFeaturesAt(xz, h, moments, farMoments, uniforms).y * 3.0 + 0.5);
        break;
    case DebugBoundaryNoise:
        color = float3(n * 0.5 + 0.5);
        break;
    case DebugWinningLayer:
    case DebugLayerWeight: {
        // Each layer's visible share: its weight times what later layers leave uncovered.
        float2 features = terrainFeaturesAt(xz, h, moments, farMoments, uniforms);
        float best = -1;
        uint winner = 0;
        float chosen = 0;
        float uncovered = 1;
        for (int i = int(material.layerCount) - 1; i >= 0; --i) {
            constant TerrainLayer &layer = layers[i];
            float weight = bandWeight(altitude + n * layer.altitudeNoise, layer.altitudeBand, layer.fadeScale.xy)
                * bandWeight(normal.y + n * layer.slopeNoise, layer.slopeBand, layer.fadeScale.zw) * layer.opacity;
            if (layer.featureMask & 1) {
                weight *= bandWeight(features.x, layer.curvatureBand, layer.featureFadeScale.xy);
            }
            if (layer.featureMask & 2) {
                weight *= bandWeight(features.y, layer.valleyBand, layer.featureFadeScale.zw);
            }
            if (layer.featureMask & 4) {
                weight *= bandWeight(dot(normal.xz, layer.aspectDirection), layer.aspectBand, layer.aspectFadeScale);
            }
            if (layer.featureMask & 16) {
                weight *= maskMap.sample(mapSampler, maskUnit)[layer.maskChannel];
            }
            float share = weight * uncovered;
            if (share > best) {
                best = share;
                winner = uint(i);
            }
            if (uint(i) == uniforms.debugLayer) {
                chosen = share;
            }
            uncovered *= 1.0 - weight;
        }
        color = uniforms.debugMode == DebugWinningLayer ? idColor(winner + 1) : turbo(chosen);
        break;
    }
    case DebugColorMap:
        color = colorMap.sample(mapSampler, colorUnit).rgb;
        break;
    case DebugMaskMap:
        color = maskMap.sample(mapSampler, maskUnit).rgb;
        break;
    case DebugDetail:
        color = surfaceDetail(in.worldPosition, normal, metersPerPixel, material, detailNoise).xyz * 0.5 + 0.5;
        break;
    case DebugLightingOnly:
    case DebugAlbedoOnly: {
        float2 features = material.featureMask & 3 ? terrainFeaturesAt(xz, h, moments, farMoments, uniforms) : float2(0);
        float3 lit = litTerrainColor(xz, metersPerPixel, altitude, normal, features, 0.0, normal, uniforms.sunDirection, material, layers, blendNoise, colorMap, maskMap);
        float diffuse = saturate(dot(normal, uniforms.sunDirection));
        float3 lighting = material.sunColor * diffuse * material.sunIntensity + material.skyZenithColor * (0.5 + 0.5 * normal.y) * material.skyLightIntensity;
        color = uniforms.debugMode == DebugLightingOnly ? lighting * 0.5 : lit / max(lighting, float3(1e-4));
        break;
    }
    case DebugFog: {
        float3 toCamera = uniforms.cameraPosition - in.worldPosition;
        float dist = length(toCamera);
        float rise = -toCamera.y;
        float opticalDepth = material.fogDensity * dist * exp(-material.fogFalloff * uniforms.cameraPosition.y);
        opticalDepth *= abs(rise) > 0.01 ? (1.0 - exp(-material.fogFalloff * rise)) / (material.fogFalloff * rise) : 1.0;
        color = turbo(1.0 - exp(-opticalDepth));
        break;
    }
    case DebugLeafDepth:
        color = turbo(float(nodeDepth(in.leafID)) / float(kMaxDepth));
        break;
    case DebugLeafID:
        color = idColor(in.leafID);
        break;
    case DebugMeshletTriangle:
        color = idColor(primitive % (1u << (2 * uniforms.meshletSubdivision)) + 1);
        break;
    case DebugTriangleSize: {
        // Approximate edge length in pixels from how fast the barycentrics change; 0.5 means on target.
        float edgePixels = 1.0 / max(max(fwidth(barycentric.x), fwidth(barycentric.y)), 1e-4);
        color = turbo(edgePixels / (2.0 * uniforms.targetEdgePixels));
        break;
    }
    case DebugHeightVariance: {
        float2 m = moments.sample(heightSampler, xz / uniforms.detailSize + 0.5, level(4.0)).rg;
        color = turbo(sqrt(max(m.y - m.x * m.x, 0.0)) * uniforms.heightExaggeration / 50.0);
        break;
    }
    default:
        color = float3(1, 0, 1);
        break;
    }
    return float4(color, 1);
}
