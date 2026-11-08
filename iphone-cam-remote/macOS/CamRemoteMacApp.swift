import ServiceManagement
import SwiftUI

enum Helper {
    static let service = SMAppService.loginItem(identifier: "com.adrianmillares.camremote.mac.helper")
}

/// Retrasa la salida un instante para avisar al iPhone.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI permite el «cierre súbito», que se salta applicationShouldTerminate.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Avisar al iPhone al salir")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = RemoteModel.shared
        var replied = false
        let reply = { if !replied { replied = true; sender.reply(toApplicationShouldTerminate: true) } }
        model.sayGoodbye(completion: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reply)   // por si la red no responde
        return .terminateLater
    }
}

@main
struct CamRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RemoteModel.shared

    /// Si macOS nos abrió al iniciar sesión, arrancamos sin ventana (solo en la barra de menús).
    private static let launchedAtLogin: Bool = {
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return e.eventID == kAEOpenApplication &&
            e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }()

    init() {
        // Primera vez: activar el ayudante que abre CamRemote al detectar el iPhone
        // (aunque la app esté cerrada). Sustituye al antiguo arranque de la app entera.
        if !UserDefaults.standard.bool(forKey: "helperConfigured") {
            try? SMAppService.mainApp.unregister()
            try? Helper.service.register()
            UserDefaults.standard.set(true, forKey: "helperConfigured")
        }
        if Self.launchedAtLogin { NSApplication.shared.setActivationPolicy(.accessory) }
    }

    var body: some Scene {
        Window("CamRemote", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    model.windowVisible = true
                }
                .onDisappear {
                    model.windowVisible = false
                    NSApp.setActivationPolicy(.accessory)   // sigue viva en la barra de menús
                }
        }
        .defaultLaunchBehavior(Self.launchedAtLogin ? .suppressed : .presented)
        .windowToolbarStyle(.unified)
        .commands {
            CommandMenu("Cámara") {
                Button(model.state?.recording == true ? "Parar grabación" : "Grabar") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.state == nil)
                Button("Desconectar") { model.disconnect() }
                    .disabled(model.link == .idle)
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
    }
}

/// Icono de la barra de menús. Siempre está vivo, así que desde aquí abrimos la
/// ventana cuando aparece un iPhone conocido.
struct MenuBarLabel: View {
    @EnvironmentObject var model: RemoteModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoOpen") private var autoOpen = true

