import AVFoundation
import SwiftUI

struct CapturePreviewView: NSViewRepresentable {
    @ObservedObject var model: ScreenCaptureModel

    func makeNSView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        model.previewLayer = view.previewLayer
        return view
    }

    func updateNSView(_ nsView: PreviewContainerView, context: Context) {
        if model.previewLayer !== nsView.previewLayer {
            model.previewLayer = nsView.previewLayer
        }
    }
}

final class PreviewContainerView: NSView {
    let previewLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
