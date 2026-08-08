import SwiftUI
import MetalKit
import CTModels

/// `MTKView` subclass that turns mouse drag into orbit and scroll into zoom.
/// Kept as a thin, dumb input adapter — all the actual camera math lives on
/// `ModelViewerRenderer`, this just forwards deltas to it.
final class InteractiveMTKView: MTKView {
    var renderer: ModelViewerRenderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        renderer.yaw += Float(event.deltaX) * 0.01
        renderer.pitch = max(-1.5, min(1.5, renderer.pitch + Float(event.deltaY) * 0.01))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        let delta = Float(event.scrollingDeltaY) * 0.01
        renderer.distanceMultiplier = max(0.3, min(20, renderer.distanceMultiplier - delta))
    }
}

struct MetalModelView: NSViewRepresentable {
    let renderer: ModelViewerRenderer

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {}
}
