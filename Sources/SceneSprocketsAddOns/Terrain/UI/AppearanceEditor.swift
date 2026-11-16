import CoreGraphics
import SceneSprocketsAddOnsShaders
import SwiftUI

/// Controls for `TerrainSettings.style` and the sun direction.
public struct AppearanceEditor: View {
    @Binding var settings: TerrainSettings
    /// Last preset chosen here; the material may have been edited since.
    @State private var presetIndex = 0

    public init(settings: Binding<TerrainSettings>) {
        _settings = settings
    }

    public var body: some View {
        Form {
            Section {
                Picker("Preset", selection: presetBinding) {
                    ForEach(TerrainStyle.presets.indices, id: \.self) { index in
                        Text(TerrainStyle.presets[index].name).tag(index)
                    }
                }
            }
            Section("Sun") {
                slider("Azimuth", azimuthBinding, 0 ... 360, format: "%.0f°")
                slider("Elevation", elevationBinding, 1 ... 89, format: "%.0f°")
                ColorPicker("Color", selection: colorBinding(\.sunColor), supportsOpacity: false)
                slider("Intensity", $settings.style.material.sunIntensity, 0 ... 4)
            }
            Section("Sky") {
                ColorPicker("Zenith", selection: colorBinding(\.skyZenithColor), supportsOpacity: false)
                ColorPicker("Horizon", selection: colorBinding(\.skyHorizonColor), supportsOpacity: false)
                slider("Sky light", $settings.style.material.skyLightIntensity, 0 ... 2)
                slider("Exposure", $settings.style.material.exposure, 0.1 ... 3)
            }
            Section("Surface Detail") {
                slider("Scale", $settings.style.material.detailScale, 0.2 ... 10, format: "%.1f m")
                slider("Bumps", $settings.style.material.detailStrength, 0 ... 1.5)
                slider("Fade distance", $settings.style.material.detailDistance, 0 ... 2_000, format: "%.0f m")
            }
            Section("Fog") {
                slider("Density", fogDensityBinding, 0 ... 30, format: "%.1f")
                slider("Height falloff", fogFalloffBinding, 0 ... 10, format: "%.1f")
            }
            Section {
                ForEach(settings.style.layers.indices, id: \.self) { index in
                    layerEditor(index)
                }
                Button("Add Layer") {
                    settings.style.layers.append(TerrainLayer([0.5, 0.5, 0.5], altitude: [0.2, 0.3, 100, 100]))
                }
                slider("Noise scale", $settings.style.material.boundaryNoiseScale, 5 ... 500, format: "%.0f m")
            } header: {
                Text("Layers (painted bottom to top)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 620)
    }

    // MARK: - Rows

    private func slider(_ title: String, _ value: Binding<Float>, _ bounds: ClosedRange<Float>, format: String = "%.2f") -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: bounds)
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func layerEditor(_ index: Int) -> some View {
        let layer = layerBinding(index)
        let count = settings.style.layers.count
        return DisclosureGroup {
            ColorPicker("Color", selection: colorBinding(layer.color), supportsOpacity: false)
            Toggle("Color from color map", isOn: Binding { layer.wrappedValue.usesColorMap != 0 } set: { layer.wrappedValue.usesColorMap = $0 ? 1 : 0 })
            slider("Opacity", layer.opacity, 0 ... 1)
            slider("Color variation", layer.colorVariation, 0 ... 0.5)
            Picker("Mask", selection: layer.maskChannel) {
                Text("None").tag(Int32(-1))
                Text("Red").tag(Int32(0))
                Text("Green").tag(Int32(1))
                Text("Blue").tag(Int32(2))
                Text("Alpha").tag(Int32(3))
            }
            band("Altitude", layer.altitudeBand, -1.5 ... 1.5)
            slider("Altitude noise", layer.altitudeNoise, 0 ... 0.3, format: "%.3f")
            band("Slope", layer.slopeBand, 0 ... 1)
            slider("Slope noise", layer.slopeNoise, 0 ... 0.3, format: "%.3f")
            band("Curvature (ridge → gully)", layer.curvatureBand, -0.5 ... 0.5)
            band("Valley depth", layer.valleyBand, -0.3 ... 0.3)
            band("Aspect (away → toward)", layer.aspectBand, -1 ... 1)
            slider("Aspect direction", layer.aspectAzimuth, 0 ... 360, format: "%.0f°")
            Button("Reset Shape Bands") {
                layer.wrappedValue.curvatureBand = TerrainLayer.anywhere
                layer.wrappedValue.valleyBand = TerrainLayer.anywhere
                layer.wrappedValue.aspectBand = TerrainLayer.anywhere
            }
            HStack {
                Button("Move Down") { moveLayer(index, by: -1) }
                    .disabled(index == 0)
                Button("Move Up") { moveLayer(index, by: 1) }
                    .disabled(index == count - 1)
                Spacer()
                Button("Delete", role: .destructive) { settings.style.layers.remove(at: index) }
            }
        } label: {
            HStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(cgColor: colorBinding(layer.color).wrappedValue))
                    .frame(width: 16, height: 16)
                Text("Layer \(index + 1)")
            }
        }
    }

