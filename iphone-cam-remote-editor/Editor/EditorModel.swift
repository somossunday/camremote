import AVFoundation
import AppKit
import Combine
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    static let shared = EditorModel()
    // Clip
    @Published private(set) var clip: ClipInfo?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // Color
    @Published var settings = ColorSettings() { didSet { if settings != oldValue { settingsChanged(lutChanged: settings.lut != oldValue.lut) } } }
    @Published var output: OutputSpace = .rec709 { didSet { if output != oldValue { pushState() } } }
    @Published var inputOverride: InputInterpretation = .auto { didSet { if inputOverride != oldValue { pushState(); scheduleThumbnails() } } }
    @Published var highlightRolloff = true { didSet { pushState() } }
    @Published var compare: CompareMode = .off { didSet { pushState() } }
    @Published var split: Double = 0.5 { didSet { pushState() } }
    @Published var selectedPresetID: String?

    // Transporte
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var trimIn: Double = 0
    @Published var trimOut: Double = 0

    // Bibliotecas
    @Published private(set) var library: [URL] = []
    /// Vídeos recibidos (desde CamRemote, Finder o «Abrir con»), en orden de llegada.
    @Published private(set) var inbox: [URL] = []
    private var lastReceive = Date.distantPast
    @Published private(set) var userPresets: [Preset] = []
    @Published private(set) var luts: [String] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    // Exportación
    @Published var exportProgress: Double?
    @Published var lastExportURL: URL?

    let player = AVPlayer()
    let renderer = GradeRenderer()
    private(set) var asset: AVURLAsset?
    private var cube: Data?
    private var cubeTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var thumbSource: CIImage?
    private var presetCubes: [String: Data?] = [:]
    private var timeObserver: Any?
    private var refreshPending = false
    private var exporter: Exporter?
    private var frameTask: Task<Void, Never>?

    var allPresets: [Preset] { BuiltInPresets.all + userPresets }
    var effectiveInput: InputInterpretation { inputOverride == .auto ? (clip?.detected ?? .rec709) : inputOverride }

    private init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        refreshLibrary()
        userPresets = UserPresetStore.loadAll()
        luts = LUTLibrary.names()
    }

    // MARK: Abrir

    func refreshLibrary() {
        let dir = AppPaths.camRemoteMovies
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        library = files.filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.directoryURL = FileManager.default.fileExists(atPath: AppPaths.camRemoteMovies.path) ? AppPaths.camRemoteMovies : nil
        panel.prompt = "Abrir"
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        if panel.urls.count == 1, let url = panel.urls.first { open(url) } else { panel.urls.forEach(receive) }
    }

    /// Recibe un vídeo enviado a la app. El primero de cada tanda se abre; el resto queda en «Enviados».
    func receive(_ url: URL) {
        let url = url.standardizedFileURL
        guard ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "«\(url.lastPathComponent)» no es un vídeo compatible."
            return
        }
        inbox.removeAll { $0 == url }
        inbox.append(url)
        refreshLibrary()
        let newBatch = Date().timeIntervalSince(lastReceive) > 2
        lastReceive = Date()
        if exportProgress == nil && (newBatch || clip == nil) { open(url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func clearInbox() { inbox.removeAll() }

    func openNextInInbox() {
        guard let cur = clip?.url, let i = inbox.firstIndex(of: cur), i + 1 < inbox.count else { return }
        open(inbox[i + 1])
    }

    func open(_ url: URL) {
        player.pause()
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let (asset, info) = try await ClipInfo.load(url: url)
                self.asset = asset
                self.clip = info
                self.inputOverride = .auto
                self.output = info.isHDR ? .hlg2020 : (info.detected == .p3 ? .p3d65 : .rec709)
                self.duration = info.duration
                self.trimIn = 0
                self.trimOut = info.duration
                self.currentTime = 0
                self.compare = .off
                pushState()
                let item = AVPlayerItem(asset: asset)
                item.videoComposition = try await CompositionBuilder.make(asset: asset, renderer: renderer, output: output)
                player.replaceCurrentItem(with: item)
                await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                grabFrame()
            } catch {
                errorMessage = "No se pudo abrir «\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Estado de color

    private func settingsChanged(lutChanged: Bool) {
        let s = settings
        cubeTask?.cancel()
        if !s.needsCube {
            cube = nil
            pushState()
            return
        }
        cubeTask = Task.detached(priority: .userInitiated) { [self] in
            let data = ColorMath.bakeCube(s)
            if Task.isCancelled { return }
            await MainActor.run {
                guard self.settings == s else { return }
                self.cube = data
                self.pushState()
            }
        }
    }

    func currentState() -> RenderState {
        var st = RenderState()
        st.settings = settings
        st.input = effectiveInput
        st.output = output
        st.compare = compare
        st.split = split
        st.highlightRolloff = highlightRolloff
        st.cube = settings.needsCube ? cube : nil
        if let ref = settings.lut { st.lut = LUTLibrary.load(ref.name) }
        return st
    }

    private func pushState() {
        let old = renderer.state
        let st = currentState()
        renderer.state = st
        if old.output != st.output, let item = player.currentItem, let asset {
            Task {
                if let comp = try? await CompositionBuilder.make(asset: asset, renderer: renderer, output: output) {
                    item.videoComposition = comp
                }
            }
        } else {
            refreshFrame()
        }
    }

    /// Con el vídeo en pausa, fuerza a recomponer el fotograma actual.
    private func refreshFrame() {
        guard !isPlaying, !refreshPending, let item = player.currentItem else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            if let comp = item.videoComposition?.mutableCopy() as? AVMutableVideoComposition {
                item.videoComposition = comp
            }
        }
    }

    func resetAll() {
        settings = ColorSettings()
        selectedPresetID = nil
    }

    // MARK: Transporte

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if isPlaying, t >= trimOut - 0.001 {
            player.pause()
            isPlaying = false
            grabFrame()
        }
        if isPlaying != (player.rate != 0) { isPlaying = player.rate != 0 }
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause(); isPlaying = false; grabFrame()
        } else {
            if currentTime >= trimOut - 0.05 || currentTime < trimIn {
                player.seek(to: CMTime(seconds: trimIn, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play(); isPlaying = true
        }
    }

    func seek(to t: Double) {
        let c = min(max(0, t), duration)
        currentTime = c
        player.seek(to: CMTime(seconds: c, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        grabFrame()
    }

    func step(_ frames: Int) {
        guard let clip else { return }
        if isPlaying { player.pause(); isPlaying = false }
        seek(to: currentTime + Double(frames) / max(1, clip.fps))
    }

    func markIn() { trimIn = min(currentTime, trimOut - 0.1) }
    func markOut() { trimOut = max(currentTime, trimIn + 0.1) }
    func resetTrim() { trimIn = 0; trimOut = duration }

    // MARK: Miniaturas

    /// Lee el fotograma original actual (sin procesar) para las miniaturas de los presets.
    private func grabFrame() {
        frameTask?.cancel()
        guard let asset else { return }
        let t = currentTime
        let input = effectiveInput
        frameTask = Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard let img = await FrameGrabber.frame(asset: asset, at: t, input: input, maxWidth: 260) else { return }
            await MainActor.run {
                self.thumbSource = img
                self.scheduleThumbnails()
            }
        }
    }

    private func scheduleThumbnails() {
        thumbTask?.cancel()
        guard let src = thumbSource else { return }
        var base = currentState()
        base.compare = .off
        base.lut = nil
        let presets = allPresets
        var cubes = presetCubes
        thumbTask = Task.detached(priority: .utility) { [self] in
            var result: [String: NSImage] = [:]
            for p in presets {
                if Task.isCancelled { return }
                if cubes[p.id] == nil { cubes[p.id] = .some(ColorMath.bakeCube(p.settings)) }
                var st = base
                var s = p.settings
                s.lut = nil
                st.settings = s
                st.cube = cubes[p.id] ?? nil
                if let cg = Pipeline.thumbnail(src, st) {
                    result[p.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            let images = result
            let baked = cubes
            await MainActor.run {
                self.presetCubes = baked
                self.thumbnails = images
            }
        }
    }

    // MARK: Presets

    func apply(_ p: Preset) {
        var s = p.settings
        s.lut = settings.lut   // el LUT elegido se conserva
        settings = s
        if let o = p.output { output = o }
        selectedPresetID = p.id
    }

    func saveUserPreset(name: String) {
        var s = settings
        s.lut = settings.lut
        let p = Preset(id: UUID().uuidString, name: name.isEmpty ? "Mi preset" : name, category: "Mis presets",
                       settings: s, output: nil, builtIn: false)
        do {
            try UserPresetStore.save(p)
            userPresets = UserPresetStore.loadAll()
            selectedPresetID = p.id
            scheduleThumbnails()
        } catch { errorMessage = "No se pudo guardar el preset: \(error.localizedDescription)" }
    }

    func deleteUserPreset(_ p: Preset) {
        UserPresetStore.delete(p)
        userPresets = UserPresetStore.loadAll()
        presetCubes[p.id] = nil
    }

    func importPresets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                var p = try JSONDecoder().decode(Preset.self, from: Data(contentsOf: url))
                p.id = UUID().uuidString
                try UserPresetStore.save(p)
            } catch { errorMessage = "«\(url.lastPathComponent)» no es un preset válido." }
        }
        userPresets = UserPresetStore.loadAll()
        scheduleThumbnails()
    }

    func exportPreset(_ p: Preset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = p.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var copy = p
        copy.category = "Mis presets"
        do { try UserPresetStore.encoder.encode(copy).write(to: url) }
        catch { errorMessage = "No se pudo exportar: \(error.localizedDescription)" }
    }

    func exportCurrentAsPreset() {
        exportPreset(Preset(id: UUID().uuidString, name: "Ajustes", category: "Mis presets", settings: settings, builtIn: false))
    }

    // MARK: LUTs

    func importLUTs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Elige uno o varios LUT .cube (1D o 3D)"
        guard panel.runModal() == .OK else { return }
        var last: String?
        for url in panel.urls {
            do { last = try LUTLibrary.importLUT(from: url) }
            catch { errorMessage = error.localizedDescription }
        }
        luts = LUTLibrary.names()
        if let last { selectLUT(last) }
    }

    func selectLUT(_ name: String?) {
        guard let name else { settings.lut = nil; return }
        var ref = settings.lut ?? LUTRef(name: name)
        ref.name = name
        // Espacio de entrada/salida deducido del nombre (se puede cambiar a mano después).
        let lower = name.lowercased()
        if lower.contains("apple log") || lower.contains("applelog") || lower.contains(" log ") || lower.hasSuffix(" log") {
            ref.input = .appleLog
            ref.output = lower.contains("hlg") ? .hlg : .rec709
        } else if lower.contains("hlg") {
            ref.input = .hlg; ref.output = .hlg
        } else {
            ref.input = .rec709; ref.output = .rec709
        }
        settings.lut = ref
    }

    func deleteLUT(_ name: String) {
        if settings.lut?.name == name { settings.lut = nil }
        LUTLibrary.remove(name)
        luts = LUTLibrary.names()
    }

    // MARK: Exportar

    func defaultExportURL(format: ExportFormat) -> URL {
        let base = clip?.url.deletingPathExtension().lastPathComponent ?? "Clip"
        let dir = AppPaths.camRemoteMovies.appendingPathComponent("Editados", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = format == .hevc10 ? "HEVC" : (format == .prores4444 ? "4444" : "ProRes")
        return dir.appendingPathComponent("\(base) · color \(suffix).mov")
    }

    func startExport(format: ExportFormat, output exportOutput: OutputSpace, useTrim: Bool, url: URL) {
        guard let asset else { return }
        let exporter = Exporter()
        self.exporter = exporter
        exportProgress = 0
        lastExportURL = nil
        var st = currentState()
        st.output = exportOutput
        st.compare = .off
        let range = useTrim
            ? CMTimeRange(start: CMTime(seconds: trimIn, preferredTimescale: 600),
                          end: CMTime(seconds: trimOut, preferredTimescale: 600))
            : CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        player.pause(); isPlaying = false
        Task {
            do {
                try await exporter.export(asset: asset, state: st, format: format, range: range, to: url) { p in
                    Task { @MainActor [weak self] in
                        if self?.exportProgress != nil { self?.exportProgress = p }
                    }
                }
                exportProgress = nil
                lastExportURL = url
            } catch is CancellationError {
                exportProgress = nil
            } catch {
                exportProgress = nil
                errorMessage = "La exportación falló: \(error.localizedDescription)"
            }
            self.exporter = nil
        }
    }

    func cancelExport() {
        exporter?.cancel()
        exportProgress = nil
    }
}

enum FrameGrabber {
    /// Fotograma original en lineal BT.2020, reducido a maxWidth.
    static func frame(asset: AVAsset, at t: Double, input: InputInterpretation, maxWidth: CGFloat) async -> CIImage? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform),
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, t), preferredTimescale: 600), duration: .positiveInfinity)
        guard reader.startReading(), let sample = out.copyNextSampleBuffer(),
              let buf = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let img = Pipeline.orient(Pipeline.inputImage(buf, input: input), transform: transform)
        let scale = min(1, maxWidth / img.extent.width)
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Materializa para no retener el lector.
        let rect = small.extent.integral
        guard let cg = Pipeline.context.createCGImage(small, from: rect, format: .RGBAh, colorSpace: Pipeline.workingSpace) else { return nil }
        reader.cancelReading()
        return CIImage(cgImage: cg, options: [.colorSpace: Pipeline.workingSpace])
    }
}
