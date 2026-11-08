import AVFoundation
import UIKit

/// Vídeos grabados con CamRemote, guardados en la carpeta de la propia app
/// (visible en Archivos › En mi iPhone › CamRemote). Al ser archivos propios,
/// se pueden borrar sin que iOS pida confirmación (cosa que Fotos siempre exige).
final class RecordingLibrary {
    static let limit = 10
    private let queue = DispatchQueue(label: "cam.library")

    static var folder: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    /// Mueve una grabación terminada a la biblioteca. Devuelve su URL final.
    func store(_ temp: URL, date: Date) throws -> URL {
        let target = Self.folder.appendingPathComponent("CamRemote \(Self.nameFormatter.string(from: date)).mov")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    private func files() -> [(url: URL, date: Date, bytes: Int64)] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.creationDate ?? .distantPast, Int64(v?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    private func url(for id: String) -> URL? {
        let u = Self.folder.appendingPathComponent(id)
        guard u.deletingLastPathComponent().standardizedFileURL == Self.folder.standardizedFileURL,
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    func list(completion: @escaping ([RecordingInfo]) -> Void) {
        queue.async { [self] in
        let recent = Array(files().prefix(Self.limit))
        Task.detached(priority: .utility) {
            var infos: [RecordingInfo] = []
            for f in recent {
                let asset = AVURLAsset(url: f.url)
                let duration = (try? await asset.load(.duration).seconds) ?? 0
                var size = CGSize.zero
                if let track = try? await asset.loadTracks(withMediaType: .video).first,
                   let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                    let r = CGRect(origin: .zero, size: natural).applying(transform)
                    size = CGSize(width: abs(r.width), height: abs(r.height))
                }
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                var thumb: Data?
                if let (cg, _) = try? await gen.image(at: CMTime(seconds: min(1, duration / 2), preferredTimescale: 600)) {
                    thumb = UIImage(cgImage: cg).jpegData(compressionQuality: 0.6)
                }
                infos.append(RecordingInfo(id: f.url.lastPathComponent, date: f.date, duration: duration,
                                           width: Int(size.width), height: Int(size.height), bytes: f.bytes,
                                           filename: f.url.lastPathComponent, thumbnail: thumb))
            }
            completion(infos)
        }
        }
    }

    /// Borra el archivo de la app. Sin confirmación de iOS y sin papelera: es definitivo.
    func delete(id: String, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard let u = url(for: id) else { completion(nil); return }
            do { try FileManager.default.removeItem(at: u); completion(nil) } catch { completion(error) }
        }
    }

    /// Lee el archivo a trozos de 1 MB. `chunk` puede bloquear (control de flujo con la red).
    func stream(id: String, start: @escaping (Int64) -> Void, chunk: @escaping (Data) -> Void, done: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard let u = url(for: id), let h = try? FileHandle(forReadingFrom: u) else {
                done(NSError(domain: "CamRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: "El vídeo ya no está en el iPhone."]))
                return
            }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
            start(size)
            DispatchQueue.global(qos: .utility).async {
                defer { try? h.close() }
                do {
                    while let data = try h.read(upToCount: 1 << 20), !data.isEmpty { chunk(data) }
                    done(nil)
                } catch {
                    done(error)
                }
            }
        }
    }
}
