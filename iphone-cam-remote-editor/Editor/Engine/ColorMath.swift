import Foundation

/// Funciones de color en CPU (mismas fórmulas que Kernels.metal).
enum ColorMath {
    static let cct0 = 0.0729055341958355
    static let cct1 = 0.5547945205479452

    static func linToCct(_ x: Double) -> Double {
        x <= 0.0078125 ? 10.5402377416545 * x + cct0 : (log2(x) + 9.72) / 17.52
    }
    static func cctToLin(_ y: Double) -> Double {
        y <= 0.155251141552511 ? (y - cct0) / 10.5402377416545 : exp2(y * 17.52 - 9.72)
    }
    static func cctToN(_ c: Double) -> Double { (c - cct0) / (cct1 - cct0) }
    static func nToCct(_ n: Double) -> Double { n * (cct1 - cct0) + cct0 }

    static let cubeSize = 33

    /// Cubo 3D (dominio ACEScct 0…1) con curvas y HSL. nil si ambos son neutros.
    static func bakeCube(_ s: ColorSettings) -> Data? {
        guard s.needsCube else { return nil }
        let curves = s.curves
        let master = MonotoneSpline(curves.master)
        let red = MonotoneSpline(curves.red), green = MonotoneSpline(curves.green), blue = MonotoneSpline(curves.blue)
        let hsl = s.hsl
        let doHSL = !s.hslIsNeutral
        let n = cubeSize
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    var c = SIMD3(Double(ri), Double(gi), Double(bi)) / Double(n - 1)
                    c = SIMD3(cctToN(c.x), cctToN(c.y), cctToN(c.z))
                    c = SIMD3(master.eval(red.eval(c.x)), master.eval(green.eval(c.y)), master.eval(blue.eval(c.z)))
                    if doHSL { c = applyHSL(c, hsl) }
                    data[i] = Float(nToCct(c.x)); data[i + 1] = Float(nToCct(c.y))
                    data[i + 2] = Float(nToCct(c.z)); data[i + 3] = 1
                    i += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func applyHSL(_ c: SIMD3<Double>, _ hsl: [HSLAdjust]) -> SIMD3<Double> {
        let cl = SIMD3(min(1, max(0, c.x)), min(1, max(0, c.y)), min(1, max(0, c.z)))
        let mx = cl.max(), mn = cl.min()
        let chroma = mx - mn
        guard chroma > 0.0001 else { return c }
        var h: Double
        if mx == cl.x { h = 60 * ((cl.y - cl.z) / chroma) }
        else if mx == cl.y { h = 60 * ((cl.z - cl.x) / chroma + 2) }
        else { h = 60 * ((cl.x - cl.y) / chroma + 4) }
        if h < 0 { h += 360 }

        // Pesos por banda (interpolación entre centros adyacentes, suma 1).
        let centers = HSLBand.centers
        var adj = HSLAdjust()
        for k in 0..<centers.count {
            let c0 = centers[k]
            let c1 = k + 1 < centers.count ? centers[k + 1] : 360
            if h >= c0 && h < c1 {
                let t = smoothstep(0, 1, (h - c0) / (c1 - c0))
                let a = hsl[k], b = hsl[(k + 1) % centers.count]
                adj.hue = a.hue * (1 - t) + b.hue * t
                adj.sat = a.sat * (1 - t) + b.sat * t
                adj.lum = a.lum * (1 - t) + b.lum * t
                break
            }
        }
        let m = smoothstep(0.02, 0.15, chroma)
        let theta = adj.hue * 30 * m * .pi / 180
        let avg = (c.x + c.y + c.z) / 3
        let v = c - SIMD3(repeating: avg)
        let k = 1 / 3.0.squareRoot()
        // k × v con k = (1,1,1)/√3: ángulo positivo lleva rojo → amarillo.
        let cross = SIMD3(k * (v.z - v.y), k * (v.x - v.z), k * (v.y - v.x))
        let rotated = v * cos(theta) + cross * sin(theta)
        let sat = max(0, 1 + adj.sat * m)
        return SIMD3(repeating: avg + adj.lum * 0.15 * m) + rotated * sat
    }
}

/// Interpolación cúbica monótona (Fritsch–Carlson) con extrapolación lineal.
struct MonotoneSpline {
    private var xs: [Double] = []
    private var ys: [Double] = []
    private var ms: [Double] = []

    init(_ points: [CurvePoint]) {
        let p = points.sorted { $0.x < $1.x }
        var cleaned: [CurvePoint] = []
        for q in p where cleaned.last.map({ q.x - $0.x > 1e-4 }) ?? true { cleaned.append(q) }
        xs = cleaned.map(\.x); ys = cleaned.map(\.y)
        let n = xs.count
        guard n >= 2 else { return }
        var d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) { d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k]) }
        ms = [Double](repeating: 0, count: n)
        ms[0] = d[0]; ms[n - 1] = d[n - 2]
        if n > 2 {
            for k in 1..<(n - 1) { ms[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2 }
        }
        for k in 0..<(n - 1) {
            if d[k] == 0 { ms[k] = 0; ms[k + 1] = 0; continue }
            let a = ms[k] / d[k], b = ms[k + 1] / d[k]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                ms[k] = t * a * d[k]; ms[k + 1] = t * b * d[k]
            }
        }
    }

    func eval(_ x: Double) -> Double {
        let n = xs.count
        guard n >= 2 else { return x }
        if x <= xs[0] { return ys[0] + ms[0] * (x - xs[0]) }
        if x >= xs[n - 1] { return ys[n - 1] + ms[n - 1] * (x - xs[n - 1]) }
        var lo = 0, hi = n - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if xs[mid] > x { hi = mid } else { lo = mid } }
        let h = xs[hi] - xs[lo]
        let t = (x - xs[lo]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * ys[lo] + (t3 - 2 * t2 + t) * h * ms[lo]
            + (-2 * t3 + 3 * t2) * ys[hi] + (t3 - t2) * h * ms[hi]
    }
}
