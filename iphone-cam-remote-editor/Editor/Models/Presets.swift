import Foundation

struct Preset: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var category: String
    var settings: ColorSettings
    var output: OutputSpace?      // solo para conversiones (p. ej. Apple Log → Rec.709)
    var builtIn: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, category, settings, output }

    init(id: String, name: String, category: String, settings: ColorSettings, output: OutputSpace? = nil, builtIn: Bool) {
        self.id = id; self.name = name; self.category = category
        self.settings = settings; self.output = output; self.builtIn = builtIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "Preset"
        category = (try? c.decode(String.self, forKey: .category)) ?? "Mis presets"
        settings = try c.decode(ColorSettings.self, forKey: .settings)
        output = try? c.decodeIfPresent(OutputSpace.self, forKey: .output)
        builtIn = false
    }
}

private func wheel(_ hueDeg: Double, _ amount: Double, luma: Double = 0) -> WheelValue {
    let a = hueDeg * .pi / 180
    return WheelValue(x: cos(a) * amount, y: sin(a) * amount, luma: luma)
}

private func pts(_ p: [(Double, Double)]) -> [CurvePoint] { p.map { CurvePoint(x: $0.0, y: $0.1) } }

private func make(_ id: String, _ name: String, _ cat: String, output: OutputSpace? = nil,
                  _ build: (inout ColorSettings) -> Void) -> Preset {
    var s = ColorSettings()
    build(&s)
    return Preset(id: "builtin." + id, name: name, category: cat, settings: s, output: output, builtIn: true)
}

