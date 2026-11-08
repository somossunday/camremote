import SwiftUI

@main
struct CamRemoteColorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = EditorModel.shared

    init() {
        CommandLineExport.runIfRequested()
    }

    var body: some Scene {
        Window("CamRemote Color", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir vídeo…") { model.showOpenPanel() }.keyboardShortcut("o")
                Button("Siguiente vídeo enviado") { model.openNextInInbox() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(model.inbox.count < 2)
            }
            CommandGroup(after: .newItem) {
                Button("Exportar…") { NotificationCenter.default.post(name: .showExport, object: nil) }
                    .keyboardShortcut("e")
                    .disabled(model.clip == nil)
            }
            CommandMenu("Color") {
                Button("Restablecer todos los ajustes") { model.resetAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Picker("Comparar", selection: $model.compare) {
                    ForEach(CompareMode.allCases) { Text($0.name).tag($0) }
                }
            }
        }
    }
}

extension Notification.Name {
    static let showExport = Notification.Name("camremote.showExport")
}

/// Recibe los vídeos enviados a la app (CamRemote, Finder «Abrir con», arrastrar al Dock).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            urls.forEach { EditorModel.shared.receive($0) }
        }
    }
}
