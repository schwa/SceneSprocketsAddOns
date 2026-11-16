import SceneSprocketsTerrainShaders
import simd

public extension TerrainLayer {
    /// Open-ended band: the layer applies to any altitude or slope.
    static let anywhere = SIMD4<Float>(-100, -100, 100, 100)

    init(
        _ color: SIMD3<Float>,
        altitude: SIMD4<Float> = anywhere,
        slope: SIMD4<Float> = anywhere,
        curvature: SIMD4<Float> = anywhere,
        valley: SIMD4<Float> = anywhere,
        aspect: SIMD4<Float> = anywhere,
        aspectAzimuth: Float = 0,
        colorVariation: Float = 0.1,
        usesColorMap: Bool = false,
        maskChannel: Int32 = -1,
        altitudeNoise: Float = 0,
        slopeNoise: Float = 0,
        opacity: Float = 1
    ) {
        self.init()
        self.color = color
        altitudeBand = altitude
        slopeBand = slope
        curvatureBand = curvature
        valleyBand = valley
        aspectBand = aspect
        self.aspectAzimuth = aspectAzimuth
        self.colorVariation = colorVariation
        self.usesColorMap = usesColorMap ? 1 : 0
        self.maskChannel = maskChannel
        self.altitudeNoise = altitudeNoise
        self.slopeNoise = slopeNoise
        self.opacity = opacity
    }
}

/// A terrain's look: global material settings plus any number of layers, painted bottom to top. The layers are
/// uploaded as their own buffer.
public struct TerrainStyle: Sendable {
    public var material: TerrainMaterial
    public var layers: [TerrainLayer]

    public init(material: TerrainMaterial, layers: [TerrainLayer]) {
        self.material = material
        self.layers = layers
    }

    /// The material and layers with their derived fields (fade scales, aspect direction, feature masks, layer count)
    /// filled in, as the shaders expect. Renderers also set the color and mask placements.
    func prepared() -> (material: TerrainMaterial, layers: [TerrainLayer]) {
        func scales(_ band: SIMD4<Float>) -> SIMD2<Float> {
            func scale(_ width: Float) -> Float {
                width > 1e-6 ? 1 / width : 1e6
            }
            return [scale(band.y - band.x), scale(band.w - band.z)]
        }
        func isOpen(_ band: SIMD4<Float>) -> Bool {
            band.y <= -10 && band.z >= 10
        }
        let preparedLayers = layers.map { layer in
            var layer = layer
            let altitude = scales(layer.altitudeBand)
            let slope = scales(layer.slopeBand)
            let curvature = scales(layer.curvatureBand)
            let valley = scales(layer.valleyBand)
            layer.fadeScale = [altitude.x, altitude.y, slope.x, slope.y]
            layer.featureFadeScale = [curvature.x, curvature.y, valley.x, valley.y]
            layer.aspectFadeScale = scales(layer.aspectBand)
            let azimuth = layer.aspectAzimuth * .pi / 180
            layer.aspectDirection = [sin(azimuth), -cos(azimuth)]
            layer.featureMask = (isOpen(layer.curvatureBand) ? 0 : 1) | (isOpen(layer.valleyBand) ? 0 : 2) | (isOpen(layer.aspectBand) ? 0 : 4)
                | (layer.usesColorMap != 0 ? 8 : 0) | ((0 ... 3).contains(layer.maskChannel) ? 16 : 0)
            return layer
        }
        var material = material
        material.layerCount = UInt32(preparedLayers.count)
        material.featureMask = preparedLayers.reduce(0) { $0 | $1.featureMask }
        return (material, preparedLayers)
    }

    /// Alpine grass, rock and snow under a clear sky.
    public static let alpine: TerrainStyle = {
        var material = TerrainMaterial()
        material.boundaryNoiseScale = 60
        material.detailScale = 1.5
        material.detailStrength = 0.12
        material.detailDistance = 400
        material.sunColor = [1.0, 0.95, 0.85]
        material.skyZenithColor = [0.22, 0.42, 0.75]
        material.skyHorizonColor = [0.70, 0.80, 0.90]
        material.sunIntensity = 1.6
        material.skyLightIntensity = 0.45
        material.fogDensity = 0.00005
        material.fogFalloff = 0.0015
        // Fog fades to the built-in sky; with a custom sky, set fogSkyBlend to 0 and fogColor to match it.
        material.fogColor = material.skyHorizonColor
        material.fogSkyBlend = 1
        material.exposure = 0.8
        material.contourInterval = 0
        material.contourOpacity = 0.6
        let grass: SIMD3<Float> = [0.20, 0.30, 0.10]
        return Self(material: material, layers: [
            TerrainLayer([0.42, 0.34, 0.22]), // dirt
            TerrainLayer(grass, slope: [0.75, 0.9, 100, 100], colorVariation: 0.2, slopeNoise: 0.06),
            TerrainLayer(grass * 0.8, altitude: [-100, -100, -0.4, 0], altitudeNoise: 0.08), // lowland
            TerrainLayer([0.36, 0.31, 0.27], slope: [-100, -100, 0.6, 0.75], slopeNoise: 0.06), // rock
            TerrainLayer([0.92, 0.94, 0.97], altitude: [0.45, 0.5, 100, 100], slope: [0.55, 0.75, 100, 100], colorVariation: 0.03, altitudeNoise: 0.12, slopeNoise: 0.06) // snow
        ])
    }()

