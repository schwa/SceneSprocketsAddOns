# ISSUES.md

---

## 1: Depends on GeometryLite3D 0.2.x / SwiftMesh 0.0.x; the rest of the stack has moved to 0.3 / 0.1

+++
status: closed
priority: high
kind: task
labels: dependencies
created: 2026-11-11T21:15:48Z
updated: 2026-11-11T22:51:43Z
closed: 2026-11-11T22:51:43Z
+++

This package still requires:

- GeometryLite3D `.upToNextMinor(from: "0.2.7")`
- SwiftMesh `.upToNextMinor(from: "0.0.11")`

MetalSprocketsPBR 0.1.1, MetalSprocketsGLTF 0.0.4 and SwiftMesh 0.1.0 now require GeometryLite3D `.upToNextMinor(from: "0.3.0")` (and SwiftMesh `0.1.0`). SwiftPM cannot resolve both ranges in one graph, so apps that use this package together with PBR or GLTF (SceneSprockets, MetalSprocketsExamples) can only build by overriding GeometryLite3D and SwiftMesh with `branch: "main"` in their root package.

GeometryLite3D 0.3.0 has source-breaking changes that code here may hit:

- `Transform3D.rotation` is `Rotation3D` (`.euler` or `.quaternion`), not `simd_quatf`. Read with `.quaternion`, write with `Rotation3D(q)`.
- `Transform3D` stores `.matrix` or `.components`; matrix initializers are `init(storing:)` and `init?(decomposing:tolerance:)`.
- `Transform3D` and `Rotation3D` are `Hashable`; `==` compares the represented transform.

Expected: this package requires GeometryLite3D 0.3.x (and SwiftMesh 0.1.x where used), builds and passes its tests, and is tagged so dependents can resolve without branch overrides.

Reported from SceneSprockets #378.

- `2026-11-11T22:51:43Z`: Now requires GeometryLite3D 0.3.0, SwiftMesh 0.1.0, MetalSprockets 0.2.10 and MetalSprocketsAddOns 0.2.6; no source changes were needed. 4 tests pass.

---

## 2: No terrain, heightmap or voxel content in SceneSprockets

+++
status: closed
priority: low
kind: feature
labels: effort:xl, has-subtasks
created: 2026-11-12T04:33:18Z
updated: 2026-11-12T04:33:29Z
closed: 2026-11-12T04:33:29Z
+++

Moved from SceneSprockets #315. Issue numbers below refer to SceneSprockets.


SceneSprockets has no way to build landscapes: no terrain or heightmap meshes (with level of detail for large areas), and no voxel worlds (a 'Minecraft lite': chunked block grids with meshing, editing and texturing). Documentation/Features.md lists 'Terrain / heightmaps' as not done.

