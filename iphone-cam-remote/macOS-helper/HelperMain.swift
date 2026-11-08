import AppKit
import Network
import os

let log = Logger(subsystem: "com.adrianmillares.camremote.mac.helper", category: "watcher")

/// Ayudante invisible (ítem de inicio de sesión). Vigila la red y, cuando aparece
/// un iPhone con CamRemote abierto, abre la app del Mac aunque esté cerrada.
final class Watcher {
    static let mainID = "com.adrianmillares.camremote.mac"
    private let queue = DispatchQueue(label: "helper.browser")
    private var browser: NWBrowser?
    private var present = Set<String>()
    /// Arranques del iPhone ya vistos: un parpadeo del anuncio en la red no debe reabrir la app.
    private var seen = Set<String>()

    /// Preferencias de la app principal (mismo usuario, sin sandbox).
    private var prefs: UserDefaults? { UserDefaults(suiteName: Self.mainID) }

    func start() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_camremote._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            // Clave = nombre + id de arranque, para detectar también reaperturas rápidas.
            var keys = Set<String>()
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                var sid = ""
                if case .bonjour(let txt) = r.metadata { sid = txt["sid"] ?? "" }
                // Al cerrarse la app del iPhone a veces llega un resultado sin TXT: no es una apertura.
                guard !sid.isEmpty else { continue }
                keys.insert(name + "\u{1}" + sid)
            }
            self?.changed(keys)
        }
        b.stateUpdateHandler = { [weak self] state in
            log.notice("browser state: \(String(describing: state), privacy: .public)")
            if case .failed = state {
                self?.browser?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 5) { self?.start() }
            }
        }
        b.start(queue: queue)
        browser = b
    }

    private func changed(_ keys: Set<String>) {
        let arrivedKeys = keys.subtracting(present).subtracting(seen)
        present = keys
        seen.formUnion(keys)
        let names = Set(keys.map { String($0.split(separator: "\u{1}", omittingEmptySubsequences: false)[0]) })
        let arrived = Set(arrivedKeys.map { String($0.split(separator: "\u{1}", omittingEmptySubsequences: false)[0]) })
        prefs?.synchronize()
        let autoOpen = prefs?.object(forKey: "autoOpen") as? Bool ?? true
        log.notice("names=\(names.sorted(), privacy: .public) arrived=\(arrived.sorted(), privacy: .public) autoOpen=\(autoOpen) pins=\(arrived.map { self.prefs?.string(forKey: "pin.\($0)") != nil }, privacy: .public)")
        guard autoOpen, arrived.contains(where: { prefs?.string(forKey: "pin.\($0)") != nil }) else { return }
        DispatchQueue.main.async { self.openMainApp() }
    }

    private func openMainApp() {
        // Si ya está abierta, ella misma abre su ventana.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.mainID).isEmpty else { log.notice("main already running"); return }
        // Helper.app está en CamRemote.app/Contents/Library/LoginItems/
        let mainApp = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        log.notice("opening \(mainApp.path, privacy: .public)")
        NSWorkspace.shared.openApplication(at: mainApp, configuration: cfg) { _, error in
            if let error { log.error("open failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

@main
enum HelperMain {
    static let watcher = Watcher()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        watcher.start()
        app.run()
    }
}
