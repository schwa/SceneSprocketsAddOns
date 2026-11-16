import GeometryLite3D
import Metal
import SceneSprockets
import SceneSprocketsAddOnsShaders
import simd
import SwiftMesh

/// A shape described by a signed distance function: primitives joined by smooth union, subtraction and intersection.
///
/// Smooth operations blend nearby surfaces, so spheres in a ``smoothUnion(_:smoothing:)`` merge like metaballs.
/// ``makeNode(device:surface:)`` makes a node that a ``SignedDistanceRenderer`` raymarches on the GPU.
public indirect enum SignedDistanceShape: Sendable, Equatable {
    case sphere(radius: Float, transform: Transform3D = .identity)
    /// A box of `size`, centered on the origin, with edges rounded by `cornerRadius`.
    case roundedBox(size: SIMD3<Float>, cornerRadius: Float = 0, transform: Transform3D = .identity)
    /// A cylinder from `start` to `end` with hemispherical caps.
    case capsule(start: SIMD3<Float>, end: SIMD3<Float>, radius: Float)
    /// All of the shapes. Surfaces closer than `smoothing` blend together.
    case smoothUnion([Self], smoothing: Float = 0)
    /// The first shape with the second cut out of it.
    case smoothSubtraction(Self, Self, smoothing: Float = 0)
    /// Where both shapes overlap.
    case smoothIntersection(Self, Self, smoothing: Float = 0)
}

/// Errors from encoding a ``SignedDistanceShape`` for the GPU.
public enum SignedDistanceShapeError: Error, Equatable {
    /// The shape nests too deeply for the shader's evaluation stack.
    case tooDeep(depth: Int, maximum: Int)
}

public extension SignedDistanceShape {
    /// The signed distance from `position` to the surface: negative inside. It never overshoots the true distance.
    func distance(at position: SIMD3<Float>) -> Float {
        switch self {
        case let .sphere(radius, transform):
            let (local, scale) = Self.local(position, transform)
            return (simd_length(local) - radius) * scale
        case let .roundedBox(size, cornerRadius, transform):
            let (local, scale) = Self.local(position, transform)
            let radius = Self.clampedCornerRadius(cornerRadius, size: size)
            let q = simd_abs(local) - size / 2 + radius
            return (simd_length(simd_max(q, .zero)) + min(q.max(), 0) - radius) * scale
        case let .capsule(start, end, radius):
            let axis = end - start
            let offset = position - start
            let along = simd_clamp(simd_dot(offset, axis) / max(simd_dot(axis, axis), 1e-12), 0, 1)
            return simd_length(offset - axis * along) - radius
        case let .smoothUnion(shapes, smoothing):
            guard var result = shapes.first?.distance(at: position) else {
                return .infinity
            }
            for shape in shapes.dropFirst() {
                result = Self.smoothMin(result, shape.distance(at: position), smoothing)
            }
            return result
        case let .smoothSubtraction(base, cut, smoothing):
            return -Self.smoothMin(-base.distance(at: position), cut.distance(at: position), smoothing)
        case let .smoothIntersection(first, second, smoothing):
            return -Self.smoothMin(-first.distance(at: position), -second.distance(at: position), smoothing)
        }
    }

    /// A box that contains the surface, or `nil` for an empty shape.
    var bounds: BoundingBox3D? {
        switch self {
        case let .sphere(radius, transform):
            return BoundingBox3D(min: SIMD3(repeating: -radius), max: SIMD3(repeating: radius)).transformed(by: transform.matrix)
        case let .roundedBox(size, _, transform):
            return BoundingBox3D(min: -size / 2, max: size / 2).transformed(by: transform.matrix)
        case let .capsule(start, end, radius):
            return BoundingBox3D(min: simd_min(start, end) - radius, max: simd_max(start, end) + radius)
        case let .smoothUnion(shapes, smoothing):
            let boxes = shapes.compactMap(\.bounds)
            guard var result = boxes.first else {
                return nil
            }
            for box in boxes.dropFirst() {
                result = BoundingBox3D(min: simd_min(result.min, box.min), max: simd_max(result.max, box.max))
            }
            return Self.padded(result, smoothing)
        case let .smoothSubtraction(base, _, smoothing):
            return base.bounds.map { Self.padded($0, smoothing) }
        case let .smoothIntersection(first, second, smoothing):
            guard let first = first.bounds, let second = second.bounds else {
                return nil
            }
            let box = BoundingBox3D(min: simd_max(first.min, second.min), max: simd_min(first.max, second.max))
            guard all(box.min .<= box.max) else {
                return nil
            }
            return Self.padded(box, smoothing)
        }
    }

