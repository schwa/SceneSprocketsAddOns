# ``SceneSprocketsVoxels``

Voxel models in a scene graph, and a MagicaVoxel .vox loader.

## Overview

A ``VoxelGrid`` is a box of colored voxels. Put one on a node with `SceneGraph.Node.setVoxels(_:voxelSize:surface:device:)`
and add a ``VoxelRenderer`` to the view's renderers. The renderer does not make triangles: each node draws its grid's
box, and the fragment shader walks the voxels along each view ray to find the first filled one. The voxels are lit
like Blinn-Phong or PBR meshes, cast and receive shadows, and write depth, so they mix with meshes. For PBR voxels,
pass the scene's `PBRMaterialRenderer` to the voxel renderer so both use the same environment.

```swift
let scene = try MagicaVoxelScene(contentsOf: url)
let node = try scene.makeNode(voxelSize: 0.05, device: device)
root.addChild(node)

SceneView(sceneGraph, renderers: [VoxelRenderer(), BlinnPhongMaterialRenderer()])
```

### MagicaVoxel files

``MagicaVoxelScene`` reads the models in a .vox file and where the file's scene graph places them. Hidden nodes and
hidden layers are left out. Files without a palette use MagicaVoxel's default palette. MagicaVoxel is z-up; the models
and transforms are converted to y-up.

The file's materials and animation frames after the first are not read.

## Topics

### Voxels

- ``VoxelGrid``
- ``VoxelMaterial``
- ``VoxelRenderer``

### MagicaVoxel

- ``MagicaVoxelScene``
- ``MagicaVoxelError``
