# ISSUES.md

---

## 1: Depends on GeometryLite3D 0.2.x / SwiftMesh 0.0.x; the rest of the stack has moved to 0.3 / 0.1

+++
status: new
priority: high
kind: task
labels: dependencies
created: 2026-11-11T21:15:48Z
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

---
