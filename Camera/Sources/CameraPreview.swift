import SwiftUI
import AVFoundation

/// NSViewRepresentable that wraps AVCaptureVideoPreviewLayer.
/// Mirror is applied as a horizontal flip (-1 scaleX).
/// The preview layer is added as a sublayer so that its anchorPoint
/// stays at (0.5, 0.5) and transforms operate from the center.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var isMirrored: Bool = false

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.previewLayer.session = session

        let mirrorX: CGFloat = isMirrored ? -1 : 1
        let transform = CGAffineTransform(scaleX: mirrorX, y: 1)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(name: .easeInEaseOut)
        )
        nsView.previewLayer.setAffineTransform(transform)
        CATransaction.commit()
    }
}

final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.masksToBounds = true
        previewLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        previewLayer.bounds = bounds
        CATransaction.commit()
    }
}
