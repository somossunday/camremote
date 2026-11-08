import AVFoundation
import CoreImage

/// Instrucción de composición que lleva el renderer (estado de color) al compositor.
final class GradeInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let renderer: GradeRenderer
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform, renderer: GradeRenderer) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        self.renderer = renderer
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

/// Compositor propio: recibe los fotogramas originales (10 bits, HDR) y los procesa con Core Image en half float.
final class GradeCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "camremote.compositor", qos: .userInitiated)
    private var generation = 0
    private let lock = NSLock()

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_64RGBAHalf
        ] as [OSType],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()
    ]

    var supportsWideColorSourceFrames: Bool { true }
    var supportsHDRSourceFrames: Bool { true }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let gen = generation; lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let cancelled = gen != self.generation; self.lock.unlock()
            if cancelled { request.finishCancelledRequest(); return }
            autoreleasepool { self.process(request) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock(); generation += 1; lock.unlock()
    }

    private func process(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? GradeInstruction,
              let source = request.sourceFrame(byTrackID: ins.trackID),
              let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: EditorError.message("No se pudo componer el fotograma."))
            return
        }
        let st = ins.renderer.state
        let input = Pipeline.orient(Pipeline.inputImage(source, input: st.input), transform: ins.transform)
        let img = Pipeline.compose(input, st)
        Pipeline.render(img, to: out, output: st.output)
        request.finish(withComposedVideoFrame: out)
    }
}

enum CompositionBuilder {
    /// Composición de vídeo con el compositor de color para reproducción o exportación.
    static func make(asset: AVAsset, renderer: GradeRenderer, output: OutputSpace) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EditorError.message("El archivo no contiene vídeo.")
        }
        let (size, transform, minDur, fps) = try await track.load(.naturalSize, .preferredTransform,
                                                                  .minFrameDuration, .nominalFrameRate)
        let id = track.trackID
        let duration = try await asset.load(.duration)
        let comp = AVMutableVideoComposition()
        comp.customVideoCompositorClass = GradeCompositor.self
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        comp.renderSize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        comp.frameDuration = frameDuration(fps: Double(fps), minDur: minDur)
        // Respeta la cadencia exacta del original (29,97, VFR…) en vez de remuestrear a una rejilla fija.
        comp.sourceTrackIDForFrameTiming = id
        comp.colorPrimaries = output.avColorProperties[AVVideoColorPrimariesKey] as? String
        comp.colorTransferFunction = output.avColorProperties[AVVideoTransferFunctionKey] as? String
        comp.colorYCbCrMatrix = output.avColorProperties[AVVideoYCbCrMatrixKey] as? String
        comp.instructions = [GradeInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                              trackID: id, transform: transform, renderer: renderer)]
        return comp
    }

    static func frameDuration(fps: Double, minDur: CMTime) -> CMTime {
        for (rate, d) in [(23.976, CMTime(value: 1001, timescale: 24000)), (29.97, CMTime(value: 1001, timescale: 30000)),
                          (59.94, CMTime(value: 1001, timescale: 60000)), (119.88, CMTime(value: 1001, timescale: 120000))]
        where abs(fps - rate) < 0.02 { return d }
        if fps > 0 { return CMTime(value: 1, timescale: CMTimeScale(fps.rounded())) }
        return minDur.isValid && minDur.seconds > 0 ? minDur : CMTime(value: 1, timescale: 30)
    }
}