    /// The postfix program that the shader runs. Throws if it needs a deeper stack than the shader has.
    func instructions() throws -> [SignedDistanceInstruction] {
        var program: [SignedDistanceInstruction] = []
        var depth = 0
        var maximumDepth = 0
        func push(_ instruction: SignedDistanceInstruction) {
            program.append(instruction)
            depth += 1
            maximumDepth = max(maximumDepth, depth)
        }
        func combine(_ operation: Int32, _ smoothing: Float) {
            program.append(Self.instruction(operation: operation, smoothing: smoothing))
            depth -= 1
        }
        func encode(_ shape: Self) {
            switch shape {
            case let .sphere(radius, transform):
                var instruction = Self.instruction(operation: SIGNED_DISTANCE_OP_SPHERE, transform: transform)
                instruction.parameters = [radius, 0, 0, 0]
                push(instruction)
            case let .roundedBox(size, cornerRadius, transform):
                var instruction = Self.instruction(operation: SIGNED_DISTANCE_OP_ROUNDED_BOX, transform: transform)
                instruction.parameters = SIMD4(size / 2, Self.clampedCornerRadius(cornerRadius, size: size))
                push(instruction)
            case let .capsule(start, end, radius):
                var instruction = Self.instruction(operation: SIGNED_DISTANCE_OP_CAPSULE)
                instruction.parameters = SIMD4(start, radius)
                instruction.end = SIMD4(end, 0)
                push(instruction)
            case let .smoothUnion(shapes, smoothing):
                // Folded pairwise, so the stack grows with nesting, not with the number of shapes.
                let shapes = shapes.filter { !$0.isEmpty }
                for (index, child) in shapes.enumerated() {
                    encode(child)
                    if index > 0 {
                        combine(SIGNED_DISTANCE_OP_SMOOTH_UNION, smoothing)
                    }
                }
            case let .smoothSubtraction(base, cut, smoothing):
                encodePair(base, cut, SIGNED_DISTANCE_OP_SMOOTH_SUBTRACTION, smoothing)
            case let .smoothIntersection(first, second, smoothing):
                encodePair(first, second, SIGNED_DISTANCE_OP_SMOOTH_INTERSECTION, smoothing)
            }
        }
        // An empty operand leaves the other operand (subtraction) or nothing (intersection).
        func encodePair(_ first: Self, _ second: Self, _ operation: Int32, _ smoothing: Float) {
            switch (first.isEmpty, second.isEmpty) {
            case (false, false):
                encode(first)
                encode(second)
                combine(operation, smoothing)
            case (false, true) where operation == SIGNED_DISTANCE_OP_SMOOTH_SUBTRACTION:
                encode(first)
            default:
                break
            }
        }
        encode(self)
        let maximum = Int(kSignedDistanceMaxStackDepth)
        guard maximumDepth <= maximum else {
            throw SignedDistanceShapeError.tooDeep(depth: maximumDepth, maximum: maximum)
        }
        return program
    }

    /// Whether the shape has no surface.
    var isEmpty: Bool {
        bounds == nil
    }

