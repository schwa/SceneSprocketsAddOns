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
status: new
priority: low
kind: feature
labels: effort:l, deferred
created: 2026-11-12T04:33:18Z
+++

Moved from SceneSprockets #316. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot show signed distance field shapes, such as metaballs or blobs that merge smoothly when they move close together. There is no way to describe a shape as a distance function (spheres, capsules and boxes combined with smooth union, subtraction or intersection) and draw it in a scene with the other nodes, lit and depth-tested like meshes.

Related: SceneSprocketsAddOns target (#314).

\\- `2026-11-07T17:19:23Z`: Starting points in MetalSprocketsExamples: the SDF example (3D SDF raymarching), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/SDFDemo/, and Tiled SDF (tile-culled 2D SDF), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/TiledSDFDemo/.
\\- `2026-11-08T02:45:53Z`: Added SignedDistanceShape to SceneSprocketsAddOns: sphere, rounded box and capsule primitives with smooth union, subtraction and intersection; distance(at:), normal(at:), bounds, surface(cellSize:) and makeMesh(device:cellSize:). The shape is meshed on the CPU with marching tetrahedra (no case tables) and gradient normals, so it is an ordinary mesh: lit, depth-tested and shadowed with any material, no new renderer. Tests: primitive distances, smooth union merges nearby spheres, subtraction/intersection, a meshed sphere lies on the sphere with outward winding and normals, and empty shapes make no mesh. Not done: GPU raymarching (the MetalSprocketsExamples approach); rebuild the mesh when the shape moves.
\\- `2026-11-08T03:34:47Z`: Reopened. The CPU-meshed SignedDistanceShape (marching tetrahedra) was removed: meshing took 23-243 ms in Release and seconds in Debug for a few blobs (#349), too slow for shapes that move.

## Proposed fix (per schwa)
Render SDFs the normal way (raymarching on the GPU) and tie them into the existing material shaders (Blinn-Phong, PBR), so SDF shapes are lit, shadowed and depth-tested like meshes.

---

## 4: No ocean or water surface, or procedural sky

+++
status: new
priority: low
kind: feature
labels: effort:l, deferred
created: 2026-11-12T04:33:18Z
+++

Moved from SceneSprockets #318. Issue numbers below refer to SceneSprockets.


SceneSprockets has no ocean or water surface node, and no procedural sky. Documentation/Features.md lists 'Water and ocean surfaces' and 'Skybox / procedural sky' (the sky gradient exists, but no physical sky) as missing.

Starting point: the Open Sea example in MetalSprocketsExamples (Gerstner-wave ocean with an analytic sky), MetalSprocketsExamples/Packages/MetalSprocketsExamples/Sources/MetalSprocketsExamples/Demos/OpenSeaDemo/. Candidate for SceneSprocketsAddOns (#314).

\- `2026-11-08T02:46:09Z`: Autonomous run: scoped, not changed. Two parts with design choices: (1) Ocean: the Open Sea example is a Gerstner-wave vertex shader with its own sun and analytic sky reflection (375 lines of Metal). As a ShaderMaterial in SceneSprocketsAddOns it would not see the scene's lights or shadows (ShaderMaterial gets none), only a sun direction parameter, and needs the app to pass time each frame; the alternative is CPU Gerstner displacement of a mesh drawn with PBR (lit, but CPU cost per frame). Same lit-vs-self-contained question as #322 and #300. (2) Procedural sky: needs a new Environment.Background case in the core (it is Codable and archived), plus a sun direction that could also drive a directional light. Question: for the ocean, unlit ShaderMaterial with its own sun, or CPU-displaced PBR mesh? For the sky, OK to add a Background case such as .physicalSky(sunDirection:turbidity:) to the core?

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
status: new
priority: low
kind: feature
labels: effort:m, deferred
created: 2026-11-12T04:33:19Z
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
status: new
priority: low
kind: feature
labels: effort:l, subtask, deferred
created: 2026-11-12T04:33:20Z
+++

Moved from SceneSprockets #351. Issue numbers below refer to SceneSprockets.


SceneSprockets cannot build a landscape from a heightmap: there is no terrain mesh made from height data (an image or a height array) with level of detail for large areas. Documentation/Features.md lists 'Terrain / heightmaps' as not done.

Part of #315.

- `2026-11-12T04:33:36Z`: Parent: SceneSprocketsAddOns #2.

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
