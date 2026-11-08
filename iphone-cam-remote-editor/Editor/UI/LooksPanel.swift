import SwiftUI

struct LooksPanel: View {
    @EnvironmentObject var model: EditorModel
    @State private var newPresetName = ""

    private var grouped: [(String, [Preset])] {
        var order: [String] = []
        var dict: [String: [Preset]] = [:]
        for p in model.allPresets {
            if dict[p.category] == nil { order.append(p.category) }
            dict[p.category, default: []].append(p)
        }
        return order.map { ($0, dict[$0]!) }
    }

    var body: some View {
        LUTSection()
        Divider()

        PanelHeader(title: "Presets")
        HStack {
            TextField("Nombre del preset", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Button("Guardar", action: save).help("Guarda los ajustes actuales como preset (JSON)")
        }
        HStack {
            Button("Importar JSON…") { model.importPresets() }
            Button("Exportar ajustes…") { model.exportCurrentAsPreset() }
        }
        .buttonStyle(.borderless).font(.caption)

        ForEach(grouped, id: \.0) { category, presets in
            Text(category).font(.subheadline.bold()).padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(presets) { p in PresetTile(preset: p) }
            }
        }
    }

    private func save() {
        model.saveUserPreset(name: newPresetName.trimmingCharacters(in: .whitespaces))
        newPresetName = ""
    }
}

struct PresetTile: View {
    @EnvironmentObject var model: EditorModel
    let preset: Preset

    var body: some View {
        let selected = model.selectedPresetID == preset.id
        Button { model.apply(preset) } label: { tile(selected) }
            .buttonStyle(.plain)
            .accessibilityLabel(preset.name)
            .help(preset.output.map { "\(preset.name) — salida \($0.name)" } ?? preset.name)
            .contextMenu {
                Button("Aplicar") { model.apply(preset) }
                Button("Exportar como JSON…") { model.exportPreset(preset) }
                if !preset.builtIn {
                    Divider()
                    Button("Eliminar", role: .destructive) { model.deleteUserPreset(preset) }
                }
            }
    }

    private func tile(_ selected: Bool) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Color.black
                if let img = model.thumbnails[preset.id] {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
            Text(preset.name).font(.caption).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

struct LUTSection: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        PanelHeader(title: "LUT (.cube)")
        HStack {
            Picker("LUT", selection: Binding(get: { model.settings.lut?.name }, set: { model.selectLUT($0) })) {
                Text("Ninguno").tag(String?.none)
                ForEach(model.luts, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            Button("Importar…") { model.importLUTs() }
        }
        if let ref = model.settings.lut {
            AdjustSlider(title: "Intensidad", value: Binding(get: { ref.intensity },
                                                             set: { model.settings.lut?.intensity = $0 }),
                         range: 0...1, format: { String(format: "%.0f %%", $0 * 100) })
            HStack {
                Picker("Entrada", selection: Binding(get: { ref.input }, set: { model.settings.lut?.input = $0 })) {
                    ForEach(LUTSpace.allCases) { Text($0.name).tag($0) }
                }
                Picker("Salida", selection: Binding(get: { ref.output }, set: { model.settings.lut?.output = $0 })) {
                    ForEach(LUTSpace.allCases) { Text($0.name).tag($0) }
                }
            }
            .font(.caption)
            HStack {
                Text("Espacio en el que el LUT espera la imagen y en el que la devuelve.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quitar de la biblioteca", role: .destructive) { model.deleteLUT(ref.name) }
                    .buttonStyle(.borderless).font(.caption)
            }
            if LUTLibrary.load(ref.name) == nil {
                Text("No se encuentra el archivo de este LUT.").font(.caption).foregroundStyle(.red)
            }
        }
    }
}
