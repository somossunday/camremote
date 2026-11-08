import Foundation

/// Recibe un vídeo a trozos y lo escribe en disco. Solo se usa desde la cola de red.
final class Downloader {
    private struct Active {
        let id: String
        let target: URL
        let temp: URL
        let handle: FileHandle
        var expected: Int64
        var received: Int64 = 0
        var lastReport = Date.distantPast
    }

    private var active: Active?
    var targets: [String: URL] = [:]           // id → destino final (lo rellena el modelo)
    var onProgress: ((String, Double) -> Void)?
    var onFinished: ((String, Result<URL, Error>) -> Void)?

    static var folder: URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("CamRemote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func target(for r: RecordingInfo) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let ext = (r.filename as NSString).pathExtension.isEmpty ? "mov" : (r.filename as NSString).pathExtension
        return folder.appendingPathComponent("CamRemote \(f.string(from: r.date)).\(ext)")
    }

    /// Devuelve true si el mensaje era de descarga.
    func handle(_ msg: ServerMessage) -> Bool {
        switch msg {
        case .downloadStart(let id, let bytes):
            abort()
            guard let target = targets[id] else { return true }
            let temp = target.appendingPathExtension("part")
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: temp) else {
                onFinished?(id, .failure(err("No se pudo escribir en \(temp.deletingLastPathComponent().path)")))
                return true
            }
            active = Active(id: id, target: target, temp: temp, handle: h, expected: bytes)
            onProgress?(id, 0)
        case .downloadEnd(let id):
            guard let a = active, a.id == id else { return true }
            try? a.handle.close()
            active = nil
            try? FileManager.default.removeItem(at: a.target)
            do {
                try FileManager.default.moveItem(at: a.temp, to: a.target)
                onFinished?(id, .success(a.target))
            } catch {
                onFinished?(id, .failure(error))
            }
        case .downloadFailed(let id, let reason):
            if active?.id == id { abort() }
            onFinished?(id, .failure(err(reason)))
        default:
            return false
        }
        return true
    }

    func chunk(_ data: Data) {
        guard var a = active else { return }
        a.handle.write(data)
        a.received += Int64(data.count)
        if Date().timeIntervalSince(a.lastReport) > 0.15, a.expected > 0 {
            a.lastReport = Date()
            onProgress?(a.id, min(Double(a.received) / Double(a.expected), 1))
        }
        active = a
    }

    /// Cancela la descarga en curso (p. ej. si se cae la conexión).
    func abort() {
        guard let a = active else { return }
        try? a.handle.close()
        try? FileManager.default.removeItem(at: a.temp)
        active = nil
        onFinished?(a.id, .failure(err("Descarga interrumpida")))
    }

    private func err(_ s: String) -> NSError { NSError(domain: "CamRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
}
