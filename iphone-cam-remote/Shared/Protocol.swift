import Foundation
import Network

// MARK: - Descubrimiento

enum CamRemote {
    /// Servicio Bonjour que anuncia el iPhone y busca el Mac.
    static let serviceType = "_camremote._tcp"

    /// TCP con peer-to-peer (AWDL) activado: funciona en la misma Wi-Fi
    /// y también sin red común, directamente entre iPhone y Mac.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }
}

// MARK: - Modelo

enum CameraKind: String, Codable, CaseIterable, Identifiable {
    case ultraWide, wide, telephoto, cinematic, front, cinematicFront
    var id: String { rawValue }
    var isCinematic: Bool { self == .cinematic || self == .cinematicFront }
    var label: String {
        switch self {
        case .ultraWide: return "Gran angular 0,5×"
        case .wide: return "Principal 1×"
        case .telephoto: return "Teleobjetivo"
        case .cinematic: return "Modo Cine"
        case .front: return "Frontal"
        case .cinematicFront: return "Modo Cine frontal"
        }
    }
}

enum Resolution: String, Codable, CaseIterable, Identifiable {
    case hd720, hd1080, uhd4K
    var id: String { rawValue }
    var width: Int32 { switch self { case .hd720: return 1280; case .hd1080: return 1920; case .uhd4K: return 3840 } }
    var height: Int32 { switch self { case .hd720: return 720; case .hd1080: return 1080; case .uhd4K: return 2160 } }
    var label: String { switch self { case .hd720: return "720p"; case .hd1080: return "1080p"; case .uhd4K: return "4K" } }
}

enum Orientation: String, Codable, CaseIterable, Identifiable {
    case landscape, portrait
    var id: String { rawValue }
    var label: String { self == .landscape ? "Horizontal" : "Vertical" }
}

enum AudioCodec: String, Codable, CaseIterable, Identifiable {
    case pcm, aac
    var id: String { rawValue }
    var label: String { self == .pcm ? "Sin pérdida (PCM 24 bits)" : "AAC 256 kbps" }
}

