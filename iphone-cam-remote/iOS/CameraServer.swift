import Foundation
import Network
import UIKit

/// Anuncia el iPhone por Bonjour y atiende a los Mac que se conectan.
final class CameraServer: ObservableObject {
    @Published private(set) var status = "Arrancando…"
    @Published private(set) var connectedClients: [String] = []
    @Published private(set) var recording = false
    let pin: String

    private let camera: CameraController
    private let library = RecordingLibrary()
    private let queue = DispatchQueue(label: "cam.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var timer: DispatchSourceTimer?
    private var meterTimer: DispatchSourceTimer?

    private final class Client {
        let link: FramedConnection
        var name = "Mac"
        var authenticated = false
        var wantsPreview = true
        var downloading = false
        init(_ link: FramedConnection) { self.link = link }
    }

    init(camera: CameraController) {
        self.camera = camera
        if let saved = UserDefaults.standard.string(forKey: "pin") {
            pin = saved
        } else {
            pin = String(format: "%04d", Int.random(in: 0...9999))
            UserDefaults.standard.set(pin, forKey: "pin")
        }
        camera.onStateChange = { [weak self] in self?.broadcastState() }
        camera.onEvent = { [weak self] msg in self?.broadcast(msg) }
        camera.onPreviewFrame = { [weak self] jpeg in self?.sendPreview(jpeg) }
        camera.library = library
        camera.onSaved = { [weak self] _ in self?.sendRecordings(to: nil) }
    }

    func start() {
        do {
            let listener = try NWListener(using: CamRemote.parameters())
            let name = UIDevice.current.name
            // "sid" cambia en cada arranque: así el Mac distingue una reapertura rápida de la app.
            listener.service = NWListener.Service(name: name, type: CamRemote.serviceType,
                                                  txtRecord: NWTXTRecord(["sid": UUID().uuidString]))
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.setStatus("Esperando al Mac…")
                case .failed(let e): self?.setStatus("Error de red: \(e.localizedDescription)"); self?.restart()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            setStatus("No se pudo abrir el servidor: \(error.localizedDescription)")
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.broadcastState() }
        t.resume()
        timer = t
        // Vúmetro: 10 veces por segundo.
        let m = DispatchSource.makeTimerSource(queue: queue)
        m.schedule(deadline: .now() + 0.1, repeating: 0.1)
        m.setEventHandler { [weak self] in
            guard let self, self.clients.values.contains(where: \.authenticated) else { return }
            self.broadcast(.audioLevel(self.camera.audioLevel))
        }
        m.resume()
        meterTimer = m
    }

    private func restart() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.listener?.cancel()
            self?.timer?.cancel()
            self?.meterTimer?.cancel()
            self?.start()
        }
    }

    // MARK: Conexiones

    private func accept(_ conn: NWConnection) {
        let link = FramedConnection(conn)
        let client = Client(link)
        let id = ObjectIdentifier(client)
        clients[id] = client
        link.onStateChange = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.clients[id] = nil; self?.publishClients() }
            default: break
            }
        }
        link.onMessage = { [weak self] kind, data in
            guard kind == .json, let cmd = try? JSONDecoder().decode(Command.self, from: data) else { return }
            self?.handle(cmd, from: client)
        }
        link.start(queue: queue)
        // Si no se identifica en 10 s, fuera.
        queue.asyncAfter(deadline: .now() + 10) { if !client.authenticated { link.cancel() } }
    }

    private func handle(_ cmd: Command, from client: Client) {
        if case .hello(let pin, let name) = cmd {
            guard pin == self.pin else {
                client.link.sendJSON(ServerMessage.rejected(reason: "PIN incorrecto")) { client.link.cancel() }
                return
            }
            client.authenticated = true
            client.name = name
            client.link.sendJSON(ServerMessage.welcome(deviceName: UIDevice.current.name))
            publishClients()
            camera.currentState { [weak self] s in self?.queue.async { client.link.sendJSON(ServerMessage.state(s)) } }
            sendRecordings(to: client)
            return
        }
        guard client.authenticated else { return }
        switch cmd {
        case .listRecordings: sendRecordings(to: client); return
        case .goodbye(let closeApp):
            client.authenticated = false
            client.link.cancel()
            publishClients()
            // Solo se cierra si era el único Mac conectado.
            guard closeApp, !clients.values.contains(where: { $0 !== client && $0.authenticated }) else { return }
            setStatus("Cerrando (el Mac ha salido de CamRemote)…")
            camera.shutdown {
                // Se cierra del todo, como pidió el Mac. Si estaba grabando, el vídeo ya está guardado.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            return
        case .downloadRecording(let id): download(id, for: client); return
        case .deleteRecording(let id):
            library.delete(id: id) { [weak self] error in
                if let error { self?.broadcast(.error("No se pudo borrar del iPhone: \(error.localizedDescription)")) }
                self?.sendRecordings(to: nil)
            }
            return
        default: break
        }
        if case .setPreview(let on) = cmd {
            client.wantsPreview = on
            return
        }
        camera.handle(cmd)
    }

    // MARK: Envío

    private func broadcast(_ msg: ServerMessage) {
        queue.async { [self] in
            for c in clients.values where c.authenticated { c.link.sendJSON(msg) }
        }
    }

    private func broadcastState() {
        camera.currentState { [weak self] s in
            self?.broadcast(.state(s))
            DispatchQueue.main.async { self?.recording = s.recording }
        }
    }

    private func sendPreview(_ jpeg: Data) {
        queue.async { [self] in
            let targets = clients.values.filter { $0.authenticated && $0.wantsPreview }
            guard !targets.isEmpty else { camera.previewSent(); return }
            let group = DispatchGroup()
            for c in targets {
                group.enter()
                c.link.send(.jpeg, jpeg) { group.leave() }
            }
            group.notify(queue: queue) { self.camera.previewSent() }
        }
    }

    // MARK: Últimos vídeos

    private func sendRecordings(to client: Client?) {
        library.list { [weak self] infos in
            guard let self else { return }
            self.queue.async {
                if let client { client.link.sendJSON(ServerMessage.recordings(infos)) }
                else { for c in self.clients.values where c.authenticated { c.link.sendJSON(ServerMessage.recordings(infos)) } }
            }
        }
    }

    private func download(_ id: String, for client: Client) {
        guard !client.downloading else {
            client.link.sendJSON(ServerMessage.downloadFailed(id: id, reason: "Ya hay una descarga en curso."))
            return
        }
        client.downloading = true
        let link = client.link
        library.stream(id: id, start: { bytes in
            link.sendJSON(ServerMessage.downloadStart(id: id, bytes: bytes))
        }, chunk: { data in
            // Esperar a que el trozo salga por la red antes de leer el siguiente.
            let sem = DispatchSemaphore(value: 0)
            link.send(.fileChunk, data) { sem.signal() }
            _ = sem.wait(timeout: .now() + 30)
        }, done: { [weak self] error in
            self?.queue.async {
                client.downloading = false
                if let error { link.sendJSON(ServerMessage.downloadFailed(id: id, reason: error.localizedDescription)) }
                else { link.sendJSON(ServerMessage.downloadEnd(id: id)) }
            }
        })
    }

    private func publishClients() {
        let names = clients.values.filter(\.authenticated).map(\.name)
        DispatchQueue.main.async {
            self.connectedClients = names
            if names.isEmpty, self.status.hasPrefix("Conectado") || self.status.hasPrefix("Esperando") {
                self.status = "Esperando al Mac…"
            } else if !names.isEmpty {
                self.status = "Conectado a \(names.joined(separator: ", "))"
            }
        }
    }

    private func setStatus(_ s: String) { DispatchQueue.main.async { self.status = s } }

    // Botón local del iPhone
    func toggleRecording() { camera.handle(recording ? .stopRecording : .startRecording) }
}
