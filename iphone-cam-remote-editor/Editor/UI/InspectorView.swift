import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case basic, wheels, curves, hsl, looks
    var id: String { rawValue }
    var name: String {
        switch self {
        case .basic: return "Básicos"
        case .wheels: return "Ruedas"
        case .curves: return "Curvas"
        case .hsl: return "HSL"
        case .looks: return "Looks"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var model: EditorModel
    @State private var tab: InspectorTab = .basic

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .basic: BasicPanel()
                    case .wheels: WheelsPanel()
                    case .curves: CurvesPanel()
                    case .hsl: HSLPanel()
                    case .looks: LooksPanel()
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                Button("Restablecer todo") { model.resetAll() }
                Spacer()
                Toggle("Comprimir altas luces", isOn: $model.highlightRolloff)
                    .toggleStyle(.checkbox)
                    .help("Comprime suavemente lo que supere el pico del destino en vez de recortarlo")
            }
            .padding(10)
        }
        .disabled(model.clip == nil)
    }
}

/// Fila de control deslizante con valor y doble clic para restablecer.
struct AdjustSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var format: (Double) -> String = { String(format: "%+.0f", $0 * 100) }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(value == 0 ? .secondary : .primary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = 0 }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
        .help("Doble clic en el nombre para restablecer")
    }
}

struct PanelHeader: View {
    let title: String
    var reset: (() -> Void)?
    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let reset { Button("Restablecer", action: reset).buttonStyle(.borderless).font(.caption) }
        }
    }
}

struct BasicPanel: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        PanelHeader(title: "Luz") {
            model.settings.exposure = 0; model.settings.contrast = 0; model.settings.highlights = 0
            model.settings.shadows = 0; model.settings.whites = 0; model.settings.blacks = 0
        }
        AdjustSlider(title: "Exposición", value: $model.settings.exposure, range: -4...4,
                     format: { String(format: "%+.2f EV", $0) })
        AdjustSlider(title: "Contraste", value: $model.settings.contrast)
        AdjustSlider(title: "Altas luces", value: $model.settings.highlights)
        AdjustSlider(title: "Sombras", value: $model.settings.shadows)
        AdjustSlider(title: "Blancos", value: $model.settings.whites)
        AdjustSlider(title: "Negros", value: $model.settings.blacks)

        Divider()
        PanelHeader(title: "Color") {
            model.settings.temperature = 0; model.settings.tint = 0
            model.settings.saturation = 0; model.settings.vibrance = 0
        }
        AdjustSlider(title: "Temperatura", value: $model.settings.temperature)
            .overlay(alignment: .bottom) { gradientBar([.blue, .white, .orange]) }
        AdjustSlider(title: "Tinte", value: $model.settings.tint)
            .overlay(alignment: .bottom) { gradientBar([.green, .white, .pink]) }
        AdjustSlider(title: "Saturación", value: $model.settings.saturation)
        AdjustSlider(title: "Vibrancia", value: $model.settings.vibrance)

        Divider()
        PanelHeader(title: "Entrada")
        Picker("Interpretar como", selection: $model.inputOverride) {
            ForEach(InputInterpretation.allCases) { Text($0.name).tag($0) }
        }
        if let clip = model.clip {
            Text("Detectado: \(clip.colorLabel)").font(.caption).foregroundStyle(.secondary)
        }
        if model.effectiveInput == .appleLog2 {
            Text("Apple Log 2: la curva es la de Apple Log; el gamut Apple Wide Gamut se aproxima como BT.2020.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("Procesado en coma flotante de 16 bits, lineal BT.2020: el HDR no se recorta.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func gradientBar(_ colors: [Color]) -> some View {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
            .frame(height: 2).opacity(0.6).padding(.horizontal, 2).offset(y: 2)
    }
}

struct WheelsPanel: View {
    @EnvironmentObject var model: EditorModel
    var body: some View {
        PanelHeader(title: "Ruedas de color") {
            model.settings.lift = WheelValue(); model.settings.gamma = WheelValue(); model.settings.gain = WheelValue()
        }
        HStack(alignment: .top, spacing: 10) {
            ColorWheelControl(title: "Lift", subtitle: "Sombras", value: $model.settings.lift)
            ColorWheelControl(title: "Gamma", subtitle: "Medios", value: $model.settings.gamma)
            ColorWheelControl(title: "Gain", subtitle: "Luces", value: $model.settings.gain)
        }
        Text("Arrastra el punto para teñir; el deslizador ajusta el brillo de cada zona. Doble clic restablece.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct CurvesPanel: View {
    @EnvironmentObject var model: EditorModel
    @State private var channel = 0

    var body: some View {
        PanelHeader(title: "Curvas") { model.settings.curves = CurveSet() }
        Picker("", selection: $channel) {
            Text("Luma").tag(0); Text("Rojo").tag(1); Text("Verde").tag(2); Text("Azul").tag(3)
        }
        .pickerStyle(.segmented).labelsHidden()
        CurveEditor(points: binding, color: [Color.white, .red, .green, .blue][channel])
            .aspectRatio(1, contentMode: .fit)
        HStack {
            Text("Clic para añadir un punto, arrastra para moverlo, doble clic para quitarlo.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Recta") { binding.wrappedValue = CurveSet.identity }.buttonStyle(.borderless).font(.caption)
        }
        Text("Por encima de 1 (HDR) la curva continúa con su última pendiente.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var binding: Binding<[CurvePoint]> {
        switch channel {
        case 1: return $model.settings.curves.red
        case 2: return $model.settings.curves.green
        case 3: return $model.settings.curves.blue
        default: return $model.settings.curves.master
        }
    }
}

struct HSLPanel: View {
    @EnvironmentObject var model: EditorModel
    @State private var band: HSLBand = .orange

    static let swatches: [Color] = [
        Color(hue: 0, saturation: 0.85, brightness: 0.9), Color(hue: 30 / 360, saturation: 0.85, brightness: 0.95),
        Color(hue: 60 / 360, saturation: 0.85, brightness: 0.95), Color(hue: 120 / 360, saturation: 0.75, brightness: 0.8),
        Color(hue: 180 / 360, saturation: 0.75, brightness: 0.85), Color(hue: 240 / 360, saturation: 0.75, brightness: 0.9),
        Color(hue: 270 / 360, saturation: 0.7, brightness: 0.85), Color(hue: 300 / 360, saturation: 0.7, brightness: 0.9)
    ]

    var body: some View {
        PanelHeader(title: "Tono · Saturación · Luminancia") {
            model.settings.hsl = [HSLAdjust](repeating: HSLAdjust(), count: HSLBand.allCases.count)
        }
        HStack(spacing: 6) {
            ForEach(HSLBand.allCases) { b in
                Circle().fill(Self.swatches[b.rawValue])
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.primary, lineWidth: band == b ? 2.5 : 0))
                    .overlay(alignment: .topTrailing) {
                        if !model.settings.hsl[b.rawValue].isNeutral { Circle().fill(.white).frame(width: 6, height: 6) }
                    }
                    .onTapGesture { band = b }
                    .help(b.name)
            }
        }
        Text(band.name).font(.subheadline.bold())
        AdjustSlider(title: "Tono", value: $model.settings.hsl[band.rawValue].hue,
                     format: { String(format: "%+.0f°", $0 * 30) })
        AdjustSlider(title: "Saturación", value: $model.settings.hsl[band.rawValue].sat)
        AdjustSlider(title: "Luminancia", value: $model.settings.hsl[band.rawValue].lum)
    }
}
