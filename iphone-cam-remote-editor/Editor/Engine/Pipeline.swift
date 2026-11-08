import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal

enum CompareMode: String, CaseIterable, Identifiable {
    case off, split, original
    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: return "Después"
        case .split: return "Dividido"
        case .original: return "Antes"
        }
    }
}

/// Todo lo necesario para procesar un fotograma (inmutable, se comparte entre hilos).
struct RenderState: @unchecked Sendable {
    var settings = ColorSettings()
    var input: InputInterpretation = .rec709
    var output: OutputSpace = .rec709
    var compare: CompareMode = .off
    var split: Double = 0.5
    var highlightRolloff = true
    var cube: Data?          // curvas + HSL horneados
    var lut: LoadedLUT?
}

enum Pipeline {
    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    static let device = MTLCreateSystemDefaultDevice()!

    /// Contexto compartido: Metal, half float, lineal BT.2020 extendido.
    static let context = CIContext(mtlDevice: device, options: [
        .workingColorSpace: workingSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .name: "CamRemoteColor"
    ])

    private static let library: Data = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else { fatalError("Falta default.metallib") }
        return data
    }()
    private static func kernel(_ name: String) -> CIColorKernel {
        do { return try CIColorKernel(functionName: name, fromMetalLibraryData: library) }
        catch { fatalError("Kernel \(name): \(error)") }
    }
    static let appleLogToLinear = kernel("appleLogToLinear")
    static let linearToAppleLog = kernel("linearToAppleLog")
    static let gradingToLinear = kernel("gradingToLinear")
    static let primaryGrade = kernel("primaryGrade")
    static let softClip = kernel("softClip")
    static let mixImages = kernel("mixImages")

    // MARK: Entrada

    /// CIImage en lineal BT.2020 a partir de un fotograma decodificado.
    static func inputImage(_ buffer: CVPixelBuffer, input: InputInterpretation) -> CIImage {
        if input.isLog {
            let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            return apply(appleLogToLinear, raw)
        }
        if let cs = input.colorSpace {
            return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: cs])
        }
        return CIImage(cvPixelBuffer: buffer)
    }

    static func apply(_ k: CIColorKernel, _ img: CIImage, _ args: [Any] = []) -> CIImage {
        k.apply(extent: img.extent, arguments: [img] + args) ?? img
    }

    static func vec(_ v: SIMD3<Double>) -> CIVector { CIVector(x: v.x, y: v.y, z: v.z) }

    // MARK: Etalonado

    /// Aplica el etalonado completo. Entrada y salida en lineal (salida ya comprimida al pico del destino).
    static func grade(_ src: CIImage, _ st: RenderState) -> CIImage {
        let s = st.settings
        var img = apply(primaryGrade, src, [
            s.exposure,
            vec(s.whiteBalanceGains),
            CIVector(x: s.highlights, y: s.shadows, z: s.whites, w: s.blacks),
            s.contrast,
            CIVector(x: s.saturation, y: s.vibrance),
            vec(s.liftVector), vec(s.gammaVector), vec(s.gainVector)
        ])
        if let cube = st.cube {
            let f = CIFilter.colorCube()
            f.inputImage = img
            f.cubeDimension = Float(ColorMath.cubeSize)
            f.cubeData = cube
            img = f.outputImage ?? img
        }
        img = apply(gradingToLinear, img)
        if let ref = s.lut, let lut = st.lut, ref.intensity > 0 {
            img = applyLUT(img, lut: lut, ref: ref)
        }
        return finish(img, st)
    }

    static func finish(_ img: CIImage, _ st: RenderState) -> CIImage {
        st.highlightRolloff ? apply(softClip, img, [st.output.peak]) : img
    }

    static func encode(_ img: CIImage, _ space: LUTSpace) -> CIImage {
        switch space {
        case .appleLog: return apply(linearToAppleLog, img)
        case .rec709: return img.matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.itur_709)!) ?? img
        case .hlg: return img.matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!) ?? img
        }
    }

    static func decode(_ img: CIImage, _ space: LUTSpace) -> CIImage {
        switch space {
        case .appleLog: return apply(appleLogToLinear, img)
        case .rec709: return img.matchedToWorkingSpace(from: CGColorSpace(name: CGColorSpace.itur_709)!) ?? img
        case .hlg: return img.matchedToWorkingSpace(from: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!) ?? img
        }
    }

    static func applyLUT(_ img: CIImage, lut: LoadedLUT, ref: LUTRef) -> CIImage {
        var enc = encode(img, ref.input)
        if lut.domainMin != SIMD3(0, 0, 0) || lut.domainMax != SIMD3(1, 1, 1) {
            let scale = SIMD3<Double>(1, 1, 1) / (lut.domainMax - lut.domainMin)
            let bias = -lut.domainMin * scale
            let m = CIFilter.colorMatrix()
            m.inputImage = enc
            m.rVector = CIVector(x: scale.x, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: scale.y, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: scale.z, w: 0)
            m.biasVector = CIVector(x: bias.x, y: bias.y, z: bias.z, w: 0)
            enc = m.outputImage ?? enc
        }
        let f = CIFilter.colorCube()
        f.inputImage = enc
        f.cubeDimension = Float(lut.size)
        f.cubeData = lut.data
        let looked = decode(f.outputImage ?? enc, ref.output)
        if ref.intensity >= 1 { return looked }
        return mixImages.apply(extent: img.extent, arguments: [img, looked, ref.intensity]) ?? looked
    }

    /// Imagen final según el modo de comparación.
    static func compose(_ src: CIImage, _ st: RenderState) -> CIImage {
        switch st.compare {
        case .original: return finish(src, st)
        case .off: return grade(src, st)
        case .split:
            let e = src.extent
            let x = e.minX + e.width * CGFloat(st.split)
            let before = finish(src, st).cropped(to: CGRect(x: e.minX, y: e.minY, width: x - e.minX, height: e.height))
            let after = grade(src, st).cropped(to: CGRect(x: x, y: e.minY, width: e.maxX - x, height: e.height))
            let w = max(2, e.width / 640)
            let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
                .cropped(to: CGRect(x: x - w / 2, y: e.minY, width: w, height: e.height))
            return line.composited(over: after.composited(over: before))
        }
    }

    /// Renderiza en un CVPixelBuffer (RGBA half) etiquetado con el espacio de salida.
    static func render(_ img: CIImage, to buffer: CVPixelBuffer, output: OutputSpace) {
        CVBufferSetAttachments(buffer, output.attachments as CFDictionary, .shouldPropagate)
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        context.render(img, to: buffer, bounds: rect, colorSpace: output.colorSpace)
    }

    /// Miniatura SDR (sRGB, 8 bits).
    static func thumbnail(_ src: CIImage, _ st: RenderState) -> CGImage? {
        var s = st
        s.output = .rec709
        s.compare = .off
        s.highlightRolloff = true
        let img = grade(src, s)
        return context.createCGImage(img, from: src.extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Orienta el fotograma según preferredTransform y lo lleva al origen.
    static func orient(_ img: CIImage, transform t: CGAffineTransform) -> CIImage {
        let o: CGImagePropertyOrientation
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): o = .right
        case (0, -1, 1, 0): o = .left
        case (-1, 0, 0, -1): o = .down
        default: o = .up
        }
        let r = o == .up ? img : img.oriented(o)
        return r.transformed(by: CGAffineTransform(translationX: -r.extent.minX, y: -r.extent.minY))
    }
}

/// Estado de render compartido entre la UI y el compositor (hilo seguro).
final class GradeRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var _state: RenderState

    init(_ state: RenderState = RenderState()) { _state = state }

    var state: RenderState {
        get { lock.lock(); defer { lock.unlock() }; return _state }
        set { lock.lock(); _state = newValue; lock.unlock() }
    }
}
