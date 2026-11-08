import Foundation

struct WheelValue: Codable, Equatable, Hashable {
    var x: Double = 0      // -1…1 (dirección de color)
    var y: Double = 0
    var luma: Double = 0   // -1…1

    var isNeutral: Bool { x == 0 && y == 0 && luma == 0 }

    /// Vector de color de media cero para el ángulo/radio de la rueda.
    var color: SIMD3<Double> {
        let r = min(1, (x * x + y * y).squareRoot())
        guard r > 0 else { return .zero }
        let a = atan2(y, x)
        return SIMD3(cos(a), cos(a - 2 * .pi / 3), cos(a + 2 * .pi / 3)) * r
    }
}

struct CurvePoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

struct CurveSet: Codable, Equatable, Hashable {
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    var master = CurveSet.identity
    var red = CurveSet.identity
    var green = CurveSet.identity
    var blue = CurveSet.identity

    var isIdentity: Bool { [master, red, green, blue].allSatisfy { $0 == CurveSet.identity } }
}

struct HSLAdjust: Codable, Equatable, Hashable {
    var hue: Double = 0   // -1…1 (±30°)
    var sat: Double = 0   // -1…1
    var lum: Double = 0   // -1…1
    var isNeutral: Bool { hue == 0 && sat == 0 && lum == 0 }
}

enum HSLBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Int { rawValue }
    static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
    var name: String {
        ["Rojos", "Naranjas", "Amarillos", "Verdes", "Aguamarinas", "Azules", "Morados", "Magentas"][rawValue]
    }
}

enum LUTSpace: String, Codable, CaseIterable, Identifiable {
    case rec709, appleLog, hlg
    var id: String { rawValue }
    var name: String {
        switch self {
        case .rec709: return "Rec.709"
        case .appleLog: return "Apple Log"
        case .hlg: return "HLG"
        }
    }
}

struct LUTRef: Codable, Equatable, Hashable {
    var name: String            // nombre del archivo .cube en la biblioteca
    var intensity: Double = 1
    var input: LUTSpace = .rec709
    var output: LUTSpace = .rec709
}

/// Todos los ajustes de color de un clip. Se guarda como JSON en los presets.
struct ColorSettings: Codable, Equatable, Hashable {
    var exposure: Double = 0      // pasos, -4…4
    var contrast: Double = 0      // -1…1
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    var temperature: Double = 0   // -1 (frío) … 1 (cálido)
    var tint: Double = 0          // -1 (verde) … 1 (magenta)
    var saturation: Double = 0    // -1…1
    var vibrance: Double = 0
    var lift = WheelValue()
    var gamma = WheelValue()
    var gain = WheelValue()
    var curves = CurveSet()
    var hsl = [HSLAdjust](repeating: HSLAdjust(), count: HSLBand.allCases.count)
    var lut: LUTRef?

    init() {}

    var hslIsNeutral: Bool { hsl.allSatisfy(\.isNeutral) }
    var needsCube: Bool { !curves.isIdentity || !hslIsNeutral }

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, temperature, tint,
             saturation, vibrance, lift, gamma, gain, curves, hsl, lut
    }

    // Decodificación tolerante: faltan claves → valores por defecto.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? 0 }
        exposure = d(.exposure); contrast = d(.contrast); highlights = d(.highlights)
        shadows = d(.shadows); whites = d(.whites); blacks = d(.blacks)
        temperature = d(.temperature); tint = d(.tint); saturation = d(.saturation); vibrance = d(.vibrance)
        lift = (try? c.decodeIfPresent(WheelValue.self, forKey: .lift)) ?? WheelValue()
        gamma = (try? c.decodeIfPresent(WheelValue.self, forKey: .gamma)) ?? WheelValue()
        gain = (try? c.decodeIfPresent(WheelValue.self, forKey: .gain)) ?? WheelValue()
        curves = (try? c.decodeIfPresent(CurveSet.self, forKey: .curves)) ?? CurveSet()
        var h = (try? c.decodeIfPresent([HSLAdjust].self, forKey: .hsl)) ?? []
        while h.count < HSLBand.allCases.count { h.append(HSLAdjust()) }
        hsl = Array(h.prefix(HSLBand.allCases.count))
        lut = try? c.decodeIfPresent(LUTRef.self, forKey: .lut)
    }

    /// Ganancias de balance de blancos en lineal, normalizadas para no cambiar la luminancia.
    var whiteBalanceGains: SIMD3<Double> {
        let t = temperature, ti = tint
        let g = SIMD3(pow(2, 0.30 * t + 0.12 * ti), pow(2, -0.24 * ti), pow(2, -0.30 * t + 0.12 * ti))
        let l = 0.2627 * g.x + 0.6780 * g.y + 0.0593 * g.z
        return g / l
    }
    var liftVector: SIMD3<Double> { SIMD3(repeating: lift.luma * 0.25) + lift.color * 0.15 }
    var gammaVector: SIMD3<Double> { SIMD3(repeating: 1 + gamma.luma * 0.5) + gamma.color * 0.25 }
    var gainVector: SIMD3<Double> { SIMD3(repeating: 1 + gain.luma * 0.6) * (SIMD3(repeating: 1) + gain.color * 0.3) }
}