enum VideoQuality: String, Codable, CaseIterable, Identifiable {
    case standard, hdr, prores
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Estándar"
        case .hdr: return "HDR"
        case .prores: return "ProRes"
        }
    }
    var detail: String {
        switch self {
        case .standard: return "8 bits, color normal. Archivos ligeros."
        case .hdr: return "HEVC 10 bits HDR (HLG), como la app Cámara."
        case .prores: return "ProRes 422 HQ 10 bits HDR. Máxima calidad para editar; ocupa muchísimo."
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}

struct AudioInput: Codable, Hashable, Identifiable {
    var id: String      // uid del puerto [+ "|" + id de la fuente]
    var name: String
}

struct CameraState: Codable, Equatable {
    var deviceName: String = ""
    var availableCameras: [CameraKind] = []
    var camera: CameraKind = .wide

    var resolution: Resolution = .hd1080
    var fps: Int = 30
    var supportedResolutions: [Resolution] = []
    var supportedFPS: [Int] = []
    var orientation: Orientation = .landscape
    var codec: VideoCodec = .hevc
    var videoQuality: VideoQuality = .standard
    var appleLog = false
    var hdrSupported = false
    var logSupported = false
    var proresSupported = false
    var megabytesPerMinute: Double = 0   // estimación del tamaño del vídeo

    var zoom: Double = 1
    var minZoom: Double = 1
    var maxZoom: Double = 1

    var focusSupported = false
    var focusAuto = true
    var lensPosition: Float = 0.5

    var exposureAuto = true
    var iso: Float = 100
    var minISO: Float = 50
    var maxISO: Float = 1600
    var shutter: Double = 1.0 / 60   // segundos
    var minShutter: Double = 1.0 / 8000
    var maxShutter: Double = 1.0 / 30
    var bias: Float = 0
    var minBias: Float = -2
    var maxBias: Float = 2

    var whiteBalanceAuto = true
    var temperature: Float = 5000

    var hasTorch = false
    var torch: Float = 0

    var stabilization = true

    var cinematicActive = false
    var aperture: Float = 2.8         // f/ simulado (menor = más desenfoque)
    var minAperture: Float = 0
    var maxAperture: Float = 0

    var audioInputs: [AudioInput] = []
    var audioInput: String?
    var audioCodec: AudioCodec = .pcm
    var audioFormat = ""              // p. ej. "48 kHz · mono · sin procesado"
    var saveToPhotos = false

    var recording = false
    var recordingSeconds: Double = 0

    var battery: Float = -1          // 0…1, -1 si desconocido
    var freeBytes: Int64 = 0
    var previewEnabled = true
}

struct RecordingInfo: Codable, Identifiable, Equatable {
    var id: String            // localIdentifier del vídeo en Fotos
    var date: Date
    var duration: Double
    var width: Int
    var height: Int
    var bytes: Int64
    var filename: String
    var thumbnail: Data?      // JPEG pequeño
}

/// Mac → iPhone
enum Command: Codable {
    case hello(pin: String, client: String)
    case setCamera(CameraKind)
    case setFormat(Resolution, fps: Int)
    case setOrientation(Orientation)
    case setCodec(VideoCodec)
    case setVideoQuality(VideoQuality)
    case setAppleLog(Bool)
    case setZoom(Double)
    case setFocus(auto: Bool, lens: Float)
    case setExposure(auto: Bool, iso: Float, shutter: Double)
    case setBias(Float)
    case setWhiteBalance(auto: Bool, temperature: Float)
    case setTorch(Float)
    case setStabilization(Bool)
    case setAperture(Float)
    case focusAt(x: Double, y: Double)   // punto normalizado 0…1 en la imagen de la vista previa
    case setPreview(Bool)
    case setAudioInput(String)
    case setAudioCodec(AudioCodec)
    case setSaveToPhotos(Bool)
    case startRecording
    case stopRecording
    case listRecordings
    case downloadRecording(id: String)
    case deleteRecording(id: String)
    case goodbye(closeApp: Bool)   // el Mac sale de la app
}

/// iPhone → Mac
enum ServerMessage: Codable {
    case welcome(deviceName: String)
    case rejected(reason: String)
    case state(CameraState)
    case error(String)
    case recordingSaved(seconds: Double)
    case audioLevel(Float)   // dBFS, -160…0
    case recordings([RecordingInfo])
    case downloadStart(id: String, bytes: Int64)
    case downloadEnd(id: String)
    case downloadFailed(id: String, reason: String)
}

// MARK: - Mensajes enmarcados sobre TCP
// [1 byte tipo][4 bytes longitud big-endian][payload]

enum FrameKind: UInt8 { case json = 0, jpeg = 1, fileChunk = 2 }

final class FramedConnection {
    let connection: NWConnection
    var onMessage: ((FrameKind, Data) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?
    private static let maxPayload = 16 * 1024 * 1024

    init(_ connection: NWConnection) { self.connection = connection }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func cancel() { connection.cancel() }

    func send(_ kind: FrameKind, _ payload: Data, completion: (() -> Void)? = nil) {
        var header = Data([kind.rawValue])
        var len = UInt32(payload.count).bigEndian
        header.append(Data(bytes: &len, count: 4))
        connection.send(content: header + payload, completion: .contentProcessed { _ in completion?() })
    }

    func sendJSON<T: Encodable>(_ value: T, completion: (() -> Void)? = nil) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(.json, data, completion: completion)
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == 5, error == nil else {
                if isComplete || error != nil { self.connection.cancel() }
                return
            }
            let kind = FrameKind(rawValue: data[data.startIndex]) ?? .json
            let len = data.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard len <= Self.maxPayload else { self.connection.cancel(); return }
            if len == 0 {
                self.onMessage?(kind, Data())
                self.receiveHeader()
            } else {
                self.receiveBody(kind: kind, length: Int(len))
            }
        }
    }

    private func receiveBody(kind: FrameKind, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else { self.connection.cancel(); return }
            self.onMessage?(kind, data)
            self.receiveHeader()
        }
    }
}
