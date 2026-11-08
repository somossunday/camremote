import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            TrimTimeline()
                .frame(height: 34)
            HStack(spacing: 10) {
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .help("Fotograma anterior (←)")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Reproducir / pausa (espacio)")
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .help("Fotograma siguiente (→)")

                Text(timecode(model.currentTime)).monospacedDigit().frame(width: 92, alignment: .leading)

                Spacer()

                Button("Entrada") { model.markIn() }.keyboardShortcut("i", modifiers: []).help("Marcar entrada en el cabezal (I)")
                Text(timecode(model.trimIn)).monospacedDigit().foregroundStyle(.secondary)
                Text("→").foregroundStyle(.secondary)
                Text(timecode(model.trimOut)).monospacedDigit().foregroundStyle(.secondary)
                Button("Salida") { model.markOut() }.keyboardShortcut("o", modifiers: []).help("Marcar salida en el cabezal (O)")
                Button { model.resetTrim() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Quitar recorte")
                Text("Duración \(timecode(model.trimOut - model.trimIn))")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func timecode(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00:00" }
        let fps = max(1, (model.clip?.fps ?? 30).rounded())
        let total = Int(t)
        let f = Int(((t - Double(total)) * fps).rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 60, total % 60, f)
    }
}

/// Barra de tiempo con cabezal y asas de recorte (entrada/salida).
struct TrimTimeline: View {
    @EnvironmentObject var model: EditorModel
    private enum DragTarget { case playhead, trimIn, trimOut }
    @State private var target: DragTarget?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let d = max(model.duration, 0.001)
            let xIn = w * model.trimIn / d, xOut = w * model.trimOut / d, xHead = w * model.currentTime / d
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.28))
                    .frame(width: max(0, xOut - xIn)).offset(x: xIn)
                handle.offset(x: xIn - 4)
                handle.offset(x: xOut - 4)
                Rectangle().fill(Color.white).frame(width: 2).offset(x: xHead - 1)
                    .shadow(radius: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let x = min(max(0, g.location.x), w)
                    if target == nil {
                        if abs(g.startLocation.x - xIn) < 8 { target = .trimIn }
                        else if abs(g.startLocation.x - xOut) < 8 { target = .trimOut }
                        else { target = .playhead }
                    }
                    let t = Double(x / w) * d
                    switch target {
                    case .trimIn: model.trimIn = min(t, model.trimOut - 0.1); model.seek(to: model.trimIn)
                    case .trimOut: model.trimOut = max(t, model.trimIn + 0.1); model.seek(to: model.trimOut)
                    default: model.seek(to: t)
                    }
                }
                .onEnded { _ in target = nil })
        }
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 8)
    }
}
