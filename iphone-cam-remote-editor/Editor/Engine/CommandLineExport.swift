import AVFoundation

/// Modo sin interfaz para pruebas y lotes:
/// CamRemote\ Color --export entrada.mov salida.mov [--preset builtin.teal_orange] [--lut archivo.cube]
///   [--intensity 0.8] [--format prores422HQ|prores4444|hevc10] [--output hlg2020|rec709|p3d65] [--exposure 0.5]
enum CommandLineExport {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--export"), args.count > i + 2 else { return }
        let input = URL(fileURLWithPath: args[i + 1]), output = URL(fileURLWithPath: args[i + 2])
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), args.count > j + 1 else { return nil }
            return args[j + 1]
        }
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let (asset, info) = try await ClipInfo.load(url: input)
                print("Entrada: \(info.formatLabel) · \(info.resolutionLabel) · \(info.colorLabel) · \(info.audio.joined(separator: ", "))")
                var st = RenderState()
                st.input = info.detected
                st.output = value("--output").flatMap(OutputSpace.init(rawValue:)) ?? (info.isHDR ? .hlg2020 : .rec709)
                if let id = value("--preset"), let p = BuiltInPresets.all.first(where: { $0.id == id }) {
                    st.settings = p.settings
                    if let o = p.output, value("--output") == nil { st.output = o }
                }
                if let e = value("--exposure").flatMap(Double.init) { st.settings.exposure = e }
                if let path = value("--lut") {
                    let lut = try LoadedLUT.parse(url: URL(fileURLWithPath: path))
                    st.lut = lut
                    st.settings.lut = LUTRef(name: lut.name, intensity: value("--intensity").flatMap(Double.init) ?? 1)
                }
                st.cube = ColorMath.bakeCube(st.settings)
                let format = value("--format").flatMap(ExportFormat.init(rawValue:)) ?? .prores422HQ
                let duration = try await asset.load(.duration)
                let start = Date()
                let exporter = Exporter()
                try await exporter.export(asset: asset, state: st, format: format,
                                            range: CMTimeRange(start: .zero, duration: duration), to: output) { _ in }
                print(String(format: "Exportado en %.1f s → %@", Date().timeIntervalSince(start), output.path))
            } catch {
                print("Error: \(error.localizedDescription) — \(error)")
                code = 1
            }
            sem.signal()
        }
        sem.wait()
        exit(code)
    }
}
