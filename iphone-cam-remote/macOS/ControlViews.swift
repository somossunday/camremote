import SwiftUI

// MARK: - Vista previa + grabación

struct PreviewPane: View {
    @EnvironmentObject var model: RemoteModel
    @State private var focusMark: CGPoint?

    /// Convierte el clic a coordenadas 0…1 dentro de la imagen (encajada con bandas negras).
    private func tapToFocus(_ loc: CGPoint, in box: CGSize, image: CGSize) {
        guard image.width > 0, image.height > 0 else { return }
        let scale = min(box.width / image.width, box.height / image.height)
        let w = image.width * scale, h = image.height * scale
        let x0 = (box.width - w) / 2, y0 = (box.height - h) / 2
        let u = (loc.x - x0) / w, v = (loc.y - y0) / h
        guard (0...1).contains(u), (0...1).contains(v) else { return }
        model.send(.focusAt(x: u, y: v))
        focusMark = loc
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if focusMark == loc { focusMark = nil } }
    }

    var body: some View {
        let s = model.state ?? CameraState()
        VStack(spacing: 0) {
            ZStack {
                Color.black
                LivePreviewImage(live: model.live, previewOn: model.previewOn, focusMark: focusMark, onTap: tapToFocus)
                VStack {
                    HStack {
                        if s.recording {
                            Label(RemoteModel.clock(s.recordingSeconds), systemImage: "record.circle.fill")
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.red, in: Capsule())
                        }
                        Spacer()
                        Text("\(s.resolution.label) · \(s.fps) fps · \(badge(s))")
                            .font(.caption.monospaced())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                .padding(14)
            }

            HStack(spacing: 18) {
                if s.battery >= 0 {
                    Label("\(Int(s.battery * 100)) %", systemImage: batteryIcon(s.battery)).fixedSize()
                }
                Label(ByteCountFormatter.string(fromByteCount: s.freeBytes, countStyle: .file), systemImage: "internaldrive").fixedSize().help("Espacio libre en el iPhone")
                Spacer(minLength: 8)
                Toggle("Vista previa", isOn: Binding(get: { model.previewOn }, set: model.setPreview))
                    .toggleStyle(.switch).controlSize(.small)
                    .fixedSize()
                RecordButton(recording: s.recording, action: model.toggleRecording)
            }
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func badge(_ s: CameraState) -> String {
        let q = s.videoQuality == .prores ? "ProRes HQ" : (s.videoQuality == .hdr ? "HEVC HDR" : s.codec.label)
        return s.appleLog ? q + " · Log" : q
    }

    private func batteryIcon(_ b: Float) -> String {
        switch b { case ..<0.15: "battery.0percent"; case ..<0.4: "battery.25percent"; case ..<0.65: "battery.50percent"; case ..<0.9: "battery.75percent"; default: "battery.100percent" }
    }
}

struct RecordButton: View {
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.primary.opacity(0.8), lineWidth: 3).frame(width: 44, height: 44)
                RoundedRectangle(cornerRadius: recording ? 4 : 17)
                    .fill(.red)
                    .frame(width: recording ? 18 : 34, height: recording ? 18 : 34)
            }
            .animation(.easeInOut(duration: 0.2), value: recording)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(recording ? "Parar (⌘R)" : "Grabar (⌘R)")
        .accessibilityLabel(recording ? "Parar grabación" : "Grabar")
    }
}

// MARK: - Panel de ajustes

struct ControlsPanel: View {
    @EnvironmentObject var model: RemoteModel

