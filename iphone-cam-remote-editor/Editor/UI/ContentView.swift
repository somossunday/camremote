import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: EditorModel
    @State private var showExport = false
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ViewerColumn()
                .inspector(isPresented: $showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
                }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.showOpenPanel() } label: { Label("Abrir", systemImage: "folder") }
                    .help("Abrir un vídeo (⌘O)")
            }
            ToolbarItemGroup(placement: .principal) {
                Picker("Comparar", selection: $model.compare) {
                    ForEach(CompareMode.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                .help("Comparación antes/después")
                .disabled(model.clip == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showExport = true } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                    .disabled(model.clip == nil)
                    .help("Exportar (⌘E)")
                Button { showInspector.toggle() } label: { Label("Ajustes", systemImage: "sidebar.right") }
            }
        }
        .navigationTitle(model.clip?.url.lastPathComponent ?? "CamRemote Color")
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.receive(url) } }
            } }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 4).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showExport) { ExportSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in
            if model.clip != nil { showExport = true }
        }
        .alert("Aviso", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct LibrarySidebar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        List(selection: Binding(get: { model.clip?.url }, set: { if let u = $0, u != model.clip?.url { model.open(u) } })) {
            if !model.inbox.isEmpty {
                Section {
                    ForEach(model.inbox, id: \.self) { url in
                        LibraryRow(url: url).tag(url)
                    }
                } header: {
                    HStack {
                        Text("Enviados (\(model.inbox.count))")
                        Spacer()
                        Button { model.clearInbox() } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Vaciar la lista de enviados")
                    }
                }
            }
            Section {
                if model.library.isEmpty {
                    Text("No hay vídeos en ~/Movies/CamRemote todavía.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.library.filter { !model.inbox.contains($0.standardizedFileURL) }, id: \.self) { url in
                    LibraryRow(url: url).tag(url)
                }
            } header: {
                HStack {
                    Text("CamRemote")
                    Spacer()
                    Button { model.refreshLibrary() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Actualizar")
                    Button { NSWorkspace.shared.open(AppPaths.camRemoteMovies) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Mostrar en Finder")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { model.showOpenPanel() } label: { Label("Abrir otro vídeo…", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLibrary()
        }
    }
}

struct LibraryRow: View {
    let url: URL
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Color.black
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
            }
            .frame(width: 54, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "CamRemote ", with: ""))
                    .lineLimit(1)
                Text(sizeLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 160, height: 160)
            if let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                thumb = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    private var sizeLabel: String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct ViewerColumn: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if let clip = model.clip {
                ClipInfoBar(clip: clip)
                Divider()
            }
            ZStack {
                Color.black
                if model.clip != nil {
                    PlayerView(player: model.player)
                    if model.compare == .split { SplitHandle() }
                } else {
                    EmptyState()
                }
                if model.isLoading { ProgressView().controlSize(.large) }
            }
            if model.clip != nil {
                Divider()
                TransportBar()
            }
        }
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: EditorModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Arrastra aquí un vídeo de CamRemote").font(.title3)
            Text("ProRes 422 HQ, HEVC 10 bits HLG, Apple Log / Log 2, HEVC/H.264 8 bits")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Abrir…") { model.showOpenPanel() }
                if let first = model.library.first {
                    Button("Abrir el último de CamRemote") { model.open(first) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

struct ClipInfoBar: View {
    let clip: ClipInfo
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Tag(icon: "film", text: clip.formatLabel)
            Tag(icon: "aspectratio", text: clip.resolutionLabel)
            Tag(icon: "camera.filters", text: clip.colorLabel, highlight: clip.isHDR)
            if !clip.audio.isEmpty { Tag(icon: "waveform", text: clip.audio.joined(separator: " + ")) }
            Spacer()
            Picker("Salida", selection: $model.output) {
                ForEach(OutputSpace.allCases) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .frame(width: 190)
            .help("Espacio de color de la vista previa y de la exportación")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .font(.callout)
    }
}

struct Tag: View {
    let icon: String
    let text: String
    var highlight = false
    var body: some View {
        Label(text, systemImage: icon)
            .lineLimit(1)
            .foregroundStyle(highlight ? Color.orange : Color.secondary)
    }
}

/// Línea de división arrastrable para la comparación antes/después.
struct SplitHandle: View {
    @EnvironmentObject var model: EditorModel
    var body: some View {
        GeometryReader { geo in
            let videoRect = fittedRect(in: geo.size)
            let x = videoRect.minX + videoRect.width * model.split
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        model.split = min(1, max(0, (g.location.x - videoRect.minX) / max(1, videoRect.width)))
                    })
                Text("Antes").font(.caption.bold()).padding(4).background(.black.opacity(0.5)).foregroundStyle(.white)
                    .position(x: max(videoRect.minX + 30, x - 36), y: videoRect.minY + 16)
                Text("Después").font(.caption.bold()).padding(4).background(.black.opacity(0.5)).foregroundStyle(.white)
                    .position(x: min(videoRect.maxX - 36, x + 42), y: videoRect.minY + 16)
            }
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        guard let c = model.clip, c.width > 0, c.height > 0 else { return CGRect(origin: .zero, size: size) }
        let s = min(size.width / CGFloat(c.width), size.height / CGFloat(c.height))
        let w = CGFloat(c.width) * s, h = CGFloat(c.height) * s
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}
