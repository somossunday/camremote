import AVKit
import SwiftUI

/// Ventana flotante (PiP de videollamada). iOS solo deja seguir usando la cámara
/// fuera de la app a las apps de videollamada que muestran esta ventana; así
/// CamRemote sigue grabando y obedeciendo al Mac aunque abras otra app.
final class BackgroundPiP: NSObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?
    private var host: UIHostingController<PiPStatusView>?

    func attach(to sourceView: UIView, server: CameraServer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let callVC = AVPictureInPictureVideoCallViewController()
        callVC.preferredContentSize = CGSize(width: 320, height: 140)

        let hosting = UIHostingController(rootView: PiPStatusView(server: server))
        hosting.view.backgroundColor = .black
        hosting.view.frame = callVC.view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        callVC.addChild(hosting)
        callVC.view.addSubview(hosting.view)
        hosting.didMove(toParent: callVC)
        host = hosting

        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: sourceView, contentViewController: callVC)
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true   // al salir de la app
        pip.delegate = self
        controller = pip
    }
}

struct PiPStatusView: View {
    @ObservedObject var server: CameraServer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.recording ? "record.circle.fill" : "video.fill")
                .font(.system(size: 34))
                .foregroundStyle(server.recording ? .red : .white)
            VStack(alignment: .leading, spacing: 4) {
                Text(server.recording ? "Grabando" : "CamRemote activo").font(.headline)
                Text(server.connectedClients.isEmpty ? "Esperando al Mac" : "Controlado desde \(server.connectedClients.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}