    /// Red rock and sand, no snow, hazy warm sky.
    public static let desert: TerrainStyle = {
        var style = alpine
        style.layers = [
            TerrainLayer([0.42, 0.22, 0.11]), // dirt
            TerrainLayer([0.50, 0.32, 0.16], slope: [0.75, 0.9, 100, 100], slopeNoise: 0.06), // sand
            TerrainLayer([0.55, 0.40, 0.22], altitude: [-100, -100, -0.4, 0], altitudeNoise: 0.08), // pale flats
            TerrainLayer([0.30, 0.13, 0.07], slope: [-100, -100, 0.6, 0.75], slopeNoise: 0.06) // red rock
        ]
        style.material.sunColor = [1.0, 0.90, 0.75]
        style.material.skyZenithColor = [0.35, 0.50, 0.75]
        style.material.skyHorizonColor = [0.90, 0.80, 0.65]
        style.material.fogDensity = 0.00008
        return style
    }()

    /// Snow down to the valleys, cold blue light.
    public static let arctic: TerrainStyle = {
        var style = alpine
        style.layers = [
            TerrainLayer([0.40, 0.40, 0.42]), // gravel
            TerrainLayer([0.35, 0.40, 0.38], slope: [0.75, 0.9, 100, 100], slopeNoise: 0.06), // tundra
            TerrainLayer([0.80, 0.85, 0.90], altitude: [-100, -100, -0.4, 0], altitudeNoise: 0.08), // frozen lowland
            TerrainLayer([0.25, 0.26, 0.28], slope: [-100, -100, 0.6, 0.75], slopeNoise: 0.06), // rock
            TerrainLayer([0.92, 0.94, 0.97], altitude: [-0.2, -0.15, 100, 100], slope: [0.45, 0.65, 100, 100], altitudeNoise: 0.12, slopeNoise: 0.06) // snow
        ]
        style.material.sunColor = [0.95, 0.97, 1.0]
        style.material.skyZenithColor = [0.30, 0.45, 0.70]
        style.material.skyHorizonColor = [0.80, 0.85, 0.92]
        style.material.sunIntensity = 1.4
        return style
    }()

    /// For low coastal terrain like the San Francisco Bay heightmap (peaks around 340 m with the default 1100 m height
    /// scale): flat blue water at the 0 m floor, a sand fringe, green lowland grass turning to golden grass higher up,
    /// rock on steep slopes. Altitudes are fractions of the height scale. A stopgap until there is real water (#25).
    public static let coastal: TerrainStyle = {
        var style = alpine
        func meters(_ value: Float) -> Float {
            value / 1_100
        }
        let grass: SIMD3<Float> = [0.22, 0.32, 0.12]
        style.layers = [
            TerrainLayer([0.42, 0.36, 0.24]), // dirt
            TerrainLayer(grass, slope: [0.7, 0.85, 100, 100], colorVariation: 0.2, slopeNoise: 0.05),
            // Golden dry grass on the higher hills.
            TerrainLayer([0.55, 0.45, 0.24], altitude: [meters(60), meters(140), 100, 100], slope: [0.7, 0.85, 100, 100], colorVariation: 0.15, altitudeNoise: meters(40), slopeNoise: 0.05),
            TerrainLayer([0.38, 0.34, 0.30], slope: [-100, -100, 0.55, 0.7], slopeNoise: 0.05), // rock
            TerrainLayer([0.76, 0.70, 0.52], altitude: [-100, -100, meters(3), meters(6)]), // sand
            TerrainLayer([0.06, 0.17, 0.28], altitude: [-100, -100, meters(0.2), meters(0.5)]) // water
        ]
        return style
    }()

    public static let presets: [(name: String, style: Self)] = [
        ("Alpine", alpine),
        ("Desert", desert),
        ("Arctic", arctic),
        ("Coastal", coastal),
        // Needs the demo maps loaded (HUD Demo Maps button).
        ("Maps Demo", DemoMaps.style)
    ]
}
