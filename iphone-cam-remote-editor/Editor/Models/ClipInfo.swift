import AVFoundation
import CoreImage
import CoreVideo

/// Espacio de color del archivo exportado (y de la vista previa).
enum OutputSpace: String, Codable, CaseIterable, Identifiable {
    case hlg2020, rec709, p3d65
    var id: String { rawValue }

    var name: String {
        switch self {
        case .hlg2020: return "HLG · BT.2020 (HDR)"
        case .rec709: return "Rec.709 (SDR)"
        case .p3d65: return "P3 D65 (SDR)"
        }
    }
    var isHDR: Bool { self == .hlg2020 }
    /// Valor lineal máximo representable (1.0 = blanco de referencia 203 nits).
    var peak: Float { self == .hlg2020 ? 4.926 : 1.0 }

    var primaries: CFString {
        switch self {
        case .hlg2020: return kCVImageBufferColorPrimaries_ITU_R_2020
        case .rec709: return kCVImageBufferColorPrimaries_ITU_R_709_2
        case .p3d65: return kCVImageBufferColorPrimaries_P3_D65
        }
    }
    var transfer: CFString {
        self == .hlg2020 ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2
    }
    var matrix: CFString {
        self == .hlg2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }
    var attachments: [String: Any] {
        [kCVImageBufferColorPrimariesKey as String: primaries,
         kCVImageBufferTransferFunctionKey as String: transfer,
         kCVImageBufferYCbCrMatrixKey as String: matrix]
    }
    var avColorProperties: [String: Any] {
        switch self {
        case .hlg2020:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .rec709:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .p3d65:
            return [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        }
    }
    var colorSpace: CGColorSpace {
        switch self {
        case .hlg2020: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)!
        case .rec709: return CGColorSpace(name: CGColorSpace.itur_709)!
        case .p3d65:
            return CVImageBufferCreateColorSpaceFromAttachments(attachments as CFDictionary)?.takeRetainedValue()
                ?? CGColorSpace(name: CGColorSpace.displayP3)!
        }
    }
}

/// Cómo interpretar el color del clip de origen.
enum InputInterpretation: String, Codable, CaseIterable, Identifiable {
    case auto, rec709, p3, hlg, pq, appleLog, appleLog2
    var id: String { rawValue }
    var name: String {
        switch self {
        case .auto: return "Automático (metadatos)"
        case .rec709: return "Rec.709"
        case .p3: return "P3 D65 · 709"
        case .hlg: return "HLG · BT.2020"
        case .pq: return "PQ · BT.2020"
        case .appleLog: return "Apple Log"
        case .appleLog2: return "Apple Log 2"
        }
    }
    var isLog: Bool { self == .appleLog || self == .appleLog2 }

    /// Espacio de color de CG para el decodificado (nil = Log, se decodifica con kernel propio).
    var colorSpace: CGColorSpace? {
        switch self {
        case .auto, .rec709: return CGColorSpace(name: CGColorSpace.itur_709)
        case .p3: return OutputSpace.p3d65.colorSpace
        case .hlg: return CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .pq: return CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .appleLog, .appleLog2: return nil
        }
    }
}

struct ClipInfo: Equatable {
    let url: URL
    let codecName: String
    let width: Int
    let height: Int
    let fps: Double
    let bitDepth: Int?
    let chroma: String?
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let logCurve: String?
    let duration: Double
    let videoBitrate: Double
    let audio: [String]
    let detected: InputInterpretation

    var isHDR: Bool { detected == .hlg || detected == .pq || detected.isLog }

    var colorLabel: String {
        switch detected {
        case .hlg: return "HLG · BT.2020"
        case .pq: return "PQ · BT.2020"
        case .appleLog: return "Apple Log · BT.2020"
        case .appleLog2: return "Apple Log 2 · Apple Wide Gamut"
        case .p3: return "P3 D65 · 709"
        default:
            if primaries == nil && transfer == nil { return "Sin etiquetar (Rec.709)" }
            return "Rec.709"
        }
    }

