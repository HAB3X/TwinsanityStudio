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
        // On-demand rendering: this asset is static the overwhelming
        // majority of the time (no camera drag, no animation frame
        // change), so a continuous 60fps redraw loop burns a full render
        // pass a second time every frame for nothing — especially wasteful
        // now that `CompositePreviewView` can have several of these
        // embedded inline at once. Redraws are triggered explicitly instead
        // — by mouse interaction (above) and by `updateNSView` below, which
        // SwiftUI calls whenever anything this view depends on changes.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.needsDisplay = true
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
        // Also covers state that lives outside this view entirely (e.g.
        // `ModelViewerWindow`'s skeleton-overlay toggle, which mutates the
        // renderer directly) — any SwiftUI state change that reaches this
        // node's `body` re-evaluation lands here, so one redraw per actual
        // change is enough without polling every frame.
        nsView.needsDisplay = true
    }
}
