import AVFoundation
import SwiftUI

@main
struct CamRemoteCamApp: App {
    private let camera: CameraController
    private let pip = BackgroundPiP()
    @StateObject private var server: CameraServer

    init() {
        let camera = CameraController()
        self.camera = camera
        _server = StateObject(wrappedValue: CameraServer(camera: camera))
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen(camera: camera, server: server, pip: pip)
                .onAppear {
                    camera.requestPermissionsAndStart()
                    server.start()
                }
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct CameraScreen: View {
    let camera: CameraController
    @ObservedObject var server: CameraServer
    let pip: BackgroundPiP

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(session: camera.session) { view in pip.attach(to: view, server: server) }.ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(server.status, systemImage: server.connectedClients.isEmpty ? "wifi" : "macbook")
                            .font(.subheadline.weight(.semibold))
                        Text("PIN  \(server.pin)")
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    Spacer()
                    if server.recording {
                        Label("REC", systemImage: "circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.red, in: Capsule())
                    }
                }
                Spacer()
                Button(action: server.toggleRecording) {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                        RoundedRectangle(cornerRadius: server.recording ? 6 : 31)
                            .fill(.red)
                            .frame(width: server.recording ? 30 : 62, height: server.recording ? 30 : 62)
                    }
                    .animation(.easeInOut(duration: 0.2), value: server.recording)
                }
                .accessibilityLabel(server.recording ? "Parar grabación" : "Grabar")
            }
            .padding()
            .foregroundStyle(.white)
        }
    }
}

/// Vista previa local en el iPhone.
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var onCreate: (UIView) -> Void = { _ in }

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            let angle: CGFloat
            switch window?.windowScene?.effectiveGeometry.interfaceOrientation {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        DispatchQueue.main.async { onCreate(v) }
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}
}