    var formatLabel: String {
        var parts = [codecName]
        if let b = bitDepth { parts.append("\(b) bits") }
        if let c = chroma { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    var resolutionLabel: String {
        let f = fps.rounded() == fps ? String(format: "%.0f", fps) : String(format: "%.2f", fps)
        return "\(width)×\(height) · \(f) fps · \(String(format: "%.0f", videoBitrate / 1_000_000)) Mbps"
    }

    static func load(url: URL) async throws -> (AVURLAsset, ClipInfo) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EditorError.message("El archivo no contiene vídeo.")
        }
        let (fds, size, transform, fps, rate) = try await track.load(.formatDescriptions, .naturalSize,
                                                                      .preferredTransform, .nominalFrameRate,
                                                                      .estimatedDataRate)
        let duration = try await asset.load(.duration).seconds
        guard let fd = fds.first else { throw EditorError.message("Formato de vídeo desconocido.") }

        let ext = (CMFormatDescriptionGetExtensions(fd) as? [String: Any]) ?? [:]
        let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        let log = ext[kCMFormatDescriptionExtension_LogTransferFunction as String] as? String

        let sub = CMFormatDescriptionGetMediaSubType(fd)
        var codec = fourCC(sub)
        var bits: Int? = (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue
        var chroma: String?
        switch sub {
        case kCMVideoCodecType_AppleProRes422HQ: codec = "ProRes 422 HQ"; bits = 10; chroma = "4:2:2"
        case kCMVideoCodecType_AppleProRes422: codec = "ProRes 422"; bits = 10; chroma = "4:2:2"
        case kCMVideoCodecType_AppleProRes422LT: codec = "ProRes 422 LT"; bits = 10; chroma = "4:2:2"
        case kCMVideoCodecType_AppleProRes422Proxy: codec = "ProRes 422 Proxy"; bits = 10; chroma = "4:2:2"
        case kCMVideoCodecType_AppleProRes4444: codec = "ProRes 4444"; bits = 12; chroma = "4:4:4"
        case kCMVideoCodecType_AppleProRes4444XQ: codec = "ProRes 4444 XQ"; bits = 12; chroma = "4:4:4"
        case kCMVideoCodecType_HEVC:
            codec = "HEVC"
            if let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
               let hvcc = atoms["hvcC"] as? Data, hvcc.count > 18 {
                let b = [UInt8](hvcc)
                bits = Int(b[17] & 0x7) + 8
                chroma = ["4:0:0", "4:2:0", "4:2:2", "4:4:4"][Int(b[16] & 0x3)]
            }
        case kCMVideoCodecType_H264:
            codec = "H.264"
            if let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
               let avcc = atoms["avcC"] as? Data, avcc.count > 1 {
                let profile = [UInt8](avcc)[1]
                if profile < 100 { bits = 8; chroma = "4:2:0" }
            }
        default: break
        }

        let detected: InputInterpretation
        if let log {
            detected = log.contains("wide-gamut") || log.lowercased().contains("log2") ? .appleLog2 : .appleLog
        } else if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) {
            detected = .hlg
        } else if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
            detected = .pq
        } else if primaries == (kCMFormatDescriptionColorPrimaries_P3_D65 as String) {
            detected = .p3
        } else {
            detected = .rec709
        }

        var audio: [String] = []
        for at in try await asset.loadTracks(withMediaType: .audio) {
            for afd in try await at.load(.formatDescriptions) {
                audio.append(describeAudio(afd))
            }
        }

        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let info = ClipInfo(url: url, codecName: codec,
                            width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()),
                            fps: Double(fps), bitDepth: bits, chroma: chroma,
                            primaries: primaries, transfer: transfer, matrix: matrix, logCurve: log,
                            duration: duration, videoBitrate: Double(rate), audio: audio, detected: detected)
        return (asset, info)
    }

    static func describeAudio(_ fd: CMFormatDescription) -> String {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return "Audio" }
        let khz = asbd.mSampleRate / 1000
        let rate = khz.rounded() == khz ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
        let ch = asbd.mChannelsPerFrame == 1 ? "mono" : asbd.mChannelsPerFrame == 2 ? "estéreo" : "\(asbd.mChannelsPerFrame) canales"
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return "PCM \(asbd.mBitsPerChannel) bits\(float ? " float" : "") · \(rate) · \(ch)"
        case kAudioFormatMPEG4AAC: return "AAC · \(rate) · \(ch)"
        case kAudioFormatAppleLossless: return "ALAC · \(rate) · \(ch)"
        default: return "\(fourCC(asbd.mFormatID)) · \(rate) · \(ch)"
        }
    }
}

func fourCC(_ v: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(v)"
}

enum EditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
