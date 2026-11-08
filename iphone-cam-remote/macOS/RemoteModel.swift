import AppKit
import Foundation
import Network

/// Vista previa y nivel de audio: se actualizan 10–15 veces por segundo.
@MainActor
final class LiveFeed: ObservableObject {
    @Published var preview: NSImage?
    @Published var audioLevel: Float = -160
}

struct DiscoveredPhone: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var sid = ""          // id de arranque de la app del iPhone
    var id: String { name }
}

/// Busca iPhones por Bonjour, se conecta y mantiene el estado de la cámara.
@MainActor
final class RemoteModel: ObservableObject {
    enum Link: Equatable { case idle, connecting, connected, failed(String) }

    @Published var phones: [DiscoveredPhone] = []
    @Published var selected: DiscoveredPhone?
    @Published var link: Link = .idle
    @Published var state: CameraState?
    @Published var previewOn = UserDefaults.standard.object(forKey: "previewOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(previewOn, forKey: "previewOn") }
    }
    /// Lo que cambia muchas veces por segundo va aparte, para no redibujar todo el panel.
    let live = LiveFeed()
    @Published var recordings: [RecordingInfo] = []
    /// Sube cada vez que aparece en la red un iPhone con PIN guardado (abre la ventana).
    @Published var phoneArrived = 0
    private var seenLaunches = Set<String>()
    /// Con la ventana cerrada no pedimos vista previa (ahorra batería y Wi-Fi).
    var windowVisible = true {
        didSet { if windowVisible != oldValue { send(.setPreview(windowVisible && previewOn)) } }
    }
    @Published var progress: [String: Double] = [:]   // descargas en curso
    @Published var banner: String?
    @Published var askPinFor: DiscoveredPhone?

    private let queue = DispatchQueue(label: "remote.net")
    private var browser: NWBrowser?
    private var conn: FramedConnection?
    private var lastLocalEdit = Date.distantPast
    private var reconnectWork: DispatchWorkItem?
    private var userDisconnected = false
    nonisolated(unsafe) private let downloader = Downloader()   // solo desde `queue`

    /// Una sola instancia para toda la app (SwiftUI puede reconstruir el App y crear copias).
    static let shared = RemoteModel()

    private init() {
        downloader.onProgress = { [weak self] id, p in Task { @MainActor in self?.progress[id] = p } }
        downloader.onFinished = { [weak self] id, result in
            Task { @MainActor in
                guard let self else { return }
                self.progress[id] = nil
                switch result {
                case .success(let url):
                    if self.editorPending.remove(id) != nil { self.openInEditor([url]) } else { NSWorkspace.shared.open(url) }
                case .failure(let e):
                    self.editorPending.remove(id)
                    self.show("No se pudo descargar: \(e.localizedDescription)")
                }
                self.downloadNextForEditor()
            }
        }
        startBrowsing()
    }