    var body: some View {
        Image(systemName: model.state?.recording == true ? "record.circle.fill" : (model.link == .connected ? "video.fill" : "video"))
            .onChange(of: model.phoneArrived) {
                guard autoOpen else { return }
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: RemoteModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("autoOpen") private var autoOpen = true
    @State private var helperOn = Helper.service.status == .enabled
    @AppStorage("closePhoneOnQuit") private var closePhoneOnQuit = true

    var body: some View {
        Text(model.link == .connected ? "Conectado a \(model.selected?.name ?? "iPhone")" : (model.phones.isEmpty ? "Buscando iPhone…" : "iPhone disponible"))
        if let s = model.state, s.recording {
            Button("Parar grabación (\(RemoteModel.clock(s.recordingSeconds)))") { model.toggleRecording() }
        } else if model.state != nil {
            Button("Grabar") { model.toggleRecording() }
        }
        Divider()
        Button("Abrir CamRemote") { openWindow(id: "main"); NSApp.activate() }
        Toggle("Abrir la ventana al detectar el iPhone", isOn: $autoOpen)
        Toggle("Cerrar la app del iPhone al salir de CamRemote", isOn: $closePhoneOnQuit)
        Toggle("Detectar el iPhone aunque CamRemote esté cerrado", isOn: Binding(get: { helperOn }, set: { on in
            if on { try? Helper.service.register() } else { try? Helper.service.unregister() }
            helperOn = Helper.service.status == .enabled
        }))
        Divider()
        Button("Salir de CamRemote") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct ContentView: View {
    @EnvironmentObject var model: RemoteModel

    var body: some View {
        NavigationSplitView {
            PhoneList()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            if model.state != nil {
                HStack(spacing: 0) {
                    PreviewPane()
                    Divider()
                    ControlsPanel().frame(width: 320)
                }
            } else {
                EmptyStateView()
            }
        }
        .sheet(item: $model.askPinFor) { phone in PinSheet(phone: phone) }
        .overlay(alignment: .bottom) {
            if let b = model.banner {
                Text(b)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: model.banner)
    }
}

// MARK: - Lista de iPhones

struct PhoneList: View {
    @EnvironmentObject var model: RemoteModel
    /// Vídeos seleccionados (clic, ⌘+clic, ⇧+clic).
    @State private var selection = Set<String>()
    @State private var pendingDelete: [RecordingInfo] = []

    private func recordings(_ ids: Set<String>) -> [RecordingInfo] { model.recordings.filter { ids.contains($0.id) } }

    var body: some View {
        List(selection: $selection) {
            Section("iPhones cerca") {
                if model.phones.isEmpty {
                    Label("Buscando…", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.phones) { phone in
                    Button { model.choose(phone) } label: {
                        HStack {
                            Label(phone.name, systemImage: "iphone")
                            Spacer()
                            if model.selected?.name == phone.name { statusDot }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Olvidar PIN") { UserDefaults.standard.removeObject(forKey: "pin.\(phone.name)") }
                    }
                }
            }
            if model.link == .connected {
                Section("Últimos vídeos") {
                    if model.recordings.isEmpty {
                        Text("Aún no hay vídeos grabados con CamRemote").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(model.recordings) { r in
                        RecordingRow(recording: r) { pendingDelete = [r] }.tag(r.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Menú contextual sobre la selección; doble clic o ↩ abre.
        .contextMenu(forSelectionType: String.self) { ids in
            let rs = recordings(ids)
            if !rs.isEmpty {
                Button(rs.count == 1 ? "Abrir" : "Abrir \(rs.count) vídeos") { rs.forEach { model.open($0) } }
                    .disabled(rs.count > 1 && rs.contains { !model.isDownloaded($0) })
                Button(rs.count == 1 ? "Editar color en CamRemote Color" : "Enviar \(rs.count) vídeos a CamRemote Color") {
                    model.sendToEditor(rs)
                }
                .help("Abre los vídeos en el editor de color; los que no estén en el Mac se descargan antes")
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting(rs.filter(model.isDownloadedAny).map(Downloader.target(for:))) }
                    .disabled(!rs.contains(where: model.isDownloadedAny))
                if rs.count == 1 { Button("Descargar de nuevo") { model.open(rs[0], redownload: true) } }
                Divider()
                Button(rs.count == 1 ? "Borrar…" : "Borrar \(rs.count) vídeos…", role: .destructive) { pendingDelete = rs }
            }
        } primaryAction: { ids in
            if let r = recordings(ids).first { model.open(r) }
        }
        .onDeleteCommand { pendingDelete = recordings(selection) }   // tecla ⌫
        .confirmationDialog(pendingDelete.count == 1 ? "¿Borrar este vídeo?" : "¿Borrar \(pendingDelete.count) vídeos?",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            let rs = pendingDelete
            Button("Borrar del Mac y del iPhone", role: .destructive) { model.delete(rs, from: .both); selection.subtract(rs.map(\.id)) }
            Button("Borrar solo del iPhone", role: .destructive) { model.delete(rs, from: .iphone); selection.subtract(rs.map(\.id)) }
            if rs.contains(where: model.isDownloadedAny) {
                Button("Borrar solo del Mac") { model.delete(rs, from: .mac) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("En el Mac va a la Papelera. En el iPhone se borra al momento y no se puede recuperar.")
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch model.link {
        case .connected: Circle().fill(.green).frame(width: 8, height: 8)
        case .connecting: ProgressView().controlSize(.small)
        case .failed: Circle().fill(.orange).frame(width: 8, height: 8)
        case .idle: EmptyView()
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: RemoteModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right").font(.system(size: 48)).foregroundStyle(.secondary)
            switch model.link {
            case .connecting: Text("Conectando con \(model.selected?.name ?? "el iPhone")…").font(.title3)
            case .failed(let r): Text(r).font(.title3)
            default: Text("Abre CamRemote en el iPhone y elígelo en la lista").font(.title3)
            }
            Text("Mac e iPhone en la misma Wi-Fi, o con Wi-Fi y Bluetooth activados para conexión directa.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

struct PinSheet: View {
    @EnvironmentObject var model: RemoteModel
    let phone: DiscoveredPhone
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Conectar con \(phone.name)").font(.headline)
            Text("Escribe el PIN de 4 cifras que aparece en la pantalla del iPhone.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            TextField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 140)
                .onSubmit(submit)
            HStack {
                Button("Cancelar", role: .cancel) { model.askPinFor = nil }
                Button("Conectar", action: submit).keyboardShortcut(.defaultAction).disabled(pin.count != 4)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func submit() {
        guard pin.count == 4 else { return }
        model.submitPin(pin, for: phone)
    }
}

struct RecordingRow: View {
    @EnvironmentObject var model: RemoteModel
    let recording: RecordingInfo
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let r = recording
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let d = r.thumbnail, let img = NSImage(data: d) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.black.overlay(Image(systemName: "film").foregroundStyle(.secondary))
                        }
                    }
                    .frame(width: 64, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(RemoteModel.clock(r.duration))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 3).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white).padding(2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.date.formatted(Date.RelativeFormatStyle(presentation: .named).locale(Locale(identifier: "es_ES")))).lineLimit(1)
                    if let p = model.progress[r.id] {
                        ProgressView(value: p).controlSize(.small)
                    } else {
                        Text("\(r.height >= 2160 || r.width >= 2160 ? "4K" : "\(min(r.width, r.height))p") · \(ByteCountFormatter.string(fromByteCount: r.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if hovering && model.progress[r.id] == nil {
                    Button(action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Borrar…")
                } else if model.isDownloaded(r) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Ya está en tu Mac")
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help("Doble clic para abrir · ⌘+clic para seleccionar varios · ⌫ para borrar")
    }
}
