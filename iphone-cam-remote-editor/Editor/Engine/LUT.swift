import Foundation

/// LUT cargada en memoria, siempre como cubo 3D RGBA float (r varía más rápido).
struct LoadedLUT: @unchecked Sendable {
    let name: String
    let size: Int
    let data: Data
    let domainMin: SIMD3<Double>
    let domainMax: SIMD3<Double>
    let is1D: Bool

    /// Lee un archivo .cube (Adobe/Resolve), 1D o 3D.
    static func parse(url: URL) throws -> LoadedLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size3 = 0, size1 = 0
        var dmin = SIMD3<Double>(0, 0, 0), dmax = SIMD3<Double>(1, 1, 1)
        var values: [Float] = []
        values.reserveCapacity(65 * 65 * 65 * 3)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = parts.first else { continue }
            if let v = Float(first) {
                guard parts.count >= 3, let g = Float(parts[1]), let b = Float(parts[2]) else { continue }
                values.append(v); values.append(g); values.append(b)
                continue
            }
            switch first.uppercased() {
            case "LUT_3D_SIZE": size3 = Int(parts.last ?? "") ?? 0
            case "LUT_1D_SIZE": size1 = Int(parts.last ?? "") ?? 0
            case "DOMAIN_MIN" where parts.count >= 4:
                dmin = SIMD3(Double(parts[1]) ?? 0, Double(parts[2]) ?? 0, Double(parts[3]) ?? 0)
            case "DOMAIN_MAX" where parts.count >= 4:
                dmax = SIMD3(Double(parts[1]) ?? 1, Double(parts[2]) ?? 1, Double(parts[3]) ?? 1)
            default: break // TITLE, LUT_3D_INPUT_RANGE…
            }
        }
        let name = url.deletingPathExtension().lastPathComponent
        if size3 > 1 {
            guard size3 <= 129, values.count >= size3 * size3 * size3 * 3 else {
                throw EditorError.message("El LUT 3D «\(name)» está incompleto.")
            }
            var rgba = [Float](repeating: 1, count: size3 * size3 * size3 * 4)
            for i in 0..<(size3 * size3 * size3) {
                rgba[i * 4] = values[i * 3]; rgba[i * 4 + 1] = values[i * 3 + 1]; rgba[i * 4 + 2] = values[i * 3 + 2]
            }
            // CIColorCube admite hasta 64; si es mayor se remuestrea.
            if size3 > 64 { rgba = resample(rgba, from: size3, to: 64); size3 = 64 }
            return LoadedLUT(name: name, size: size3, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
                             domainMin: dmin, domainMax: dmax, is1D: false)
        }
        if size1 > 1 {
            guard values.count >= size1 * 3 else { throw EditorError.message("El LUT 1D «\(name)» está incompleto.") }
            // Se convierte a cubo 3D de 33.
            let n = 33
            var rgba = [Float](repeating: 1, count: n * n * n * 4)
            func lookup(_ x: Double, _ ch: Int) -> Float {
                let p = min(1, max(0, x)) * Double(size1 - 1)
                let i0 = Int(p), i1 = min(size1 - 1, i0 + 1), t = Float(p - Double(i0))
                return values[i0 * 3 + ch] * (1 - t) + values[i1 * 3 + ch] * t
            }
            var i = 0
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                rgba[i] = lookup(Double(r) / Double(n - 1), 0)
                rgba[i + 1] = lookup(Double(g) / Double(n - 1), 1)
                rgba[i + 2] = lookup(Double(b) / Double(n - 1), 2)
                i += 4
            } } }
            return LoadedLUT(name: name, size: n, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) },
                             domainMin: dmin, domainMax: dmax, is1D: true)
        }
        throw EditorError.message("«\(name)» no parece un archivo .cube válido (falta LUT_3D_SIZE o LUT_1D_SIZE).")
    }

    private static func resample(_ src: [Float], from n: Int, to m: Int) -> [Float] {
        func at(_ r: Int, _ g: Int, _ b: Int, _ c: Int) -> Float { src[((b * n + g) * n + r) * 4 + c] }
        var out = [Float](repeating: 1, count: m * m * m * 4)
        var i = 0
        for b in 0..<m { for g in 0..<m { for r in 0..<m {
            let p = [r, g, b].map { Double($0) * Double(n - 1) / Double(m - 1) }
            let i0 = p.map { Int($0) }, i1 = i0.map { min(n - 1, $0 + 1) }
            let t = zip(p, i0).map { Float($0 - Double($1)) }
            for c in 0..<3 {
                var v: Float = 0
                for corner in 0..<8 {
                    let rr = corner & 1 == 0 ? i0[0] : i1[0], wr = corner & 1 == 0 ? 1 - t[0] : t[0]
                    let gg = corner & 2 == 0 ? i0[1] : i1[1], wg = corner & 2 == 0 ? 1 - t[1] : t[1]
                    let bb = corner & 4 == 0 ? i0[2] : i1[2], wb = corner & 4 == 0 ? 1 - t[2] : t[2]
                    v += at(rr, gg, bb, c) * wr * wg * wb
                }
                out[i + c] = v
            }
            i += 4
        } } }
        return out
    }
}

/// Biblioteca de LUTs en ~/Library/Application Support/CamRemote Color/LUTs.
enum LUTLibrary {
    static var directory: URL {
        let dir = AppPaths.support.appendingPathComponent("LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func names() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name).appendingPathExtension("cube") }

    /// Copia el .cube a la biblioteca (validándolo) y devuelve su nombre.
    static func importLUT(from url: URL) throws -> String {
        _ = try LoadedLUT.parse(url: url)
        let name = url.deletingPathExtension().lastPathComponent
        let dest = self.url(for: name)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: url, to: dest)
        return name
    }

    private static var cache: [String: LoadedLUT] = [:]
    private static let lock = NSLock()

    static func load(_ name: String) -> LoadedLUT? {
        lock.lock(); defer { lock.unlock() }
        if let l = cache[name] { return l }
        guard let l = try? LoadedLUT.parse(url: url(for: name)) else { return nil }
        cache[name] = l
        return l
    }

    static func remove(_ name: String) {
        lock.lock(); cache[name] = nil; lock.unlock()
        try? FileManager.default.removeItem(at: url(for: name))
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CamRemote Color", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var camRemoteMovies: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/CamRemote", isDirectory: true)
    }
}
