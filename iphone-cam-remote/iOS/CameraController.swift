import AVFoundation
import CoreImage
import Photos
import UIKit
import VideoToolbox

/// Gestiona la cámara: sesión, ajustes, grabación (AVAssetWriter) y vista previa en JPEG.
final class CameraController: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cam.session")
    private let mediaQueue = DispatchQueue(label: "cam.media")      // vídeo + audio + escritura
    private let previewQueue = DispatchQueue(label: "cam.preview")

    private var videoInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var device: AVCaptureDevice? { videoInput?.device }

    // Ajustes elegidos (sessionQueue)
    private var kind: CameraKind = .wide
    private var resolution: Resolution = .hd1080
    private var fps = 30
    private var orientation: Orientation = .landscape
    private var codec: VideoCodec = .hevc
    private var videoQuality: VideoQuality = .standard
    private var appleLog = false

    /// HDR, ProRes y Log necesitan el sensor en 10 bits.
    private var tenBit: Bool { videoQuality != .standard || appleLog }
    private static let pixel8 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange      // 420v
    private static let pixel8Full = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange   // 420f (admite P3)
    private static let pixel10 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange    // x420 (HDR)
    private static let pixel10_422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange // x422 (Log / ProRes)

    private struct Requirement { let pixel: OSType; let spaces: [AVCaptureColorSpace] }

    /// Formatos aceptables para la calidad elegida, en orden de preferencia
    /// (según lo que ofrece el iPhone 17 Pro: P3 en 420f, HLG en x420, Log en x422).
    private func requirements() -> [Requirement] {
        if appleLog { return [Requirement(pixel: Self.pixel10_422, spaces: [.appleLog2, .appleLog])] }
        switch videoQuality {
        case .standard: return [Requirement(pixel: Self.pixel8Full, spaces: [.P3_D65]), Requirement(pixel: Self.pixel8, spaces: [.sRGB])]
        case .hdr: return [Requirement(pixel: Self.pixel10, spaces: [.HLG_BT2020]), Requirement(pixel: Self.pixel10_422, spaces: [.HLG_BT2020])]
        case .prores: return [Requirement(pixel: Self.pixel10_422, spaces: [.HLG_BT2020]), Requirement(pixel: Self.pixel10, spaces: [.HLG_BT2020])]
        }
    }

    private func requirementIndex(_ f: AVCaptureDevice.Format) -> Int? {
        let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return requirements().firstIndex { $0.pixel == sub && $0.spaces.contains(where: f.supportedColorSpaces.contains) }
    }
    private var stabilization = true

    // Grabación (mediaQueue)
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?
    private var writerStarted = false
    private var recordingStart: Date?   // solo lectura aproximada para el contador
    private var isRecording: Bool { recordingStart != nil }

    // Vista previa
    var previewEnabled = true
    private var previewBusy = false
    private var lastPreview = CFAbsoluteTimeGetCurrent()
    private let previewFPS = 15.0
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var onPreviewFrame: ((Data) -> Void)?
    var onStateChange: (() -> Void)?
    var onEvent: ((ServerMessage) -> Void)?
    var onSaved: ((String) -> Void)?   // id del vídeo guardado
    var library: RecordingLibrary!

    // Preferencias que se recuerdan entre sesiones.
    private var audioCodec = AudioCodec(rawValue: UserDefaults.standard.string(forKey: "audioCodec") ?? "") ?? .pcm {
        didSet { UserDefaults.standard.set(audioCodec.rawValue, forKey: "audioCodec") }
    }
    private var saveToPhotos = UserDefaults.standard.bool(forKey: "saveToPhotos") {
        didSet { UserDefaults.standard.set(saveToPhotos, forKey: "saveToPhotos") }
    }
    private var lastAudioFormat: CMFormatDescription?   // mediaQueue
    private var lastVideoSize = CGSize.zero             // mediaQueue: tamaño real de los fotogramas

    // MARK: Arranque

    func requestPermissionsAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
                    self.sessionQueue.async { self.configureSession() }
                }
            }
        }
        DispatchQueue.main.async {
            UIDevice.current.isBatteryMonitoringEnabled = true
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func configureSession() {
        configureAudioSession()
        session.beginConfiguration()
        session.automaticallyConfiguresCaptureDeviceForWideColor = false   // el color lo elegimos nosotros
        // Gestionamos nosotros la sesión de audio para poder elegir el micro (USB-C, auriculares…).
        session.automaticallyConfiguresApplicationAudioSession = false

        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.setSampleBufferDelegate(self, queue: mediaQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        audioOutput.setSampleBufferDelegate(self, queue: mediaQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        let start = availableCameras().contains(.wide) ? CameraKind.wide : (availableCameras().first ?? .wide)
        _ = switchInput(to: start)
        // Seguir usando la cámara con la app en segundo plano (modo videollamada).
        if session.isMultitaskingCameraAccessSupported { session.isMultitaskingCameraAccessEnabled = true }
        session.commitConfiguration()
        observeInterruptions()
        session.startRunning()
        restoreSettings()
        notify()
    }

    // MARK: Interrupciones

    private func observeInterruptions() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
            let raw = n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            let text: String
            switch reason {
            case .videoDeviceNotAvailableInBackground?: text = "iOS ha pausado la cámara en segundo plano."
            case .videoDeviceInUseByAnotherClient?: text = "Otra app está usando la cámara."
            case .audioDeviceInUseByAnotherClient?: text = "Otra app está usando el micro."
            default: text = "La cámara se ha interrumpido."
            }
            self?.emitError(text)
        }
        nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { if self?.session.isRunning == false { self?.session.startRunning() }; self?.notify() }
        }
        nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
            self?.sessionQueue.asyncAfter(deadline: .now() + 1) { self?.session.startRunning() }
        }
    }

    // MARK: Audio

    /// Nivel medio del micro en dBFS (se actualiza en mediaQueue).
    private(set) var audioLevel: Float = -160

    private func configureAudioSession() {
        let a = AVAudioSession.sharedInstance()
        do {
            try a.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .mixWithOthers])
            try? a.setPreferredSampleRate(48_000)
            try a.setActive(true)
            updateAudioMode()
        } catch {
            emitError("No se pudo preparar el audio: \(error.localizedDescription)")
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sessionQueue.async {
                if self?.isRecording == false { self?.updateAudioMode() }
                self?.notify()
            }
        }
    }

    private var isExternalMic: Bool {
        guard let p = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return false }
        return p.portType != .builtInMic
    }

    /// Micro externo: modo «measurement» = señal limpia, sin control de ganancia ni reducción de ruido.
    /// Micro del iPhone: modo «videoRecording» (estéreo y ajustado para vídeo).
    private func updateAudioMode() {
        let a = AVAudioSession.sharedInstance()
        let mode: AVAudioSession.Mode = isExternalMic ? .measurement : .videoRecording
        if a.mode != mode { try? a.setMode(mode) }
    }

    private func audioFormatText() -> String {
        let a = AVAudioSession.sharedInstance()
        var ch = a.inputNumberOfChannels
        var rate = a.sampleRate
        if let f = mediaQueue.sync(execute: { lastAudioFormat }),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
            ch = Int(asbd.mChannelsPerFrame)
            rate = asbd.mSampleRate
        }
        let chText = ch == 1 ? "mono" : ch == 2 ? "estéreo" : "\(ch) canales"
        let proc = a.mode == .measurement ? "sin procesado" : "procesado del iPhone"
        return "\(Int(rate / 1000)) kHz · \(chText) · \(proc)"
    }

    private static func sourceName(_ ds: AVAudioSessionDataSourceDescription) -> String {
        switch ds.orientation {
        case .front?: return "iPhone · micro frontal"
        case .back?: return "iPhone · micro trasero"
        case .bottom?: return "iPhone · micro inferior"
        case .top?: return "iPhone · micro superior"
        default: return "iPhone · \(ds.dataSourceName)"
        }
    }

    private static func portName(_ p: AVAudioSessionPortDescription) -> String {
        switch p.portType {
        case .usbAudio: return "USB-C · \(p.portName)"
        case .headsetMic: return "Auriculares · \(p.portName)"
        case .bluetoothHFP: return "Bluetooth · \(p.portName)"
        case .builtInMic: return "iPhone · micro"
        default: return p.portName
        }
    }

    private func audioInputs() -> [AudioInput] {
        (AVAudioSession.sharedInstance().availableInputs ?? []).flatMap { port -> [AudioInput] in
            if port.portType == .builtInMic, let sources = port.dataSources, sources.count > 1 {
                return sources.map { AudioInput(id: "\(port.uid)|\($0.dataSourceID)", name: Self.sourceName($0)) }
            }
            return [AudioInput(id: port.uid, name: Self.portName(port))]
        }
    }

    private func currentAudioInputID() -> String? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.inputs.first else { return nil }
        if port.portType == .builtInMic, let ds = port.selectedDataSource, (port.dataSources?.count ?? 0) > 1 {
            return "\(port.uid)|\(ds.dataSourceID)"
        }
        return port.uid
    }

    private func selectAudioInput(_ id: String) {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        let a = AVAudioSession.sharedInstance()
        guard let port = a.availableInputs?.first(where: { $0.uid == parts[0] }) else {
            emitError("Ese micro ya no está conectado.")
            return
        }
        do {
            try a.setPreferredInput(port)
            if parts.count == 2, let ds = port.dataSources?.first(where: { "\($0.dataSourceID)" == parts[1] }) {
                try port.setPreferredDataSource(ds)
            }
        } catch {
            emitError("No se pudo cambiar el micro: \(error.localizedDescription)")
        }
    }

    // MARK: Dispositivos

    private func captureDevice(for kind: CameraKind) -> AVCaptureDevice? {
        switch kind {
        case .ultraWide: return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case .wide: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .telephoto: return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case .front: return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .cinematic:
            return AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
        case .cinematicFront: return AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)
        }
    }

    private lazy var cachedCameras: [CameraKind] = CameraKind.allCases.filter { k in
        guard let dev = captureDevice(for: k) else { return false }
        return !k.isCinematic || dev.formats.contains { $0.isCinematicVideoCaptureSupported }
    }

    private func availableCameras() -> [CameraKind] { cachedCameras }

    /// Debe llamarse dentro de begin/commitConfiguration.
    private func switchInput(to newKind: CameraKind) -> Bool {
        guard let dev = captureDevice(for: newKind), let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        if let old = videoInput { session.removeInput(old) }
        guard session.canAddInput(input) else {
            if let old = videoInput { session.addInput(old) }
            return false
        }
        session.addInput(input)
        videoInput = input
        kind = newKind

        // Mantener la resolución/fps si la nueva lente lo admite; si no, la mejor disponible.
        if !supportedResolutions(dev).contains(resolution) { resolution = supportedResolutions(dev).last ?? .hd1080 }
        if !supportedFPS(dev, resolution).contains(fps) { fps = supportedFPS(dev, resolution).filter { $0 <= 30 }.last ?? 30 }
        applyFormat()
        applyCinematic()
        applyConnectionSettings()
        return true
    }

    /// Activa/desactiva el Modo Cine en la entrada (dentro de begin/commitConfiguration).
    private func applyCinematic() {
        guard let input = videoInput else { return }
        let want = kind.isCinematic && input.isCinematicVideoCaptureSupported
        if input.isCinematicVideoCaptureEnabled != want { input.isCinematicVideoCaptureEnabled = want }
        if kind.isCinematic && !want { emitError("El Modo Cine no está disponible con este formato. Prueba 1080p o 4K a 30 fps.") }
        if want { configure { d in d.videoZoomFactor = d.videoZoomFactor.clamped(self.minZoom(d), self.maxZoom(d)) } }
    }

    // MARK: Formatos

    private static let fpsOptions = [24, 25, 30, 60, 120, 240]

    private func formats(_ dev: AVCaptureDevice, _ res: Resolution, _ fps: Int) -> [AVCaptureDevice.Format] {
        let cine = kind.isCinematic
        return dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width == res.width && d.height == res.height else { return false }
            if cine {
                guard f.isCinematicVideoCaptureSupported, let r = f.videoFrameRateRangeForCinematicVideo else { return false }
                return r.minFrameRate <= Double(fps) && r.maxFrameRate >= Double(fps)
            }
            return requirementIndex(f) != nil &&
                f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) })
        }
    }

    private func supportedResolutions(_ dev: AVCaptureDevice) -> [Resolution] {
        Resolution.allCases.filter { !formats(dev, $0, 24).isEmpty || !formats(dev, $0, 30).isEmpty }
    }

    private func supportedFPS(_ dev: AVCaptureDevice, _ res: Resolution) -> [Int] {
        Self.fpsOptions.filter { !formats(dev, res, $0).isEmpty }
    }

    private func applyFormat() {
        guard let dev = device else { return }
        // Ordenados por preferencia de formato (p. ej. P3 antes que sRGB).
        let candidates = formats(dev, resolution, fps).sorted { (requirementIndex($0) ?? 9) < (requirementIndex($1) ?? 9) }
        // Preferir formatos con estabilización cinemática y sin binning.
        // Preferir 8 bits sin binning (en Modo Cine también hay formatos de 10 bits).
        let bestIndex = candidates.first.flatMap(requirementIndex) ?? 0
        let is420v = { (f: AVCaptureDevice.Format) in self.requirementIndex(f) == bestIndex || self.kind.isCinematic }
        let format = candidates.first { is420v($0) && !$0.isVideoBinned && $0.isVideoStabilizationModeSupported(.cinematicExtended) }
            ?? candidates.first { is420v($0) && !$0.isVideoBinned }
            ?? candidates.first { !$0.isVideoBinned } ?? candidates.first
        guard let format else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = format
            let spaces = requirementIndex(format).map { requirements()[$0].spaces } ?? []
            if let cs = spaces.first(where: format.supportedColorSpaces.contains) { dev.activeColorSpace = cs }
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            dev.activeVideoMinFrameDuration = duration
            dev.activeVideoMaxFrameDuration = duration
            if !(videoInput?.isCinematicVideoCaptureEnabled ?? false), dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
            dev.unlockForConfiguration()
        } catch {
            emitError("No se pudo aplicar el formato: \(error.localizedDescription)")
        }
        // Los fotogramas que recibimos, en la misma profundidad que el sensor.
        // ProRes 422 aprovecha el 4:2:2; HEVC trabaja en 4:2:0.
        let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let pixel: OSType
        switch sub {
        case Self.pixel10_422: pixel = videoQuality == .prores ? Self.pixel10_422 : Self.pixel10
        case Self.pixel10, Self.pixel8Full: pixel = sub
        default: pixel = Self.pixel8
        }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixel]
    }

    /// Si la resolución/fps actuales no existen con la calidad elegida, usa lo más parecido.
    private func normalizeFormat() {
        guard let dev = device else { return }
        let resolutions = supportedResolutions(dev)
        if !resolutions.contains(resolution) { resolution = resolutions.last ?? .hd1080 }
        let rates = supportedFPS(dev, resolution)
        if !rates.contains(fps) { fps = rates.filter { $0 <= fps }.last ?? rates.first ?? 30 }
    }

    // MARK: Calidad

    private func capability(_ dev: AVCaptureDevice, _ spaces: [AVCaptureColorSpace]) -> Bool {
        dev.formats.contains { spaces.contains(where: $0.supportedColorSpaces.contains) }
    }

    /// iOS no anuncia ProRes para AVAssetWriter, pero los iPhone Pro lo codifican: lo comprobamos de verdad.
    private lazy var proresAvailable: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prores-probe.mov")
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422HQ,
                                                                       AVVideoWidthKey: 3840, AVVideoHeightKey: 2160])
        guard w.canAdd(i) else { return false }
        w.add(i)
        let ok = w.startWriting()
        if ok { w.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
        return ok
    }()

    private var writerCodec: AVVideoCodecType {
        switch videoQuality {
        case .prores: return .proRes422HQ
        case .hdr: return .hevc
        case .standard: return appleLog || codec == .hevc ? .hevc : .h264
        }
    }

    /// Bits por segundo objetivo (por encima de lo que propone iOS por defecto).
    private func targetBitrate() -> Double {
        let pixelsPerSecond = Double(resolution.width) * Double(resolution.height) * Double(fps)
        let bitsPerPixel: Double
        switch writerCodec {
        case .proRes422HQ: bitsPerPixel = 2.84          // ~707 Mbps en 4K30 (dato de Apple)
        case .h264: bitsPerPixel = 0.20
        default: bitsPerPixel = tenBit ? 0.16 : 0.12    // HEVC: ~40 / ~30 Mbps en 4K30
        }
        let bps = pixelsPerSecond * bitsPerPixel
        return writerCodec == .proRes422HQ ? bps : min(bps, 160_000_000)
    }

    private func applyConnectionSettings() {
        guard let conn = videoOutput.connection(with: .video) else { return }
        let angle: CGFloat = orientation == .landscape ? 0 : 90
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        if conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = (kind == .front)
        }
        if conn.isVideoStabilizationSupported {
            let modes: [AVCaptureVideoStabilizationMode] = stabilization ? [.cinematicExtended, .cinematic, .standard] : [.off]
            let format = device?.activeFormat
            conn.preferredVideoStabilizationMode = modes.first { format?.isVideoStabilizationModeSupported($0) ?? false } ?? (stabilization ? .auto : .off)
        }
    }

    // MARK: Comandos

    func handle(_ command: Command) {
        sessionQueue.async { [self] in
            apply(command)
            if Self.isSetting(command) { saveSettings() }
            notify()
        }
    }

    // MARK: Ajustes guardados

    private static let settingsKey = "savedSettings"

    private static func isSetting(_ c: Command) -> Bool {
        switch c {
        case .setCamera, .setFormat, .setOrientation, .setCodec, .setVideoQuality, .setAppleLog, .setZoom, .setFocus, .setExposure, .setBias,
             .setWhiteBalance, .setStabilization, .setAperture, .setAudioInput: return true
        default: return false
        }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(buildState()) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    /// Reaplica la última configuración usada (sessionQueue, con la sesión ya en marcha).
    private func restoreSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let s = try? JSONDecoder().decode(CameraState.self, from: data) else { return }
        if availableCameras().contains(s.camera) { apply(.setCamera(s.camera)) }
        apply(.setFormat(s.resolution, fps: s.fps))
        apply(.setOrientation(s.orientation))
        apply(.setCodec(s.codec))
        if s.videoQuality != .standard { apply(.setVideoQuality(s.videoQuality)) }
        if s.appleLog { apply(.setAppleLog(true)) }
        apply(.setStabilization(s.stabilization))
        apply(.setZoom(s.zoom))
        if s.cinematicActive { apply(.setAperture(s.aperture)) }
        if !s.focusAuto { apply(.setFocus(auto: false, lens: s.lensPosition)) }
        if !s.exposureAuto { apply(.setExposure(auto: false, iso: s.iso, shutter: s.shutter)) }
        else if s.bias != 0 { apply(.setBias(s.bias)) }
        if !s.whiteBalanceAuto { apply(.setWhiteBalance(auto: false, temperature: s.temperature)) }
        if let mic = s.audioInput, audioInputs().contains(where: { $0.id == mic }) { apply(.setAudioInput(mic)) }
    }

    private func apply(_ command: Command) {
            switch command {
            case .hello, .listRecordings, .downloadRecording, .deleteRecording, .goodbye: break
            case .setCamera(let k):
                guard k != kind else { break }
                guard !isRecording else { emitError("Para cambiar de cámara, para antes la grabación."); break }
                session.beginConfiguration()
                if !switchInput(to: k) { emitError("Esa cámara no está disponible.") }
                session.commitConfiguration()
            case .setFormat(let res, let f):
                guard !isRecording else { emitError("Para cambiar el formato, para antes la grabación."); break }
                resolution = res
                fps = f
                if let dev = device, !supportedFPS(dev, res).contains(f) { fps = supportedFPS(dev, res).filter { $0 <= 30 }.last ?? 30 }
                session.beginConfiguration()
                applyFormat()
                applyCinematic()
                applyConnectionSettings()
                session.commitConfiguration()
            case .setOrientation(let o):
                guard !isRecording else { emitError("Para cambiar la orientación, para antes la grabación."); break }
                orientation = o
                applyConnectionSettings()
            case .setCodec(let c):
                guard !isRecording else { break }
                codec = c
            case .setVideoQuality(let q):
                guard !isRecording else { emitError("Para cambiar la calidad, para antes la grabación."); break }
                if q == .prores, !proresAvailable { emitError("Este iPhone no puede grabar ProRes desde una app."); break }
                videoQuality = q
                session.beginConfiguration()
                normalizeFormat(); applyFormat(); applyCinematic(); applyConnectionSettings()
                session.commitConfiguration()
            case .setAppleLog(let on):
                guard !isRecording else { emitError("Para cambiar el color, para antes la grabación."); break }
                appleLog = on
                session.beginConfiguration()
                normalizeFormat(); applyFormat(); applyCinematic(); applyConnectionSettings()
                session.commitConfiguration()
            case .setStabilization(let on):
                stabilization = on
                applyConnectionSettings()
            case .setZoom(let z):
                configure { dev in
                    dev.videoZoomFactor = CGFloat(z).clamped(self.minZoom(dev), self.maxZoom(dev))
                }
            case .setAperture(let f):
                guard !isRecording else { emitError("La apertura se ajusta antes de grabar."); break }
                guard let input = videoInput, input.isCinematicVideoCaptureEnabled, let fmt = device?.activeFormat,
                      fmt.minSimulatedAperture > 0 else { break }
                input.simulatedAperture = f.clamped(fmt.minSimulatedAperture, fmt.maxSimulatedAperture)
            case .focusAt(let x, let y):
                focus(atImagePoint: CGPoint(x: x, y: y))
            case .setFocus(let auto, let lens):
                guard !(videoInput?.isCinematicVideoCaptureEnabled ?? false) else { break }
                configure { dev in
                    if auto {
                        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                    } else if dev.isLockingFocusWithCustomLensPositionSupported {
                        dev.setFocusModeLocked(lensPosition: lens.clamped(0, 1))
                    }
                }
            case .setExposure(let auto, let iso, let shutter):
                configure { dev in
                    if auto {
                        dev.exposureMode = .continuousAutoExposure
                    } else if dev.isExposureModeSupported(.custom) {
                        let f = dev.activeFormat
                        let maxS = min(f.maxExposureDuration.seconds, 1.0 / Double(self.fps))
                        let s = shutter.clamped(f.minExposureDuration.seconds, maxS)
                        dev.setExposureModeCustom(duration: CMTime(seconds: s, preferredTimescale: 1_000_000),
                                                  iso: iso.clamped(f.minISO, f.maxISO))
                    }
                }
            case .setBias(let b):
                configure { dev in dev.setExposureTargetBias(b.clamped(dev.minExposureTargetBias, dev.maxExposureTargetBias)) }
            case .setWhiteBalance(let auto, let temp):
                configure { dev in
                    if auto {
                        dev.whiteBalanceMode = .continuousAutoWhiteBalance
                    } else if dev.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                        var g = dev.deviceWhiteBalanceGains(for: .init(temperature: temp, tint: 0))
                        let m = dev.maxWhiteBalanceGain
                        g.redGain = g.redGain.clamped(1, m)
                        g.greenGain = g.greenGain.clamped(1, m)
                        g.blueGain = g.blueGain.clamped(1, m)
                        dev.setWhiteBalanceModeLocked(with: g)
                    }
                }
            case .setTorch(let level):
                configure { dev in
                    guard dev.hasTorch else { return }
                    if level <= 0.01 { dev.torchMode = .off }
                    else { try? dev.setTorchModeOn(level: min(level, AVCaptureDevice.maxAvailableTorchLevel)) }
                }
            case .setPreview(let on):
                previewEnabled = on
            case .setAudioCodec(let c):
                guard !isRecording else { break }
                audioCodec = c
            case .setSaveToPhotos(let on):
                saveToPhotos = on
            case .setAudioInput(let id):
                guard !isRecording else { emitError("Para cambiar el micro, para antes la grabación."); break }
                selectAudioInput(id)
            case .startRecording:
                startRecording()
            case .stopRecording:
                stopRecording()
            }
    }

    private func maxZoom(_ dev: AVCaptureDevice) -> CGFloat {
        if videoInput?.isCinematicVideoCaptureEnabled == true { return dev.activeFormat.videoMaxZoomFactorForCinematicVideo }
        return min(dev.maxAvailableVideoZoomFactor, 15)
    }

    private func minZoom(_ dev: AVCaptureDevice) -> CGFloat {
        if videoInput?.isCinematicVideoCaptureEnabled == true { return dev.activeFormat.videoMinZoomFactorForCinematicVideo }
        return dev.minAvailableVideoZoomFactor
    }

    /// Punto tocado en la imagen (ya girada/espejada) → coordenadas del sensor.
    private func focus(atImagePoint p: CGPoint) {
        var u = p.x.clamped(0, 1), v = p.y.clamped(0, 1)
        if kind == .front || kind == .cinematicFront { u = 1 - u }
        let sensor = orientation == .landscape ? CGPoint(x: u, y: v) : CGPoint(x: v, y: 1 - u)
        configure { dev in
            if self.videoInput?.isCinematicVideoCaptureEnabled == true {
                dev.setCinematicVideoTrackingFocus(at: sensor, focusMode: .strong)
                return
            }
            if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.continuousAutoFocus) {
                dev.focusPointOfInterest = sensor
                dev.focusMode = .continuousAutoFocus
            }
            if dev.isExposurePointOfInterestSupported, dev.exposureMode != .custom {
                dev.exposurePointOfInterest = sensor
                dev.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func configure(_ block: (AVCaptureDevice) -> Void) {
        guard let dev = device else { return }
        do {
            try dev.lockForConfiguration()
            block(dev)
            dev.unlockForConfiguration()
        } catch {
            emitError(error.localizedDescription)
        }
    }

    private func emitError(_ msg: String) { onEvent?(.error(msg)) }
    private func notify() { onStateChange?() }

    // MARK: Estado

    func currentState(completion: @escaping (CameraState) -> Void) {
        sessionQueue.async { completion(self.buildState()) }
    }

    private func buildState() -> CameraState {
        var s = CameraState()
        s.deviceName = UIDevice.current.name
        s.availableCameras = availableCameras()
        s.camera = kind
        s.resolution = resolution
        s.fps = fps
        s.orientation = orientation
        s.codec = codec
        s.videoQuality = videoQuality
        s.appleLog = appleLog
        s.proresSupported = proresAvailable
        s.megabytesPerMinute = targetBitrate() * 60 / 8 / 1_000_000
        s.stabilization = stabilization
        s.previewEnabled = previewEnabled
        s.audioInputs = audioInputs()
        s.audioInput = currentAudioInputID()
        s.audioCodec = audioCodec
        if !isRecording { updateAudioMode() }   // por si el micro cambió durante una grabación
        s.audioFormat = audioFormatText()
        s.saveToPhotos = saveToPhotos
        if let dev = device {
            s.supportedResolutions = supportedResolutions(dev)
            s.hdrSupported = capability(dev, [.HLG_BT2020])
            s.logSupported = capability(dev, [.appleLog2, .appleLog])
            s.supportedFPS = supportedFPS(dev, resolution)
            s.zoom = Double(dev.videoZoomFactor)
            s.minZoom = Double(minZoom(dev))
            s.maxZoom = Double(maxZoom(dev))
            let cine = videoInput?.isCinematicVideoCaptureEnabled ?? false
            s.cinematicActive = cine
            if cine, let input = videoInput {
                s.aperture = input.simulatedAperture
                s.minAperture = dev.activeFormat.minSimulatedAperture
                s.maxAperture = dev.activeFormat.maxSimulatedAperture
            }
            s.focusSupported = dev.isLockingFocusWithCustomLensPositionSupported && !cine
            s.focusAuto = dev.focusMode != .locked
            s.lensPosition = dev.lensPosition
            let f = dev.activeFormat
            s.exposureAuto = dev.exposureMode != .custom
            s.iso = dev.iso
            s.minISO = f.minISO
            s.maxISO = f.maxISO
            s.shutter = dev.exposureDuration.seconds
            s.minShutter = f.minExposureDuration.seconds
            s.maxShutter = min(f.maxExposureDuration.seconds, 1.0 / Double(fps))
            s.bias = dev.exposureTargetBias
            s.minBias = max(dev.minExposureTargetBias, -4)
            s.maxBias = min(dev.maxExposureTargetBias, 4)
            s.whiteBalanceAuto = dev.whiteBalanceMode != .locked
            // Esta llamada lanza una excepción si las ganancias están fuera de rango (p. ej. cámara pausada).
            var g = dev.deviceWhiteBalanceGains
            let m = dev.maxWhiteBalanceGain
            if g.redGain >= 1, g.greenGain >= 1, g.blueGain >= 1, m >= 1 {
                g.redGain = min(g.redGain, m); g.greenGain = min(g.greenGain, m); g.blueGain = min(g.blueGain, m)
                s.temperature = dev.temperatureAndTintValues(for: g).temperature.clamped(2000, 10000)
            }
            s.hasTorch = dev.hasTorch
            s.torch = dev.torchMode == .on ? dev.torchLevel : 0
        }
        if let start = recordingStart {
            s.recording = true
            s.recordingSeconds = Date().timeIntervalSince(start)
        }
        s.battery = UIDevice.current.batteryLevel
        let home = URL(fileURLWithPath: NSHomeDirectory())
        s.freeBytes = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return s
    }

    // MARK: Grabación

    private func startRecording() {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CamRemote-\(UUID().uuidString).mov")
        let codecType = writerCodec
        // iOS lanza una excepción si pedimos ajustes recomendados para un códec que no anuncia
        // (pasa con ProRes y con HEVC en Apple Log): en ese caso los construimos nosotros.
        let announced = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov).contains(codecType)
        let recommended = announced ? videoOutput.recommendedVideoSettings(forVideoCodecType: codecType, assetWriterOutputFileType: .mov) : nil
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov),
              var vSettings = recommended ?? manualVideoSettings(codecType) else {
            emitError("No se pudo preparar la grabación con \(videoQuality.label).")
            return
        }
        vSettings[AVVideoCodecKey] = codecType
        if codecType != .proRes422HQ {
            // Más calidad que la propuesta por iOS y perfil de 10 bits para HDR/Log.
            var comp = vSettings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            comp[AVVideoAverageBitRateKey] = targetBitrate()
            // iOS añade un suelo de calidad (QP mín. 15) y deja quedarse corto de tasa: lo quitamos
            // para que use toda la tasa objetivo, también en escenas fáciles.
            comp.removeValue(forKey: "RelaxAverageBitRateTarget")
            comp.removeValue(forKey: "MinAllowedFrameQP")
            if codecType == .hevc, tenBit { comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
            vSettings[AVVideoCompressionPropertiesKey] = comp
        }
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = true
        guard w.canAdd(vIn) else { emitError("Formato de vídeo no compatible."); return }
        w.add(vIn)

        var aIn: AVAssetWriterInput?
        if let aSettings = audioWriterSettings() {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            input.expectsMediaDataInRealTime = true
            if w.canAdd(input) { w.add(input); aIn = input }
        }
        recordingStart = Date()
        mediaQueue.sync {
            writer = w
            writerVideo = vIn
            writerAudio = aIn
            writerStarted = false
        }
    }

    /// Ajustes de vídeo hechos a mano: tamaño real de los fotogramas y etiquetas de color correctas.
    private func manualVideoSettings(_ codec: AVVideoCodecType) -> [String: Any]? {
        let size = mediaQueue.sync { lastVideoSize }
        guard size.width > 0 else { return nil }
        var s: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        switch device?.activeColorSpace {
        case .HLG_BT2020?:
            s[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                           AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                                           AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        case .P3_D65?:
            s[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                                           AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                           AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        case .sRGB?:
            s[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                           AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                           AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        default:
            break   // Apple Log: las etiquetas Log viajan en los propios fotogramas
        }
        return s
    }

    /// Ajustes de audio a máxima calidad, con la frecuencia y canales reales del micro.
    private func audioWriterSettings() -> [String: Any]? {
        guard let f = mediaQueue.sync(execute: { lastAudioFormat }),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee else {
            return audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
        }
        let channels = max(1, min(Int(asbd.mChannelsPerFrame), 2))
        let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        switch audioCodec {
        case .pcm:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false, AVChannelLayoutKey: layoutData]
        case .aac:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 1 ? 256_000 : 320_000, AVChannelLayoutKey: layoutData]
        }
    }

    /// Para la grabación (si la hay) y la cámara; `completion` cuando el vídeo ya está guardado.
    func shutdown(completion: @escaping () -> Void) {
        sessionQueue.async { [self] in
            let finish = { [self] in
                sessionQueue.async { self.session.stopRunning(); completion() }
            }
            if isRecording { stopRecording(done: finish) } else { finish() }
        }
    }

    private func stopRecording(done: (() -> Void)? = nil) {
        guard isRecording else { done?(); return }
        let seconds = Date().timeIntervalSince(recordingStart ?? Date())
        recordingStart = nil
        mediaQueue.async { [self] in
            guard let w = writer else { done?(); return }
            writer = nil
            let started = writerStarted
            writerVideo?.markAsFinished()
            writerAudio?.markAsFinished()
            writerVideo = nil
            writerAudio = nil
            guard started else { w.cancelWriting(); done?(); return }
            w.finishWriting { [self] in
                let url = w.outputURL
                guard w.status == .completed else {
                    emitError("La grabación falló: \(w.error?.localizedDescription ?? "error desconocido")")
                    done?()
                    return
                }
                let stored: URL
                do { stored = try library.store(url, date: Date().addingTimeInterval(-seconds)) }
                catch { emitError("No se pudo guardar el vídeo: \(error.localizedDescription)"); done?(); return }
                onSaved?(stored.lastPathComponent)
                onEvent?(.recordingSaved(seconds: seconds))
                notify()
                // Copia opcional en Fotos (añadir no pide confirmación; borrar de Fotos sí).
                guard sessionQueue.sync(execute: { saveToPhotos }) else { done?(); return }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: stored, options: nil)
                }) { ok, error in
                    if !ok { self.emitError("No se pudo copiar a Fotos: \(error?.localizedDescription ?? "")") }
                    done?()
                }
            }
        }
    }

    // MARK: Vista previa

    private func makePreview(from buffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard previewEnabled, !previewBusy, onPreviewFrame != nil, now - lastPreview >= 1 / previewFPS else { return }
        previewBusy = true
        lastPreview = now
        previewQueue.async { [self] in
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = 640 / max(image.extent.width, image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let data = ciContext.jpegRepresentation(of: scaled, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.55])
            if let data { onPreviewFrame?(data) } else { previewSent() }
        }
    }

    /// El servidor la llama cuando el último frame ya salió por la red (control de flujo).
    func previewSent() { mediaQueue.async { self.previewBusy = false } }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                lastVideoSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
                makePreview(from: pb)
            }
            guard let w = writer, let vIn = writerVideo else { return }
            if !writerStarted {
                guard w.startWriting() else {
                    // P. ej. ProRes a una velocidad que el iPhone no puede escribir.
                    writer = nil; writerVideo = nil; writerAudio = nil
                    emitError("No se pudo empezar a grabar: \(w.error?.localizedDescription ?? "formato no compatible")")
                    sessionQueue.async { self.recordingStart = nil; self.notify() }
                    return
                }
                w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                writerStarted = true
            }
            if w.status == .writing, vIn.isReadyForMoreMediaData { vIn.append(sampleBuffer) }
        } else if output === audioOutput {
            if let ch = connection.audioChannels.first { audioLevel = ch.averagePowerLevel }
            lastAudioFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
            guard writerStarted, let w = writer, w.status == .writing, let aIn = writerAudio, aIn.isReadyForMoreMediaData else { return }
            aIn.append(sampleBuffer)
        }
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
