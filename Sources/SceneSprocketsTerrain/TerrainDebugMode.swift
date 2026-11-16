/// Ways to color the terrain by an internal quantity instead of shading it. Raw values match DebugMode in Terrain.metal.
public enum TerrainDebugMode: Int, CaseIterable, Identifiable, Sendable {
    case off
    case height
    case slope
    case normal
    case aspect
    case curvature
    case valley
    case boundaryNoise
    case winningLayer
    case layerWeight
    case colorMap
    case maskMap
    case detail
    case lightingOnly
    case albedoOnly
    case fog
    case leafDepth
    case leafID
    case meshletTriangle
    case triangleSize
    case heightVariance

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .off: "Off"
        case .height: "Height"
        case .slope: "Slope"
        case .normal: "Normal"
        case .aspect: "Aspect"
        case .curvature: "Curvature"
        case .valley: "Valley Depth"
        case .boundaryNoise: "Boundary Noise"
        case .winningLayer: "Winning Layer"
        case .layerWeight: "Layer Weight"
        case .colorMap: "Color Map"
        case .maskMap: "Mask Map"
        case .detail: "Detail Normal"
        case .lightingOnly: "Lighting Only"
        case .albedoOnly: "Albedo Only"
        case .fog: "Fog Amount"
        case .leafDepth: "Leaf Depth"
        case .leafID: "Leaf ID"
        case .meshletTriangle: "Meshlet Triangle"
        case .triangleSize: "Triangle Size"
        case .heightVariance: "Height Variance"
        }
    }
}
