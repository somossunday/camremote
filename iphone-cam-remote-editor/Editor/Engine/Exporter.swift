import AVFoundation
import VideoToolbox

enum ExportFormat: String, CaseIterable, Identifiable {
    case prores422HQ, prores4444, hevc10
    var id: String { rawValue }
    var name: String {
        switch self {
        case .prores422HQ: return "Apple ProRes 422 HQ (10 bits 4:2:2)"
        case .prores4444: return "Apple ProRes 4444 (12 bits 4:4:4)"
        case .hevc10: return "HEVC 10 bits (alta tasa)"
        }
    }
    var codec: AVVideoCodecType {
        switch self {
        case .prores422HQ: return .proRes422HQ
        case .prores4444: return .proRes4444
        case .hevc10: return .hevc
        }
    }
    var pixelFormat: OSType {
        switch self {
        case .prores422HQ: return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .prores4444: return kCVPixelFormatType_4444AYpCbCr16
        case .hevc10: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
    }
}

/// Exporta con AVAssetReader/AVAssetWriter: vídeo procesado por el compositor de color,
/// audio copiado tal cual (sin decodificar ni recomprimir).
final class Exporter: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; let r = reader; let w = writer; lock.unlock()
        r?.cancelReading()
        w?.cancelWriting()
    }

    private func attach(_ r: AVAssetReader, _ w: AVAssetWriter) {
        lock.lock(); reader = r; writer = w; lock.unlock()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func export(asset: AVAsset, state: RenderState, format: ExportFormat, range: CMTimeRange,
                to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var st = state
        st.compare = .off
        let renderer = GradeRenderer(st)
        let composition = try await CompositionBuilder.make(asset: asset, renderer: renderer, output: st.output)

        guard let vtrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw EditorError.message("El archivo no contiene vídeo.")
        }
        let atracks = try await asset.loadTracks(withMediaType: .audio)
        let fps = try await vtrack.load(.nominalFrameRate)
        let timescale = try await vtrack.load(.naturalTimeScale)

        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = timescale
        if let meta = try? await asset.load(.metadata) { writer.metadata = meta }

        // Vídeo
        let vout = AVAssetReaderVideoCompositionOutput(videoTracks: [vtrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
        ])
        vout.videoComposition = composition
        vout.alwaysCopiesSampleData = false
        guard reader.canAdd(vout) else { throw EditorError.message("No se puede leer el vídeo.") }
        reader.add(vout)

        let w = Int(composition.renderSize.width), h = Int(composition.renderSize.height)
        var vsettings: [String: Any] = [
            AVVideoCodecKey: format.codec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: st.output.avColorProperties
        ]
        if format == .hevc10 {
            // ~0.5 bits por píxel y fotograma: 4K30 ≈ 125 Mbps.
            let bitrate = max(20_000_000, Int(Double(w * h) * Double(max(fps, 24)) * 0.5))
            vsettings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoAllowFrameReorderingKey: true
            ]
        }
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: vsettings)
        vin.expectsMediaDataInRealTime = false
        guard writer.canAdd(vin) else { throw EditorError.message("El formato de vídeo elegido no es compatible.") }
        writer.add(vin)

        // Audio: passthrough (outputSettings nil en lectura y escritura).
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for t in atracks {
            let fds = try await t.load(.formatDescriptions)
            let aout = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
            aout.alwaysCopiesSampleData = false
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fds.first)
            ain.expectsMediaDataInRealTime = false
            if reader.canAdd(aout) && writer.canAdd(ain) {
                reader.add(aout); writer.add(ain)
                audioPairs.append((aout, ain))
            }
        }

        attach(reader, writer)

        guard reader.startReading() else {
            throw reader.error ?? EditorError.message("No se pudo empezar a leer el clip.")
        }
        guard writer.startWriting() else {
            throw writer.error ?? EditorError.message("No se pudo crear el archivo de salida.")
        }
        writer.startSession(atSourceTime: range.start)

        let total = range.duration.seconds
        let group = DispatchGroup()

        func pump(_ o: AVAssetReaderOutput, _ i: AVAssetWriterInput, label: String, reportProgress: Bool) {
            group.enter()
            let io = IOPair(output: o, input: i)
            let q = DispatchQueue(label: "camremote.export.\(label)")
            // Captura fuerte: el exportador vive hasta que terminan todas las pistas.
            i.requestMediaDataWhenReady(on: q) { [self] in
                let output = io.output, input = io.input
                while input.isReadyForMoreMediaData {
                    if self.isCancelled {
                        input.markAsFinished(); group.leave(); return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); group.leave(); return
                    }
                    if !input.append(sample) {
                        input.markAsFinished(); group.leave(); return
                    }
                    if reportProgress, total > 0 {
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - range.start.seconds
                        progress(min(1, max(0, t / total)))
                    }
                }
            }
        }

        pump(vout, vin, label: "video", reportProgress: true)
        for (i, pair) in audioPairs.enumerated() { pump(pair.0, pair.1, label: "audio\(i)", reportProgress: false) }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { c.resume() }
        }

        if isCancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? EditorError.message("Error leyendo el clip.")
        }
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? EditorError.message("Error escribiendo el archivo.")
        }
        progress(1)
    }
}

private struct IOPair: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
}