    /// A node that draws the shape, labeled "Signed Distance Shape". It has no content when the shape is empty.
    ///
    /// The node's mesh is the shape's bounding box, for culling and selection. To change the shape, call
    /// ``SceneSprockets/SceneGraph/Node/setSignedDistanceShape(_:surface:device:)``.
    func makeNode(device: MTLDevice, surface: SignedDistanceMaterial.Surface) throws -> SceneGraph.Node {
        let node = SceneGraph.Node(label: "Signed Distance Shape")
        try node.setSignedDistanceShape(self, surface: surface, device: device)
        return node
    }
}

public extension SceneGraph.Node {
    /// Replaces the node's content with a signed distance shape. Shapes that move each frame are cheap to set: only
    /// the program and an 8-vertex bounding box are rebuilt.
    func setSignedDistanceShape(_ shape: SignedDistanceShape, surface: SignedDistanceMaterial.Surface, device: MTLDevice) throws {
        guard let bounds = shape.bounds else {
            content = .empty
            return
        }
        var material = try SignedDistanceMaterial(shape: shape, surface: surface)
        if case let .mesh(_, materials, _, receivesShadow) = content, let existing = materials.first as? SignedDistanceMaterial {
            material.maxSteps = existing.maxSteps
            material.hitThreshold = existing.hitThreshold
            material.stepScale = existing.stepScale
            content = .mesh(Self.boundsMesh(bounds, device: device), materials: [material], castsShadow: false, receivesShadow: receivesShadow)
        } else {
            content = .mesh(Self.boundsMesh(bounds, device: device), materials: [material], castsShadow: false)
        }
    }

    private static func boundsMesh(_ bounds: BoundingBox3D, device: MTLDevice) -> MetalMesh {
        let corners = (0..<8).map { index in
            SIMD3<Float>(
                index & 1 == 0 ? bounds.min.x : bounds.max.x,
                index & 2 == 0 ? bounds.min.y : bounds.max.y,
                index & 4 == 0 ? bounds.min.z : bounds.max.z
            )
        }
        let indices: [UInt32] = [0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5, 0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6]
        return MetalMesh(
            device: device,
            attributes: [.positions(corners)],
            submeshes: [MetalMesh.SubmeshIndices(label: "Bounds", indices: indices, primitiveType: .triangle)],
            label: "Signed Distance Bounds"
        )
    }
}

extension SignedDistanceShape {
    // The polynomial smooth minimum; the shader uses the same formula.
    static func smoothMin(_ a: Float, _ b: Float, _ k: Float) -> Float {
        guard k > 0 else {
            return min(a, b)
        }
        let h = max(k - abs(a - b), 0) / k
        return min(a, b) - h * h * k * 0.25
    }

    // Smooth operations move the surface out by at most a quarter of the smoothing distance.
    static func padded(_ box: BoundingBox3D, _ smoothing: Float) -> BoundingBox3D {
        let padding = max(smoothing, 0) * 0.25
        return BoundingBox3D(min: box.min - padding, max: box.max + padding)
    }

    static func clampedCornerRadius(_ radius: Float, size: SIMD3<Float>) -> Float {
        simd_clamp(radius, 0, (size / 2).min())
    }

    // The position in the primitive's space, and the smallest axis scale that turns its distances back.
    static func local(_ position: SIMD3<Float>, _ transform: Transform3D) -> (SIMD3<Float>, Float) {
        let matrix = transform.matrix
        let local = (matrix.inverse * SIMD4(position, 1)).xyz
        return (local, minimumScale(matrix))
    }

    static func minimumScale(_ matrix: simd_float4x4) -> Float {
        min(simd_length(matrix.columns.0.xyz), simd_length(matrix.columns.1.xyz), simd_length(matrix.columns.2.xyz))
    }

    static func instruction(operation: Int32, transform: Transform3D = .identity, smoothing: Float = 0) -> SignedDistanceInstruction {
        let matrix = transform.matrix
        var instruction = SignedDistanceInstruction()
        instruction.inverseTransform = matrix.inverse
        instruction.operation = operation
        instruction.smoothing = smoothing
        instruction.scale = minimumScale(matrix)
        return instruction
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
