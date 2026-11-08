import SwiftUI
import UniformTypeIdentifiers

struct ExportSheet: View {
    @EnvironmentObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .prores422HQ
    @State private var output: OutputSpace = .rec709
    @State private var useTrim = true
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Exportar").font(.title2.bold())

            Form {
                Picker("Formato", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.name).tag($0) }
                }
                Picker("Color", selection: $output) {
                    ForEach(OutputSpace.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Solo el tramo recortado (\(String(format: "%.2f", model.trimOut - model.trimIn)) s)", isOn: $useTrim)
                    .disabled(model.trimIn <= 0.001 && model.trimOut >= model.duration - 0.001)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let clip = model.clip {
                    Label("\(clip.width)×\(clip.height) · mismos fps que el original", systemImage: "aspectratio")
                    Label(clip.audio.isEmpty ? "Sin audio" : "Audio copiado sin recomprimir: \(clip.audio.joined(separator: " + "))",
                          systemImage: "waveform")
                }
                Label(output.isHDR ? "Metadatos HLG · BT.2020 (HDR)" : "Metadatos \(output == .p3d65 ? "P3 D65" : "Rec.709") (SDR)",
                      systemImage: "camera.filters")
            }
            .font(.callout).foregroundStyle(.secondary)

            if let p = model.exportProgress {
                ProgressView(value: p) { Text("Exportando… \(Int(p * 100)) %") }
            } else if let url = model.lastExportURL, started {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }

            HStack {
                Spacer()
                if model.exportProgress != nil {
                    Button("Cancelar exportación", role: .cancel) { model.cancelExport() }
                } else {
                    Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Exportar…") { chooseAndExport() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            output = model.output
            useTrim = !(model.trimIn <= 0.001 && model.trimOut >= model.duration - 0.001)
        }
    }

    private func chooseAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        let def = model.defaultExportURL(format: format)
        panel.directoryURL = def.deletingLastPathComponent()
        panel.nameFieldStringValue = def.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        started = true
        model.startExport(format: format, output: output, useTrim: useTrim, url: url)
    }
}
