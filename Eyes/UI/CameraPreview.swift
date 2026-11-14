import AVFoundation
import SwiftUI

/// Live camera preview. Fills the view (cropping the frame), matching `DetectionOverlay`'s mapping.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Flips to true once frames flow; triggers an update so the preview connection can be rotated.
    let ready: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.applyRotation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyRotation()
        }

        func applyRotation() {
            guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) else { return }
            if connection.videoRotationAngle != 90 { connection.videoRotationAngle = 90 }
        }
    }
}
