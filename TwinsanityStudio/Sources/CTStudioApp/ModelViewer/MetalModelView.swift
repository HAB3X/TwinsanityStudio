import SwiftUI
import MetalKit
import CTModels

/// Common orbit-camera surface both `ModelViewerRenderer` and
/// `LevelViewerRenderer` implement, so `InteractiveMTKView`/`MetalModelView`
/// can drive either without knowing which one they're holding.
protocol OrbitCameraRenderer: AnyObject, MTKViewDelegate {
    var device: MTLDevice { get }
    var yaw: Float { get set }
    var pitch: Float { get set }
    var distanceMultiplier: Float { get set }
}

extension ModelViewerRenderer: OrbitCameraRenderer {}
extension LevelViewerRenderer: OrbitCameraRenderer {}

/// `MTKView` subclass that turns mouse drag into orbit and scroll into zoom.
/// Kept as a thin, dumb input adapter — all the actual camera math lives on
/// the renderer, this just forwards deltas to it.
final class InteractiveMTKView: MTKView {
    var renderer: OrbitCameraRenderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        renderer.yaw += Float(event.deltaX) * 0.01
        renderer.pitch = max(-1.5, min(1.5, renderer.pitch + Float(event.deltaY) * 0.01))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        let delta = Float(event.scrollingDeltaY) * 0.01
        renderer.distanceMultiplier = max(0.3, min(20, renderer.distanceMultiplier - delta))
        needsDisplay = true
    }
}

struct MetalModelView: NSViewRepresentable {
    let renderer: OrbitCameraRenderer

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0.07, 0.07, 0.09, 1)
        // Continuous, throttled rendering. This was briefly switched to
        // pure on-demand rendering (isPaused = true + enableSetNeedsDisplay,
        // redrawing only on setNeedsDisplay()) to cut idle GPU cost — but
        // that makes the very first frame depend on `needsDisplay = true`
        // landing *after* this view is actually attached to a window with
        // a non-zero drawable size, which isn't guaranteed to happen before
        // AppKit would otherwise have drawn it, and produced a viewport
        // that stayed blank until some other event forced a redraw. A
        // low-but-nonzero frame rate keeps the original idle-cost win
        // (throttled well below a full 60fps loop) without depending on
        // exact invalidation timing — the display link will always paint
        // the first frame and every frame after, whether or not a
        // setNeedsDisplay() call actually landed.
        view.preferredFramesPerSecond = 20
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        // The composite preview swaps in a freshly-uploaded renderer per
        // asset (see `CompositePreviewView`) while reusing this same
        // underlying `NSView` — without re-pointing `renderer`/`delegate`
        // here, the view would keep drawing whatever asset it first showed.
        if nsView.renderer !== renderer {
            nsView.renderer = renderer
            nsView.delegate = renderer
        }
    }
}