    // MARK: Descubrimiento

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: CamRemote.serviceType, domain: nil), using: CamRemote.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            let list = results.compactMap { r -> DiscoveredPhone? in
                guard case .service(let name, _, _, _) = r.endpoint, seen.insert(name).inserted else { return nil }
                var sid = ""
                if case .bonjour(let txt) = r.metadata { sid = txt["sid"] ?? "" }
                return DiscoveredPhone(name: name, endpoint: r.endpoint, sid: sid)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.phonesChanged(list) }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.restartBrowsing() } }
        }
        b.start(queue: queue)
        browser = b
    }

    private func restartBrowsing() {
        browser?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startBrowsing() }
    }

    private func phonesChanged(_ list: [DiscoveredPhone]) {
        phones = list
        // Solo cuenta como llegada un arranque nuevo de la app del iPhone (no un parpadeo de la red).
        let fresh = list.filter { !$0.sid.isEmpty && !seenLaunches.contains($0.name + $0.sid) }
        seenLaunches.formUnion(list.map { $0.name + $0.sid })
        if fresh.contains(where: { savedPin(for: $0) != nil }) { phoneArrived += 1 }
        // Conexión automática al primer iPhone con PIN guardado.
        if conn == nil, !userDisconnected, let p = list.first(where: { savedPin(for: $0) != nil }) {
            connect(p)
        }
    }

    // MARK: Conexión

    private func savedPin(for p: DiscoveredPhone) -> String? { UserDefaults.standard.string(forKey: "pin.\(p.name)") }

    func choose(_ p: DiscoveredPhone) {
        if savedPin(for: p) == nil { askPinFor = p } else { connect(p) }
    }

    func submitPin(_ pin: String, for p: DiscoveredPhone) {
        UserDefaults.standard.set(pin, forKey: "pin.\(p.name)")
        askPinFor = nil
        connect(p)
    }

    func connect(_ p: DiscoveredPhone) {
        guard let pin = savedPin(for: p) else { askPinFor = p; return }
        disconnect(byUser: false)
        userDisconnected = false
        selected = p
        link = .connecting
        let c = FramedConnection(NWConnection(to: p.endpoint, using: CamRemote.parameters()))
        conn = c
        c.onStateChange = { [weak self, weak c] st in
            Task { @MainActor in
                guard let self, let c, self.conn === c else { return }
                switch st {
                case .ready:
                    c.sendJSON(Command.hello(pin: pin, client: Host.current().localizedName ?? "Mac"))
                    c.sendJSON(Command.setPreview(self.previewOn && self.windowVisible))
                case .failed(let e): self.lost("Conexión perdida: \(e.localizedDescription)")
                case .cancelled: self.lost(nil)
                default: break
                }
            }
        }
        let downloader = self.downloader
        c.onMessage = { [weak self] kind, data in
            switch kind {
            case .jpeg:
                let img = NSImage(data: data)
                Task { @MainActor in self?.live.preview = img }
            case .fileChunk:
                downloader.chunk(data)
            case .json:
                guard let msg = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return }
                if downloader.handle(msg) { return }   // en orden con los trozos
                Task { @MainActor in self?.receive(msg) }
            }
        }
        c.start(queue: queue)
    }

    func disconnect(byUser: Bool = true) {
        userDisconnected = byUser
        reconnectWork?.cancel()
        let c = conn
        conn = nil
        c?.cancel()
        state = nil
        live.preview = nil
        recordings = []
        link = .idle
        queue.async { self.downloader.abort() }
    }

    private func lost(_ reason: String?) {
        guard conn != nil else { return }
        conn = nil
        state = nil
        live.preview = nil
        queue.async { self.downloader.abort() }
        link = .failed(reason ?? "Desconectado")
        // Reintento automático.
        guard let p = selected, !userDisconnected else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.conn == nil, !self.userDisconnected else { return }
                if let fresh = self.phones.first(where: { $0.name == p.name }) { self.connect(fresh) }
            }
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func receive(_ msg: ServerMessage) {
        switch msg {
        case .welcome:
            link = .connected
        case .rejected(let reason):
            if let p = selected { UserDefaults.standard.removeObject(forKey: "pin.\(p.name)"); askPinFor = p }
            userDisconnected = true
            let c = conn
            conn = nil
            c?.cancel()
            link = .failed(reason)
        case .state(var s):
            // Mientras se arrastra un control, conservar el valor local para que no "salte".
            if let local = state, Date().timeIntervalSince(lastLocalEdit) < 0.6 {
                s.zoom = local.zoom; s.lensPosition = local.lensPosition; s.iso = local.iso
                s.shutter = local.shutter; s.bias = local.bias; s.temperature = local.temperature; s.torch = local.torch
            }
            if state != s { state = s }   // no redibujar si nada cambió
        case .error(let e):
            show(e)
        case .audioLevel(let db):
            if abs(live.audioLevel - db) > 0.5 { live.audioLevel = db }
        case .recordings(let list):
            recordings = list
        case .downloadStart, .downloadEnd, .downloadFailed:
            break
        case .recordingSaved(let secs):
            show("Vídeo guardado en el iPhone (\(Self.clock(secs)))")
        }
    }

    private func show(_ text: String) {
        banner = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.banner == text { self?.banner = nil }
        }
    }

    // MARK: Comandos

    func send(_ cmd: Command) { conn?.sendJSON(cmd) }

    /// Al salir de la app: avisa al iPhone (y le pide cerrarse si está activada la opción).
    func sayGoodbye(completion: @escaping @Sendable () -> Void) {
        guard let c = conn, link == .connected else { completion(); return }
        let closeApp = UserDefaults.standard.object(forKey: "closePhoneOnQuit") as? Bool ?? true
        userDisconnected = true
        c.sendJSON(Command.goodbye(closeApp: closeApp)) { Task { @MainActor in completion() } }
    }

    /// Cambia el estado local al instante y envía el comando.
    func edit(_ change: (inout CameraState) -> Void, _ cmd: (CameraState) -> Command) {
        guard var s = state else { return }
        change(&s)
        state = s
        lastLocalEdit = Date()
        send(cmd(s))
    }

    // MARK: Últimos vídeos

    func isDownloaded(_ r: RecordingInfo) -> Bool {
        let url = Downloader.target(for: r)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return false }
        return r.bytes == 0 || size == r.bytes
    }

    /// Abre el vídeo en el Mac; si no está, lo descarga primero.
    func open(_ r: RecordingInfo, redownload: Bool = false) {
        if !redownload, isDownloaded(r) { NSWorkspace.shared.open(Downloader.target(for: r)); return }
        guard progress.isEmpty else { show("Espera a que termine la descarga en curso."); return }
        startDownload(r)
    }

    private func startDownload(_ r: RecordingInfo) {
        let target = Downloader.target(for: r)
        progress[r.id] = 0
        queue.async {
            self.downloader.targets[r.id] = target
            Task { @MainActor in self.send(.downloadRecording(id: r.id)) }
        }
    }

    // MARK: Enviar a CamRemote Color (editor de color)

    static let editorBundleID = "com.adrianmillares.camremote.editor"
    /// Vídeos que se envían al editor en cuanto terminen de descargarse.
    private var editorQueue: [RecordingInfo] = []
    private var editorPending = Set<String>()

    var editorAppURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.editorBundleID) }

    /// Envía los vídeos a CamRemote Color; los que no estén en el Mac se descargan antes, uno detrás de otro.
    func sendToEditor(_ rs: [RecordingInfo]) {
        guard editorAppURL != nil else {
            show("No encuentro CamRemote Color. Instálala en Aplicaciones (o ábrela una vez) y vuelve a intentarlo.")
            return
        }
        let ready = rs.filter(isDownloaded)
        if !ready.isEmpty { openInEditor(ready.map(Downloader.target(for:))) }
        for r in rs where !isDownloaded(r) && !editorPending.contains(r.id) {
            editorPending.insert(r.id)
            editorQueue.append(r)
        }
        downloadNextForEditor()
    }

    private func downloadNextForEditor() {
        guard progress.isEmpty, !editorQueue.isEmpty else { return }
        startDownload(editorQueue.removeFirst())
    }

    private func openInEditor(_ urls: [URL]) {
        guard let app = editorAppURL, !urls.isEmpty else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.show("No se pudo abrir en CamRemote Color: \(error.localizedDescription)") }
        }
    }

    enum DeleteScope { case mac, iphone, both }

    func delete(_ r: RecordingInfo, from scope: DeleteScope) {
        if scope != .iphone, isDownloadedAny(r) {
            do { try FileManager.default.trashItem(at: Downloader.target(for: r), resultingItemURL: nil) }
            catch { show("No se pudo mover a la Papelera: \(error.localizedDescription)") }
        }
        if scope != .mac {
            send(.deleteRecording(id: r.id))
        }
        objectWillChange.send()
    }

    func delete(_ rs: [RecordingInfo], from scope: DeleteScope) {
        rs.forEach { delete($0, from: scope) }
    }

    func isDownloadedAny(_ r: RecordingInfo) -> Bool { FileManager.default.fileExists(atPath: Downloader.target(for: r).path) }

    func revealInFinder(_ r: RecordingInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([Downloader.target(for: r)])
    }

    func toggleRecording() {
        guard let s = state else { return }
        send(s.recording ? .stopRecording : .startRecording)
        state?.recording.toggle()
        if state?.recording == true { state?.recordingSeconds = 0 }
    }

    func setPreview(_ on: Bool) {
        previewOn = on
        if !on { live.preview = nil }
        send(.setPreview(on))
    }

    static func clock(_ secs: Double) -> String {
        let t = Int(secs)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }
}