    var body: some View {
        let s = model.state ?? CameraState()
        Form {
            Section("Cámara") {
                Picker("Lente", selection: Binding(get: { s.camera }, set: { k in model.edit({ $0.camera = k }) { .setCamera($0.camera) } })) {
                    ForEach(s.availableCameras) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(s.recording)
                if s.cinematicActive {
                    if s.minAperture > 0 {
                        LabeledSlider(value: Double(s.aperture), range: Double(s.minAperture)...Double(max(s.maxAperture, s.minAperture + 0.1)),
                                      text: String(format: "f/%.1f", s.aperture)) { v in
                            model.edit({ $0.aperture = Float(v) }) { .setAperture($0.aperture) }
                        }
                        .disabled(s.recording)
                    }
                    Text("Desenfoque: f/ más bajo = más fondo borroso. Haz clic en la imagen para enfocar y seguir a alguien.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Haz clic en la imagen para enfocar ahí.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Audio") {
                Picker("Micro", selection: Binding(get: { s.audioInput ?? "" }, set: { id in model.edit({ $0.audioInput = id }) { .setAudioInput($0.audioInput ?? "") } })) {
                    if s.audioInputs.isEmpty { Text("Sin micro").tag("") }
                    ForEach(s.audioInputs) { Text($0.name).tag($0.id) }
                }
                .disabled(s.recording)
                LiveMeter(live: model.live)
                Picker("Calidad", selection: Binding(get: { s.audioCodec }, set: { c in model.edit({ $0.audioCodec = c }) { .setAudioCodec($0.audioCodec) } })) {
                    ForEach(AudioCodec.allCases) { Text($0.label).tag($0) }
                }
                .disabled(s.recording)
                if !s.audioFormat.isEmpty {
                    Text(s.audioFormat).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Guardado") {
                Toggle("Copiar también a Fotos", isOn: Binding(get: { s.saveToPhotos }, set: { v in model.edit({ $0.saveToPhotos = v }) { .setSaveToPhotos($0.saveToPhotos) } }))
                Text("Los vídeos se guardan en la app (Archivos › En mi iPhone › CamRemote) y se borran desde aquí sin confirmar en el iPhone. La copia en Fotos no se borra desde el Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Calidad de vídeo") {
                Picker("Calidad", selection: Binding(get: { s.videoQuality }, set: { q in model.send(.setVideoQuality(q)) })) {
                    ForEach(VideoQuality.allCases) { q in
                        Text(q.label).tag(q)
                            .disabled((q == .hdr && !s.hdrSupported) || (q == .prores && !s.proresSupported))
                    }
                }
                .pickerStyle(.segmented)
                Text(s.videoQuality.detail).font(.caption).foregroundStyle(.secondary)
                if s.logSupported {
                    Toggle("Apple Log (imagen plana para etalonar)", isOn: Binding(get: { s.appleLog }, set: { v in model.send(.setAppleLog(v)) }))
                }
                StorageEstimate(state: s)
            }
            .disabled(s.recording)

            Section("Formato") {
                Picker("Resolución", selection: Binding(get: { s.resolution }, set: { r in model.send(.setFormat(r, fps: s.fps)) })) {
                    ForEach(s.supportedResolutions) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Fotogramas", selection: Binding(get: { s.fps }, set: { f in model.send(.setFormat(s.resolution, fps: f)) })) {
                    ForEach(s.supportedFPS, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Orientación", selection: Binding(get: { s.orientation }, set: { o in model.send(.setOrientation(o)) })) {
                    ForEach(Orientation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if s.videoQuality == .standard && !s.appleLog {
                Picker("Códec", selection: Binding(get: { s.codec }, set: { c in model.edit({ $0.codec = c }) { .setCodec($0.codec) } })) {
                    ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                }
                Toggle("Estabilización", isOn: Binding(get: { s.stabilization }, set: { v in model.edit({ $0.stabilization = v }) { .setStabilization($0.stabilization) } }))
            }
            .disabled(s.recording)

            Section("Zoom") {
                LabeledSlider(value: s.zoom, range: s.minZoom...max(s.maxZoom, s.minZoom + 0.01), text: String(format: "%.1f×", s.zoom)) { z in
                    model.edit({ $0.zoom = z }) { .setZoom($0.zoom) }
                }
            }

            Section("Enfoque") {
                Toggle("Automático", isOn: Binding(get: { s.focusAuto }, set: { v in model.edit({ $0.focusAuto = v }) { .setFocus(auto: $0.focusAuto, lens: $0.lensPosition) } }))
                LabeledSlider(value: Double(s.lensPosition), range: 0...1, text: s.lensPosition < 0.02 ? "Cerca" : String(format: "%.2f", s.lensPosition)) { v in
                    model.edit({ $0.lensPosition = Float(v); $0.focusAuto = false }) { .setFocus(auto: false, lens: $0.lensPosition) }
                }
                .disabled(!s.focusSupported)
            }

            Section("Exposición") {
                Toggle("Automática", isOn: Binding(get: { s.exposureAuto }, set: { v in model.edit({ $0.exposureAuto = v }) { .setExposure(auto: $0.exposureAuto, iso: $0.iso, shutter: $0.shutter) } }))
                LabeledSlider(value: Double(s.iso), range: Double(s.minISO)...Double(max(s.maxISO, s.minISO + 1)), text: "ISO \(Int(s.iso))") { v in
                    model.edit({ $0.iso = Float(v); $0.exposureAuto = false }) { .setExposure(auto: false, iso: $0.iso, shutter: $0.shutter) }
                }
                // Obturación en escala logarítmica.
                LabeledSlider(value: log(max(s.shutter, 1e-6)),
                              range: log(s.minShutter)...log(max(s.maxShutter, s.minShutter * 1.01)),
                              text: shutterText(s.shutter)) { v in
                    model.edit({ $0.shutter = exp(v); $0.exposureAuto = false }) { .setExposure(auto: false, iso: $0.iso, shutter: $0.shutter) }
                }
                LabeledSlider(value: Double(s.bias), range: Double(s.minBias)...Double(s.maxBias), text: String(format: "%+.1f EV", s.bias)) { v in
                    model.edit({ $0.bias = Float(v) }) { .setBias($0.bias) }
                }
                .disabled(!s.exposureAuto)
            }

            Section("Balance de blancos") {
                Toggle("Automático", isOn: Binding(get: { s.whiteBalanceAuto }, set: { v in model.edit({ $0.whiteBalanceAuto = v }) { .setWhiteBalance(auto: $0.whiteBalanceAuto, temperature: $0.temperature) } }))
                LabeledSlider(value: Double(s.temperature), range: 2000...10000, text: "\(Int(s.temperature)) K") { v in
                    model.edit({ $0.temperature = Float(v); $0.whiteBalanceAuto = false }) { .setWhiteBalance(auto: false, temperature: $0.temperature) }
                }
            }

            if s.hasTorch {
                Section("Linterna") {
                    LabeledSlider(value: Double(s.torch), range: 0...1, text: s.torch < 0.01 ? "Apagada" : "\(Int(s.torch * 100)) %") { v in
                        model.edit({ $0.torch = Float(v) }) { .setTorch($0.torch) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func shutterText(_ s: Double) -> String {
        s >= 0.5 ? String(format: "%.1f s", s) : "1/\(Int((1 / s).rounded()))"
    }
}

struct LabeledSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let text: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack {
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: onChange), in: range)
            Text(text).font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
        }
    }
}

/// Vúmetro sencillo: -60 dB … 0 dB, verde/amarillo/rojo.
struct AudioMeter: View {
    let db: Float

    var body: some View {
        let level = CGFloat(((db + 60) / 60).clamped(0, 1))
        HStack {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width)
                        .mask(alignment: .leading) { Capsule().frame(width: g.size.width * level) }
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.1), value: level)
            Text(db <= -60 ? "—" : String(format: "%.0f dB", db))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .accessibilityLabel("Nivel de audio")
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}

/// Cuánto ocupa por minuto y cuántos minutos caben en el iPhone.
struct StorageEstimate: View {
    let state: CameraState

    var body: some View {
        let mbPerMin = state.megabytesPerMinute
        let minutes = mbPerMin > 0 ? Double(state.freeBytes) / 1_000_000 / mbPerMin : 0
        let perMin = mbPerMin >= 1000 ? String(format: "%.1f GB/min", mbPerMin / 1000) : String(format: "%.0f MB/min", mbPerMin)
        let mbps = mbPerMin * 8 / 60
        HStack {
            Label("≈ \(perMin) · \(Int(mbps)) Mbps", systemImage: "internaldrive")
            Spacer()
            Text(minutes >= 120 ? "caben \(Int(minutes / 60)) h" : "caben \(Int(minutes)) min")
                .foregroundStyle(minutes < 15 ? .orange : .secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Solo esta vista se redibuja con cada fotograma de la vista previa.
struct LivePreviewImage: View {
    @ObservedObject var live: LiveFeed
    let previewOn: Bool
    let focusMark: CGPoint?
    let onTap: (CGPoint, CGSize, CGSize) -> Void

    var body: some View {
        if let img = live.preview {
            GeometryReader { g in
                Image(nsImage: img).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .frame(width: g.size.width, height: g.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { loc in onTap(loc, g.size, img.size) }
                    .overlay {
                        if let p = focusMark {
                            RoundedRectangle(cornerRadius: 4).stroke(.yellow, lineWidth: 1.5)
                                .frame(width: 56, height: 56).position(p).allowsHitTesting(false)
                        }
                    }
            }
        } else {
            Text(previewOn ? "Cargando vista previa…" : "Vista previa desactivada")
                .foregroundStyle(.secondary)
        }
    }
}

/// Solo el vúmetro se redibuja con el nivel de audio.
struct LiveMeter: View {
    @ObservedObject var live: LiveFeed
    var body: some View { AudioMeter(db: live.audioLevel) }
}