    /// (fade in start, full start, full end, fade out end). Values outside `bounds` mean open-ended and pin to the ends.
    private func band(_ title: String, _ value: Binding<SIMD4<Float>>, _ bounds: ClosedRange<Float>) -> some View {
        LabeledContent(title) {
            VStack(spacing: 2) {
                ForEach(0 ..< 4, id: \.self) { component in
                    Slider(value: Binding { value.wrappedValue[component] } set: { value.wrappedValue[component] = $0 }, in: bounds)
                }
            }
        }
    }

    private func moveLayer(_ index: Int, by offset: Int) {
        var layers = settings.style.layers
        layers.swapAt(index, index + offset)
        settings.style.layers = layers
    }

    // MARK: - Bindings

    private var presetBinding: Binding<Int> {
        Binding {
            presetIndex
        } set: { index in
            presetIndex = index
            if TerrainStyle.presets.indices.contains(index) {
                settings.style = TerrainStyle.presets[index].style
            }
        }
    }

    private var azimuthBinding: Binding<Float> {
        Binding {
            (settings.sunAzimuth + 360).truncatingRemainder(dividingBy: 360)
        } set: { azimuth in
            settings.setSun(azimuth: azimuth, elevation: settings.sunElevation)
        }
    }

    private var elevationBinding: Binding<Float> {
        Binding {
            settings.sunElevation
        } set: { elevation in
            settings.setSun(azimuth: settings.sunAzimuth, elevation: elevation)
        }
    }

    // Shown per 100 km and per km so the slider values are readable.
    private var fogDensityBinding: Binding<Float> {
        Binding { settings.style.material.fogDensity * 100_000 } set: { settings.style.material.fogDensity = $0 / 100_000 }
    }

    private var fogFalloffBinding: Binding<Float> {
        Binding { settings.style.material.fogFalloff * 1_000 } set: { settings.style.material.fogFalloff = $0 / 1_000 }
    }

    private func layerBinding(_ index: Int) -> Binding<TerrainLayer> {
        Binding {
            let layers = settings.style.layers
            return layers.indices.contains(index) ? layers[index] : TerrainLayer()
        } set: { layer in
            var layers = settings.style.layers
            if layers.indices.contains(index) {
                layers[index] = layer
                settings.style.layers = layers
            }
        }
    }

    /// Material colors are linear; the picker shows them through a linear color space so they look as rendered.
    private func colorBinding(_ keyPath: WritableKeyPath<TerrainMaterial, SIMD3<Float>>) -> Binding<CGColor> {
        colorBinding($settings.style.material[dynamicMember: keyPath])
    }

    private func colorBinding(_ color: Binding<SIMD3<Float>>) -> Binding<CGColor> {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return Binding {
            let color = color.wrappedValue
            return CGColor(colorSpace: space, components: [CGFloat(color.x), CGFloat(color.y), CGFloat(color.z), 1])!
        } set: { newColor in
            guard let linear = newColor.converted(to: space, intent: .defaultIntent, options: nil), let components = linear.components, components.count >= 3 else {
                return
            }
            color.wrappedValue = SIMD3(Float(components[0]), Float(components[1]), Float(components[2]))
        }
    }
}