// Tonos de las ruedas: 0° rojo, 30° naranja, 60° amarillo, 120° verde, 180° cian, 240° azul, 300° magenta.
enum BuiltInPresets {
    static let all: [Preset] = [
        make("neutral", "Neutro", "Básicos") { _ in },
        make("natural", "Natural", "Básicos") { s in
            s.contrast = 0.08; s.vibrance = 0.15; s.curves.master = pts([(0, 0), (0.25, 0.23), (0.75, 0.77), (1, 1)])
        },
        make("vivid", "Vívido", "Básicos") { s in
            s.contrast = 0.15; s.saturation = 0.15; s.vibrance = 0.35; s.blacks = -0.2
        },
        make("soft", "Suave", "Básicos") { s in
            s.contrast = -0.15; s.highlights = -0.3; s.shadows = 0.3; s.vibrance = 0.05
        },

        make("log709", "Apple Log → Rec.709", "Conversión", output: .rec709) { s in
            s.contrast = 0.12; s.saturation = 0.08
            s.curves.master = pts([(0, 0), (0.2, 0.17), (0.8, 0.83), (1, 1)])
        },
        make("loghlg", "Apple Log → HLG", "Conversión", output: .hlg2020) { s in
            s.exposure = 0.3; s.contrast = 0.06; s.saturation = 0.05
        },

        make("cine_warm", "Cine cálido", "Cinematográficos") { s in
            s.contrast = 0.15; s.temperature = 0.25; s.saturation = -0.1
            s.lift = wheel(200, 0.15, luma: 0.05); s.gain = wheel(40, 0.2)
            s.curves.master = pts([(0, 0.03), (0.25, 0.22), (0.75, 0.8), (1, 0.97)])
        },
        make("teal_orange", "Teal & Orange", "Cinematográficos") { s in
            s.contrast = 0.18; s.vibrance = 0.15
            s.lift = wheel(195, 0.35); s.gamma = wheel(195, 0.08); s.gain = wheel(32, 0.3)
            s.hsl[HSLBand.orange.rawValue] = HSLAdjust(hue: -0.05, sat: 0.2, lum: 0.05)
            s.hsl[HSLBand.blue.rawValue] = HSLAdjust(hue: -0.4, sat: 0.1, lum: -0.1)
            s.hsl[HSLBand.aqua.rawValue] = HSLAdjust(hue: 0.2, sat: 0.15, lum: 0)
            s.hsl[HSLBand.green.rawValue] = HSLAdjust(hue: 0.4, sat: -0.3, lum: 0)
        },
        make("blockbuster", "Blockbuster", "Cinematográficos") { s in
            s.contrast = 0.3; s.blacks = -0.25; s.saturation = -0.05; s.vibrance = 0.2
            s.lift = wheel(205, 0.3); s.gain = wheel(38, 0.25, luma: 0.05)
            s.curves.master = pts([(0, 0), (0.2, 0.14), (0.8, 0.86), (1, 1)])
        },
        make("bleach", "Bleach bypass", "Cinematográficos") { s in
            s.contrast = 0.35; s.saturation = -0.55; s.blacks = -0.15; s.highlights = 0.1
            s.curves.master = pts([(0, 0), (0.3, 0.24), (0.7, 0.78), (1, 1)])
        },
        make("film35", "Película 35 mm", "Cinematográficos") { s in
            s.contrast = 0.1; s.temperature = 0.1; s.saturation = -0.08
            s.curves.master = pts([(0, 0.05), (0.2, 0.2), (0.8, 0.82), (1, 0.95)])
            s.curves.blue = pts([(0, 0.06), (1, 0.94)])
            s.hsl[HSLBand.green.rawValue] = HSLAdjust(hue: -0.2, sat: -0.2, lum: 0)
            s.hsl[HSLBand.red.rawValue] = HSLAdjust(hue: 0.05, sat: 0.1, lum: 0)
        },
        make("film_cold", "Película fría", "Cinematográficos") { s in
            s.contrast = 0.1; s.temperature = -0.15; s.tint = -0.08; s.saturation = -0.15
            s.lift = wheel(150, 0.15, luma: 0.04)
            s.curves.master = pts([(0, 0.04), (0.5, 0.5), (1, 0.96)])
        },
        make("matte", "Matte", "Cinematográficos") { s in
            s.contrast = -0.05; s.saturation = -0.12
            s.curves.master = pts([(0, 0.1), (0.15, 0.17), (0.85, 0.85), (1, 0.93)])
        },
        make("moody", "Moody", "Cinematográficos") { s in
            s.exposure = -0.3; s.contrast = 0.2; s.shadows = -0.2; s.saturation = -0.25
            s.lift = wheel(220, 0.2); s.gain = wheel(45, 0.1)
            s.hsl[HSLBand.green.rawValue] = HSLAdjust(hue: 0.2, sat: -0.4, lum: -0.2)
        },
        make("western", "Western", "Cinematográficos") { s in
            s.contrast = 0.2; s.temperature = 0.45; s.saturation = -0.2
            s.gamma = wheel(45, 0.15); s.gain = wheel(50, 0.15)
            s.curves.master = pts([(0, 0.04), (0.5, 0.52), (1, 0.97)])
        },
        make("night_blue", "Noche azul", "Cinematográficos") { s in
            s.exposure = -0.6; s.contrast = 0.15; s.temperature = -0.5; s.saturation = -0.3
            s.lift = wheel(230, 0.25); s.gamma = wheel(225, 0.12)
        },

        make("bw_classic", "B/N clásico", "Blanco y negro") { s in
            s.saturation = -1; s.contrast = 0.12
        },
        make("bw_contrast", "B/N alto contraste", "Blanco y negro") { s in
            s.saturation = -1; s.contrast = 0.4; s.blacks = -0.3; s.whites = 0.2
            s.curves.master = pts([(0, 0), (0.25, 0.18), (0.75, 0.84), (1, 1)])
        },
        make("bw_soft", "B/N suave", "Blanco y negro") { s in
            s.saturation = -1; s.contrast = -0.15
            s.curves.master = pts([(0, 0.06), (1, 0.96)])
        },
        make("selenium", "Selenio", "Blanco y negro") { s in
            s.saturation = -1; s.contrast = 0.15
            s.lift = wheel(280, 0.2); s.gain = wheel(40, 0.12)
        },
        make("sepia", "Sepia", "Blanco y negro") { s in
            s.saturation = -1; s.contrast = 0.05
            s.gamma = wheel(35, 0.35); s.gain = wheel(45, 0.2)
            s.curves.master = pts([(0, 0.05), (1, 0.95)])
        },

        make("warm", "Cálido", "Color") { s in
            s.temperature = 0.35; s.tint = 0.05; s.vibrance = 0.1
        },
        make("cold", "Frío", "Color") { s in
            s.temperature = -0.35; s.tint = -0.03; s.vibrance = 0.05
        },
        make("pastel", "Pastel", "Color") { s in
            s.contrast = -0.25; s.saturation = -0.3; s.vibrance = 0.2; s.shadows = 0.35
            s.lift = wheel(300, 0.1, luma: 0.1)
            s.curves.master = pts([(0, 0.12), (0.5, 0.56), (1, 0.98)])
        },
        make("sunset", "Atardecer", "Color") { s in
            s.temperature = 0.5; s.tint = 0.15; s.contrast = 0.1; s.vibrance = 0.25
            s.gain = wheel(20, 0.2)
            s.hsl[HSLBand.orange.rawValue] = HSLAdjust(hue: -0.1, sat: 0.3, lum: 0)
        },
        make("summer", "Verano", "Color") { s in
            s.exposure = 0.2; s.temperature = 0.2; s.vibrance = 0.4; s.shadows = 0.2
            s.hsl[HSLBand.blue.rawValue] = HSLAdjust(hue: -0.15, sat: 0.25, lum: 0)
            s.hsl[HSLBand.aqua.rawValue] = HSLAdjust(hue: 0, sat: 0.3, lum: 0.1)
        },
        make("vintage", "Vintage", "Color") { s in
            s.contrast = -0.1; s.saturation = -0.25; s.temperature = 0.2
            s.curves.master = pts([(0, 0.08), (0.5, 0.5), (1, 0.92)])
            s.curves.red = pts([(0, 0.03), (1, 1)])
            s.curves.blue = pts([(0, 0.08), (1, 0.88)])
        },
        make("green_forest", "Bosque", "Color") { s in
            s.contrast = 0.12; s.saturation = -0.1
            s.hsl[HSLBand.green.rawValue] = HSLAdjust(hue: 0.25, sat: 0.1, lum: -0.15)
            s.hsl[HSLBand.yellow.rawValue] = HSLAdjust(hue: 0.3, sat: -0.1, lum: 0)
            s.lift = wheel(160, 0.12)
        }
    ]
}

/// Presets del usuario en ~/Library/Application Support/CamRemote Color/Presets/*.json
enum UserPresetStore {
    static var directory: URL {
        let dir = AppPaths.support.appendingPathComponent("Presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    static func loadAll() -> [Preset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Preset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ p: Preset) throws {
        try encoder.encode(p).write(to: directory.appendingPathComponent(p.id + ".json"), options: .atomic)
    }

    static func delete(_ p: Preset) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(p.id + ".json"))
    }
}