## Proposed scope (per schwa)
Add these, and similar content, to the SceneSprocketsAddOns target (#314): landscape/terrain rendering, voxels, etc.

\- `2026-11-07T17:19:23Z`: Starting points in MetalSprocketsExamples: the Voxel example (compute-raymarched voxel volumes) and its MagicaVoxel .vox loader, MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/VoxelDemo/.
\- `2026-11-08T03:35:04Z`: Split (per schwa) into #351 (heightmap terrain) and #352 (voxel worlds). This issue now tracks both.
\- `2026-11-08T03:36:47Z`: Closed (per schwa). Remaining work tracked in #351 (heightmap terrain); voxels are #352 (deferred).

- `2026-11-12T04:33:29Z`: Was closed in SceneSprockets (#315).
- `2026-11-12T04:33:36Z`: Subtasks: SceneSprocketsAddOns #13 (heightmap terrain), #14 (voxel worlds).

---

## 3: No signed distance field (SDF) blobs

+++
status: closed
priority: low
kind: feature
labels: effort:l
milestone: M1
created: 2026-11-12T04:33:18Z
updated: 2026-11-17T01:14:51Z
closed: 2026-11-17T01:14:51Z
+++

Moved from SceneSprockets #316. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot show signed distance field shapes, such as metaballs or blobs that merge smoothly when they move close together. There is no way to describe a shape as a distance function (spheres, capsules and boxes combined with smooth union, subtraction or intersection) and draw it in a scene with the other nodes, lit and depth-tested like meshes.

Related: SceneSprocketsAddOns target (#314).

\\- `2026-11-07T17:19:23Z`: Starting points in MetalSprocketsExamples: the SDF example (3D SDF raymarching), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/SDFDemo/, and Tiled SDF (tile-culled 2D SDF), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/TiledSDFDemo/.
\\- `2026-11-08T02:45:53Z`: Added SignedDistanceShape to SceneSprocketsAddOns: sphere, rounded box and capsule primitives with smooth union, subtraction and intersection; distance(at:), normal(at:), bounds, surface(cellSize:) and makeMesh(device:cellSize:). The shape is meshed on the CPU with marching tetrahedra (no case tables) and gradient normals, so it is an ordinary mesh: lit, depth-tested and shadowed with any material, no new renderer. Tests: primitive distances, smooth union merges nearby spheres, subtraction/intersection, a meshed sphere lies on the sphere with outward winding and normals, and empty shapes make no mesh. Not done: GPU raymarching (the MetalSprocketsExamples approach); rebuild the mesh when the shape moves.
\\- `2026-11-08T03:34:47Z`: Reopened. The CPU-meshed SignedDistanceShape (marching tetrahedra) was removed: meshing took 23-243 ms in Release and seconds in Debug for a few blobs (#349), too slow for shapes that move.

## Proposed fix (per schwa)
Render SDFs the normal way (raymarching on the GPU) and tie them into the existing material shaders (Blinn-Phong, PBR), so SDF shapes are lit, shadowed and depth-tested like meshes.

- `2026-11-16T23:28:35Z`: Design (grill session):
- `2026-11-16T23:28:35Z`: One proxy box per SDF node. Back faces are drawn; the ray starts at the analytic box entry or the near plane, whichever is later. A hit writes [[depth(any)]]; a miss discards.
- `2026-11-16T23:28:35Z`: Smooth merging only between primitives in one node. No blending across nodes.
- `2026-11-16T23:28:35Z`: The shape tree is a flat instruction buffer read by one generic shader, so animation does not recompile pipelines.
- `2026-11-16T23:28:35Z`: API: indirect enum SignedDistanceShape (sphere, roundedBox, capsule, smoothUnion, smoothSubtraction, smoothIntersection), shape.makeNode(device:material:). Bounds padded by the largest smoothing radius. Animate by setting a new shape on SignedDistanceMaterial.
- `2026-11-16T23:28:35Z`: Lighting reuses BlinnPhongLighting.h (SceneSprockets) and PBRLighting.h (MetalSprocketsPBR), both uncommitted refactors. Blinn-Phong first, PBR second (needs a MetalSprocketsPBR release). Keep the two models structured alike.
- `2026-11-16T23:28:35Z`: March defaults: 128 steps, a hit threshold that scales with distance, step scale 1.
- `2026-11-16T23:28:35Z`: Casting shadows deferred to #40. Receiving shadows works.
- `2026-11-16T23:28:35Z`: Tests: CPU encoding, distance and bounds tests, plus offscreen render tests (coverage matches a mesh sphere, depth against meshes, camera inside the box, smooth union has no gap). Animated metaball demo.

---

## 4: No ocean or water surface, or procedural sky

+++
status: closed
priority: low
kind: feature
labels: effort:l, deferred
created: 2026-11-12T04:33:18Z
updated: 2026-11-16T19:43:18Z
closed: 2026-11-16T19:43:18Z
+++

Moved from SceneSprockets #318. Issue numbers below refer to SceneSprockets.


SceneSprockets has no ocean or water surface node, and no procedural sky. Documentation/Features.md lists 'Water and ocean surfaces' and 'Skybox / procedural sky' (the sky gradient exists, but no physical sky) as missing.

Starting point: the Open Sea example in MetalSprocketsExamples (Gerstner-wave ocean with an analytic sky), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/OpenSeaDemo/. Candidate for SceneSprocketsAddOns (#314).

\- `2026-11-08T02:46:09Z`: Autonomous run: scoped, not changed. Two parts with design choices: (1) Ocean: the Open Sea example is a Gerstner-wave vertex shader with its own sun and analytic sky reflection (375 lines of Metal). As a ShaderMaterial in SceneSprocketsAddOns it would not see the scene's lights or shadows (ShaderMaterial gets none), only a sun direction parameter, and needs the app to pass time each frame; the alternative is CPU Gerstner displacement of a mesh drawn with PBR (lit, but CPU cost per frame). Same lit-vs-self-contained question as #322 and #300. (2) Procedural sky: needs a new Environment.Background case in the core (it is Codable and archived), plus a sun direction that could also drive a directional light. Question: for the ocean, unlit ShaderMaterial with its own sun, or CPU-displaced PBR mesh? For the sky, OK to add a Background case such as .physicalSky(sunDirection:turbidity:) to the core?

- `2026-11-16T19:43:18Z`: Superseded by #16 (sun and sky), #18 (water and waves) and #19 (physically based sky), which split this issue up.

---

## 5: No grass or foliage fields

+++
status: closed
priority: low
kind: feature
labels: effort:l, deferred
created: 2026-11-12T04:33:18Z
updated: 2026-11-12T04:33:31Z
closed: 2026-11-12T04:33:31Z
+++

Moved from SceneSprockets #319. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot cover ground with grass or similar foliage: there is no node that scatters many blades or plants over a surface cheaply, with wind. Documentation/Features.md lists 'Foliage with wind' as missing.

Starting points in MetalSprocketsExamples: Grass (mesh-shader procedural grass), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/GrassDemo/, and Meadow (ray-traced procedural meadow), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/MeadowDemo/. Candidate for SceneSprocketsAddOns (#314); pairs with terrain (#315).

\- `2026-11-08T02:46:17Z`: Autonomous run: scoped, not changed. 'Cheap, many blades, with wind' needs per-frame GPU vertex animation (the Grass example uses a mesh shader). In SceneSprockets that is either a ShaderMaterial in SceneSprocketsAddOns (no scene lights or shadows, own sun parameter) or wind support in the Blinn-Phong/PBR vertex shaders (lit, but touches every renderer). Static scattered blades on the CPU would be lit but have no wind and cost a lot of vertices. Punting: same lit-vs-self-contained decision as #318, #322 and #300. Question: which approach, and should it wait for terrain (#315) to scatter on?
\- `2026-11-12T04:32:26Z`: Closed in deferred-issue cleanup: wishful, with no concrete use case in SceneSprockets.

- `2026-11-12T04:33:31Z`: Was closed in SceneSprockets (#319).

---

## 6: No reusable procedural tree generator

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-12T04:33:19Z
updated: 2026-11-12T04:33:31Z
closed: 2026-11-12T04:33:31Z
+++

Moved from SceneSprockets #320. Issue numbers below refer to SceneSprockets.


SceneSprockets has no reusable way to generate trees. The demos' Tree Appreciator grows trees, but that code lives in the demo package, where apps cannot use it.

Starting points: the Tree Generator example in MetalSprocketsExamples (space-colonization trees), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/TreeGeneratorDemo/, and the demos' Demo/Packages/SceneSprocketsDemos/Sources/SceneSprocketsDemos/TreeAppreciator/. Candidate for SceneSprocketsAddOns (#314).

\- `2026-11-08T02:37:56Z`: Added ProceduralTree to SceneSprocketsAddOns: Parameters (with random(seed:)), deterministic growth from a seed, public branches and leaves for custom geometry, and makeNode(device:) for a flat-shaded Blinn-Phong mesh. The algorithm is the demo's (TreeAppreciator) without its game-only parts (differences, fruit, blossoms, birds); the demo still uses its own copy because its growth is interleaved with those differences. 5 tests in SceneSprocketsAddOnsTests (determinism, shape, branch limit, bare tree, node submeshes).
\- `2026-11-08T03:30:21Z`: Removed ProceduralTree from SceneSprocketsAddOns (per schwa: the tree can die). Not doing a reusable tree generator; the demo's Tree Appreciator keeps its own code. Closed as won't do.

- `2026-11-12T04:33:31Z`: Was closed in SceneSprockets (#320).

---

## 7: No point cloud node

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-12T04:33:19Z
updated: 2026-11-12T04:33:32Z
closed: 2026-11-12T04:33:32Z
+++

Moved from SceneSprockets #321. Issue numbers below refer to SceneSprockets.


SceneSprockets has no node for point clouds (for example scanned data or PLY points) drawn as sized, colored points. Documentation/Features.md marks point clouds as possible with ShaderMaterial but needing an example.

Starting point: the Point Cloud example in MetalSprocketsExamples, MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/PointCloudDemo/. Candidate for SceneSprocketsAddOns (#314).

\- `2026-11-08T02:42:24Z`: Added PointCloud to SceneSprocketsAddOns: points with position and color, a pointSize in screen points, makeMaterial() (a ShaderMaterial with new PointCloud.metal shaders in SceneSprocketsShaders: round points via point_coord, node opacity applied) and makeNode(device:) (a .point-primitive mesh that casts no shadow). Tests: an 8-point dot renders round, centered and red (52 pixels, square would be 64); empty clouds make empty nodes; translucent colors make a transparent material. Note: the first version put pointSize at [[buffer(0)]], which collides with the mesh's vertex buffer and drew nothing; ShaderMaterial parameters in vertex functions must use slots above the vertex buffers.

- `2026-11-12T04:33:32Z`: Was closed in SceneSprockets (#321).

---

## 8: No dissolve effect for nodes

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-11-12T04:33:19Z
updated: 2026-11-16T20:12:47Z
+++

Moved from SceneSprockets #322. Issue numbers below refer to SceneSprockets.


SceneSprockets has no way to dissolve a node in or out (for example for teleport, spawn or destroy effects); only opacity fades exist.

Starting point: the Mesh Dissolve example in MetalSprocketsExamples (triplanar-grid dissolve effects), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/MeshDissolveDemo/. Candidate for SceneSprocketsAddOns (#314).

\- `2026-11-08T02:42:41Z`: Autonomous run: scoped, not changed. The MetalSprocketsExamples dissolve discards fragments by a 3D noise field and draws an edge glow, in its own shader. In SceneSprockets that can be done two ways: (a) a ShaderMaterial in SceneSprocketsAddOns that replaces the node's material while it dissolves (self-contained, but unlit: ShaderMaterial gets no lights, so a Blinn-Phong or PBR node changes look when the dissolve starts); or (b) a node-level dissolve amount (like opacity) that Blinn-Phong, PBR (MetalSprocketsPBR) and ShaderMaterial shaders all honor (looks right, but touches every material renderer and the PBR package). Punting: this is a design choice. Question: (a) add-on material, or (b) node-level dissolve in every renderer?

---

## 9: No volumetric clouds

+++
status: closed
priority: low
kind: feature
labels: effort:l, deferred
created: 2026-11-12T04:33:19Z
updated: 2026-11-12T04:33:33Z
closed: 2026-11-12T04:33:33Z
+++

Moved from SceneSprockets #323. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot show volumetric clouds in a scene's sky. Documentation/Features.md lists 'Volumetric lighting and fog' as missing.

Starting point: the cloud demo in MetalSprocketsExamples (sun-lit volumetric cloud with progressive accumulation), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/CloudDemo/CloudDemoView.swift. It is not in the examples README and still has temporary #242 bisect code. Candidate for SceneSprocketsAddOns (#314).

\- `2026-11-08T02:46:26Z`: Autonomous run: scoped, not changed. Volumetric clouds are a raymarched full-screen pass that needs the scene depth (to stop at geometry), a sun direction and a sky to sit in. That means a new pass in SceneGraphRenderer's post-pass chain (like FogPass) or an Environment.Background option, not a self-contained add-on node; the CloudDemo source also relies on progressive accumulation over frames, which does not fit a moving camera. Punting: depends on the procedural sky decision in #318 and on where sky effects live. Question: should clouds be part of the sky/background (#318) or a post pass like fog?
\- `2026-11-12T04:31:39Z`: Closed in deferred-issue cleanup: wishful: volumetric clouds, with no concrete use case in SceneSprockets.

- `2026-11-12T04:33:33Z`: Was closed in SceneSprockets (#323).

---

## 10: No fluid simulation

+++
status: closed
priority: low
kind: feature
labels: effort:xl, deferred
created: 2026-11-12T04:33:19Z
updated: 2026-11-12T04:33:33Z
closed: 2026-11-12T04:33:33Z
+++

Moved from SceneSprockets #324. Issue numbers below refer to SceneSprockets.


SceneSprockets has no fluid simulation, such as a water volume that splashes and flows around objects.

Starting point: the FLIP Fluid example in MetalSprocketsExamples (3D PIC/FLIP simulation), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/MetalFLIPDemo/. A later candidate for SceneSprocketsAddOns (#314): heavier than the others.

\- `2026-11-12T04:31:39Z`: Closed in deferred-issue cleanup: wishful: FLIP fluid simulation, xl effort, with no concrete use case in SceneSprockets.

- `2026-11-12T04:33:33Z`: Was closed in SceneSprockets (#324).

---

## 11: SignedDistanceShape meshing is too slow to rebuild while a shape moves

+++
status: closed
priority: medium
kind: enhancement
labels: effort:m
created: 2026-11-12T04:33:20Z
updated: 2026-11-12T04:33:34Z
closed: 2026-11-12T04:33:34Z
+++

Moved from SceneSprockets #349. Issue numbers below refer to SceneSprockets.


SignedDistanceShape.surface(cellSize:) / makeMesh(device:cellSize:) take far too long for shapes that change, such as metaballs moving every frame. Even small shapes take tens to hundreds of milliseconds in Release and seconds in Debug.

Measured on this Mac (swift test, one call each):

| Shape | cellSize | Triangles | Debug | Release |
|---|---|---|---|---|
| sphere r=1 | 0.1 | 10,950 | 0.14 s | 5 ms |
| sphere r=1 | 0.05 | 44,598 | 0.62 s | 23 ms |
| sphere r=1 | 0.025 | 179,760 | 2.97 s | 131 ms |
| 6 spheres, smooth union 0.6 | 0.1 | 31,550 | 1.33 s | 51 ms |
| 6 spheres, smooth union 0.6 | 0.05 | 125,921 | 5.91 s | 243 ms |
| 6 spheres, smooth union 0.6 | 0.025 | 505,570 | 27.98 s | 1.31 s |

Expected: a few metaballs can be re-meshed every frame (under a few ms) at a cell size that looks smooth.
Actual: 51-243 ms in Release for 6 blobs at usable cell sizes, so animated SDF shapes are not practical; Debug builds are about 20x slower again.

Observations (not profiled): the distance function is evaluated at every grid corner of the whole bounding box, and normal(at:) (6 more evaluations) runs once per output vertex and once per triangle. Time grows with the cube of size/cellSize.

Part of #316.

\- `2026-11-08T03:34:47Z`: Obsolete: the CPU-meshed SignedDistanceShape was removed; #316 will raymarch on the GPU instead.

- `2026-11-12T04:33:34Z`: Was closed in SceneSprockets (#349).

---

## 12: SignedDistanceShape meshes do not share vertices

+++
status: closed
priority: low
kind: enhancement
labels: effort:s
created: 2026-11-12T04:33:20Z
updated: 2026-11-12T04:33:34Z
closed: 2026-11-12T04:33:34Z
+++

Moved from SceneSprockets #350. Issue numbers below refer to SceneSprockets.


makeMesh(device:cellSize:) emits three new vertices for every triangle; neighboring triangles never share a vertex. A sphere at cellSize 0.025 has 179,760 triangles and therefore 539,280 vertices, about six times more than a mesh with shared vertices would need. This makes the meshes large in memory and adds work for every vertex that is drawn or deformed, and it adds normal evaluations to meshing time (see the meshing speed issue).

Part of #316.

\- `2026-11-08T03:34:47Z`: Obsolete: the CPU-meshed SignedDistanceShape was removed; #316 will raymarch on the GPU instead.

- `2026-11-12T04:33:34Z`: Was closed in SceneSprockets (#350).

---

## 13: No heightmap terrain in SceneSprocketsAddOns

+++
status: closed
priority: low
kind: feature
labels: effort:l, subtask, deferred
created: 2026-11-12T04:33:20Z
updated: 2026-11-16T19:43:18Z
closed: 2026-11-16T19:43:18Z
+++

Moved from SceneSprockets #351. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot build a landscape from a heightmap: there is no terrain mesh made from height data (an image or a height array) with level of detail for large areas. Documentation/Features.md lists 'Terrain / heightmaps' as not done.

Part of #315.

- `2026-11-12T04:33:36Z`: Parent: SceneSprocketsAddOns #2.
- `2026-11-16T19:43:18Z`: Fixed by the SceneSprocketsTerrain target (commits sktkvyuu and vvwukkmy): GPU-tessellated heightmap terrain with clipmap streaming, from images or procedural noise, drawn as a scene graph node by TerrainRenderer.

---

## 14: No voxel worlds in SceneSprocketsAddOns

+++
status: closed
priority: low
kind: feature
labels: effort:l, subtask, deferred
created: 2026-11-12T04:33:20Z
updated: 2026-11-12T04:33:35Z
closed: 2026-11-12T04:33:35Z
+++

Moved from SceneSprockets #352. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot show voxel worlds (a 'Minecraft lite'): there are no chunked block grids with meshing, editing and texturing. Starting point: the Voxel example in MetalSprocketsExamples (compute-raymarched voxel volumes) and its MagicaVoxel .vox loader, MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/VoxelDemo/.

Part of #315.

\- `2026-11-12T04:31:40Z`: Closed in deferred-issue cleanup: wishful: voxel worlds, with no concrete use case in SceneSprockets.

- `2026-11-12T04:33:35Z`: Was closed in SceneSprockets (#352).
- `2026-11-12T04:33:36Z`: Parent: SceneSprocketsAddOns #2.

---

## 15: SceneSprocketsAddOns has its own point cloud instead of MetalSprocketsAddOns' PointCloud

+++
status: closed
priority: low
kind: task
labels: effort:m
created: 2026-11-12T04:33:21Z
updated: 2026-11-12T04:33:35Z
closed: 2026-11-12T04:33:35Z
+++

Moved from SceneSprockets #353. Issue numbers below refer to SceneSprockets.


SceneSprocketsAddOns.PointCloud (#321) is a point renderer written for SceneSprockets: a .point-primitive mesh drawn by a ShaderMaterial with new shaders in SceneSprocketsShaders (PointCloud.metal). MetalSprocketsAddOns, which SceneSprockets already depends on, has its own point cloud pipeline (Pipelines/PointCloud.swift: PointCloudRasterizePass, PointCloudResolvePipeline, PointCloudPointFunction, with shaders in MetalSprocketsAddOnsShaders). So there are two point cloud implementations, and the SceneSprockets one does not use the existing one.

## Proposed fix (per schwa)
Use the point cloud in MetalSprocketsAddOns, not the one SceneSprockets rolled itself.

Related: #321.

\- `2026-11-08T04:05:14Z`: Done: SceneSprocketsAddOns.PointCloud now draws with MetalSprocketsAddOns' compute rasterizer. New PointCloudMaterial (points buffer of PointCloudPoint, size, size units, shape) and PointCloudRenderer (SceneGraphPrePassRenderer: one PointCloudRasterizePass per node before the scene pass, PointCloudResolvePipeline in the scene pass, reverse-Z). Removed the ShaderMaterial version and PointCloud.metal from SceneSprocketsShaders. Needs Apple GPU family 8+; otherwise not drawn. Tests: disc size/color, node transform, packed point data.

- `2026-11-12T04:33:35Z`: Was closed in SceneSprockets (#353).

---

## 16: No sun and sky renderer for scenes

+++
status: open
priority: medium
kind: feature
labels: effort:m
created: 2026-11-16T19:33:43Z
updated: 2026-11-16T19:43:26Z
+++

SceneSprockets backgrounds are a solid color, a gradient, or an environment map. There is no sky that follows a sun: a visible sun disc, a sky that brightens toward the sun, and a sun direction that matches the scene's directional light.

The terrain (SceneSprocketsTerrain) has its own built-in sky, but only for terrain nodes and only with drawsSky.

## Proposed (per user)

A separate target and product.

- `2026-11-16T19:43:18Z`: Related: #19 (physically based sky), closed #4.

---

## 17: No voxel renderer or voxel file loading

+++
status: closed
priority: medium
kind: feature
labels: effort:l
milestone: M1
created: 2026-11-16T19:33:43Z
updated: 2026-11-17T02:10:56Z
closed: 2026-11-17T02:10:56Z
+++

There is no way to draw voxel models in a scene, and no loader for standard voxel file formats (for example MagicaVoxel .vox).

## Proposed (per user)

A separate target and product.

- `2026-11-16T19:43:18Z`: Related: closed #14 (voxel worlds) and #2. Starting point: the Voxel example in MetalSprocketsExamples and its MagicaVoxel .vox loader, Demos/VoxelDemo/.

---

## 18: No water or wave renderer

+++
status: open
priority: medium
kind: feature
labels: effort:l
created: 2026-11-16T19:33:43Z
updated: 2026-11-16T19:43:26Z
+++

There is no water surface for scenes: no animated waves, reflection, refraction, or shoreline. The terrain's Coastal style fakes water with a flat blue layer at sea level.

## Proposed (per user)

A separate target and product.

- `2026-11-16T19:43:18Z`: Related: closed #4 (older ocean issue). Starting point from it: the Open Sea example in MetalSprocketsExamples (Gerstner-wave ocean with an analytic sky), Demos/OpenSeaDemo/. Open design question from #4: an unlit shader material with its own sun, or a CPU-displaced mesh drawn with PBR so it gets the scene's lights and shadows.

---

## 19: No physically based sky for sunrise and sunset

+++
status: open
priority: medium
kind: feature
labels: effort:l
created: 2026-11-16T19:33:43Z
updated: 2026-11-16T19:43:26Z
+++

There is no realistic sky that changes with the time of day: atmospheric scattering, sunrise and sunset colors, twilight, and matching sun light color for the scene.

Related to the sun and sky renderer issue, which covers a simpler sky.

## Proposed (per user)

A separate target and product.

- `2026-11-16T19:43:18Z`: Related: closed #4. Its notes: a procedural sky likely needs a new Environment.Background case in SceneSprockets core (Codable, archived), and the sun direction could also drive a directional light.

---

## 20: No fluid simulation and renderer

+++
status: open
priority: medium
kind: feature
labels: effort:xl
created: 2026-11-16T19:33:50Z
updated: 2026-11-16T19:43:26Z
+++

There is no fluid system for scenes: no GPU fluid simulation (for example particle-based liquids, smoke, or fire) and no way to draw its surface or volume in the scene pass.

Different from the water and wave renderer issue (#18), which covers large water surfaces.

## Proposed (per user)

A separate target and product.

- `2026-11-16T19:43:18Z`: Related: closed #10 (older fluid issue, closed as wishful). Starting point: the FLIP Fluid example in MetalSprocketsExamples, Demos/MetalFLIPDemo/.

---

## 21: No volumetric clouds

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:37Z
updated: 2026-11-16T19:43:26Z
+++

Scenes have no clouds. Skies are flat backgrounds, with no 3D clouds that the light passes through or that cast shadows.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T19:43:18Z`: Related: closed #9 (older volumetric clouds issue). Starting point: the cloud demo in MetalSprocketsExamples, Demos/CloudDemo/. Needs scene depth, a sun direction and a sky, like FogPass.

---

## 22: No weather effects (rain, snow, wet surfaces)

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:37Z
updated: 2026-11-16T19:43:26Z
+++

There is no rain or snow, and surfaces cannot look wet or covered in snow.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T19:43:18Z`: Related: #21 (clouds) and #16 (sky).

---

## 23: No vegetation system (instanced grass and trees with wind)

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:37Z
updated: 2026-11-16T19:43:26Z
+++

There is no way to scatter large amounts of grass, plants or trees over a surface such as the terrain, draw them as instances, or move them with wind.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T19:43:18Z`: Related: closed #5 (grass or foliage fields). Starting points: Grass and Meadow examples in MetalSprocketsExamples. Pairs with SceneSprocketsTerrain.

---

## 24: No projected decals

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:37Z
updated: 2026-11-16T20:03:49Z
closed: 2026-11-16T20:03:49Z
+++

There is no way to project an image onto existing meshes, for example bullet holes, footprints or road markings.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:03:49Z`: Moved to SceneSprockets #397: this belongs in the main library.

---

## 25: No screen-space reflections

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:37Z
updated: 2026-11-16T20:03:49Z
closed: 2026-11-16T20:03:49Z
+++

Shiny surfaces reflect only the environment map. They do not reflect other objects in the scene.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:03:49Z`: Moved to SceneSprockets #398: this belongs in the main library.

---

## 26: No bloom, depth of field or motion blur

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:37Z
updated: 2026-11-16T20:03:49Z
closed: 2026-11-16T20:03:49Z
+++

Post-processing has exposure, contrast, saturation, vignette and ambient occlusion. It has no bloom, depth of field or motion blur.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:03:49Z`: Moved to SceneSprockets #399: this belongs in the main library.

---

## 27: No volumetric light shafts (god rays)

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T19:43:26Z
+++

Light does not scatter in the air, so there are no visible light shafts through gaps, trees or windows.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T19:43:18Z`: Related: #21 (clouds).

---

## 28: No outline or toon (non-photorealistic) shading

+++
status: open
priority: low
kind: feature
labels: effort:m
milestone: M1
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T23:16:28Z
+++

There is no outline shading or toon/cel shading for a non-photorealistic look.

## Proposed (per user)

An optional add-on, in its own target and product.

---

## 29: Gaussian splats cannot be added as scene nodes

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T19:43:26Z
+++

MetalSprocketsGaussianSplats (https://github.com/schwa/MetalSprocketsGaussianSplats) draws 3D Gaussian splats and loads .ply, .splat, .spz and .sog files, but only in its own SplatView or render elements. A scene graph cannot hold a splat model as a node: splats cannot be placed with node transforms, drawn in the scene pass with the other meshes, depth-tested against opaque meshes, or culled and picked like other nodes.

## Proposed (per user)

An optional add-on in its own target and product, built on MetalSprocketsGaussianSplats.

- `2026-11-16T19:43:18Z`: Related: #39 (animated point clouds) for the animated-splats case.

---

## 30: No procedural content generators (roads, buildings, L-system trees)

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T19:43:26Z
+++

There are no generators for roads, buildings or trees (for example L-systems) that make scene nodes.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T19:43:18Z`: Related: #6 added ProceduralTree to SceneSprocketsAddOns, so trees already exist (space colonization, not L-systems).

---

## 31: No cloth or rope simulation

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T19:43:26Z
+++

Scenes cannot simulate cloth (flags, curtains) or ropes and cables.

## Proposed (per user)

An optional add-on, in its own target and product.

---

## 32: No trail or ribbon effects

+++
status: open
priority: low
kind: feature
labels: effort:s
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T19:43:26Z
+++

There are no trails or ribbons that follow a moving object, for example sword swings, contrails or motion trails.

## Proposed (per user)

An optional add-on, in its own target and product.

---

## 33: No billboard imposters for distant meshes

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T20:03:49Z
closed: 2026-11-16T20:03:49Z
+++

Distant meshes are drawn as full geometry or a lower LOD. They cannot be replaced by billboard imposters (pre-rendered views).

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:03:49Z`: Moved to SceneSprockets #400: this belongs in the main library.

---

## 34: No geospatial data support (GeoJSON, map tiles)

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:38Z
updated: 2026-11-16T19:43:26Z
+++

There is no way to load geospatial data such as GeoJSON or map tiles, or to lay it onto the terrain.

## Proposed (per user)

An optional add-on, in its own target and product.

---

## 35: No editor gizmos (grid, axes, light and camera icons, bounds)

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:39Z
updated: 2026-11-16T20:13:10Z
closed: 2026-11-16T20:13:10Z
+++

There is no ready-made set of editor aids: a ground grid, axes, icons for lights and cameras, and bounding boxes.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:13:10Z`: Moved to SceneSprockets #406: this belongs in the main library.

---

## 36: No path or spline nodes

+++
status: closed
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:34:39Z
updated: 2026-11-16T20:14:04Z
closed: 2026-11-16T20:14:04Z
+++

There are no spline paths in the scene, and nothing that moves cameras or objects along a path.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:14:04Z`: Moved to SceneSprockets #407: this belongs in the main library.

---

## 37: No navmesh generation or pathfinding

+++
status: open
priority: low
kind: feature
labels: effort:l
created: 2026-11-16T19:34:39Z
updated: 2026-11-16T19:43:26Z
+++

Scenes cannot generate a navigation mesh from their geometry or find paths across it.

## Proposed (per user)

An optional add-on, in its own target and product.

---

## 38: No GPU timing overlay per pass

+++
status: closed
priority: low
kind: feature
labels: effort:s
created: 2026-11-16T19:34:39Z
updated: 2026-11-16T20:03:49Z
closed: 2026-11-16T20:03:49Z
+++

There is no overlay that shows how much GPU time each pass (shadows, the scene pass, post-processing, pre-passes) takes.

## Proposed (per user)

An optional add-on, in its own target and product.

- `2026-11-16T20:03:49Z`: Moved to SceneSprockets #401: this belongs in the main library.

---

## 39: Point clouds cannot be animated

+++
status: open
priority: low
kind: feature
labels: effort:m
created: 2026-11-16T19:36:05Z
updated: 2026-11-16T19:43:26Z
+++

A PointCloud's points are fixed when its node is made: positions, colors and sizes are copied into a buffer once. There is no way to animate them over time, for example point positions or colors that change per frame, point cloud sequences (one cloud per frame, such as volumetric video), or morphing between clouds. The only way to change the points is to make a new node.

- `2026-11-16T19:43:18Z`: Related: #29 (Gaussian splats as scene nodes).

---

## 40: Signed distance field (SDF) shapes cast no shadows

+++
status: closed
priority: low
kind: feature
depends: 3
created: 2026-11-16T23:27:38Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

SDF shapes from #3 receive shadows from the shadow map, but they do not cast shadows. They are not drawn in the shadow pass, so they do not shadow meshes, the ground, or other SDF shapes, and they look like they float above the ground.

Expected: SDF shapes cast shadows like meshes do.

---

## 41: Signed distance field (SDF) shapes cannot use PBR materials

+++
status: closed
priority: low
kind: feature
depends: 3
created: 2026-11-17T01:14:51Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

SignedDistanceMaterial.Surface has only a Blinn-Phong case. SDF shapes cannot be lit with PBR materials (metallic-roughness, clearcoat, sheen, image-based lighting), so they do not match PBR meshes in the same scene.

MetalSprocketsPBR 0.2.2 provides PBRLighting.h (PBR::Fragment and PBR::shade) for surfaces that build their own fragment.

---

## 42: MagicaVoxel loader ignores the file's scene graph

+++
status: closed
priority: low
kind: feature
created: 2026-11-17T02:09:45Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

VoxelGrid.magicaVoxelModels(data:) ignores the nTRN, nGRP, nSHP and LAYR chunks. Files with more than one model load as separate grids with no position, rotation, or layer. Scenes built in MagicaVoxel from several models do not load as laid out.

Related: #17.

---

## 43: MagicaVoxel files without a palette load as gray

+++
status: closed
priority: low
kind: bug
created: 2026-11-17T02:09:46Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

A .vox file with no RGBA chunk uses MagicaVoxel's built-in default palette. VoxelGrid.magicaVoxelModels(data:) makes every voxel gray (200, 200, 200) instead, so such files lose their colors.

Related: #17.

---

## 44: SceneSprocketsVoxels has no DocC documentation

+++
status: closed
priority: low
kind: documentation
created: 2026-11-17T02:09:46Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

The SceneSprocketsVoxels product has no documentation catalog. VoxelGrid, VoxelMaterial, VoxelRenderer, the MagicaVoxel loader, and SceneGraph.Node.setVoxels do not appear in any DocC page.

Related: #17.

---

## 45: Voxel grids cannot use PBR materials

+++
status: closed
priority: low
kind: feature
depends: 17
created: 2026-11-17T02:10:23Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

VoxelMaterial.Surface has only a Blinn-Phong case. Voxel grids cannot be lit with PBR materials (metallic-roughness, clearcoat, sheen, image-based lighting), so they do not match PBR meshes in the same scene.

MetalSprocketsPBR 0.2.2 provides PBRLighting.h (PBR::Fragment and PBR::shade) for surfaces that build their own fragment.

Related: #41 (same gap for SDF shapes).

---

## 46: Voxel grids cast no shadows

+++
status: closed
priority: low
kind: feature
depends: 17
created: 2026-11-17T02:10:23Z
updated: 2026-11-17T02:56:59Z
closed: 2026-11-17T02:56:59Z
+++

Voxel grids receive shadows from the shadow map, but they do not cast shadows. They are not drawn in the shadow pass, so they do not shadow meshes, the ground, other voxel grids, or themselves.

Expected: voxel grids cast shadows like meshes do.

Related: #40 (same gap for SDF shapes).

---

## Milestone: M1

+++
status: open
created: 2026-11-16T23:15:55Z
+++

---
