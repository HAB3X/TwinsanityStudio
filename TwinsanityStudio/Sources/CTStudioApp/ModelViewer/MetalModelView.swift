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
    /// "F to Focus/Frame" (QoL sweep): resets the orbit angle/distance to a
    /// sensible default. A plain reset, not a per-object fitted bounding
    /// calculation — `LevelViewerRenderer` gets the "orbit around whatever's
    /// selected" part of "focus on selection" for free from its own
    /// `orbitTarget` (see that type), since the look-at point already
    /// follows the current selection; this just un-sticks a wildly zoomed
    /// in/out or spun-around camera back to a readable framing.
    func resetView()
}

extension ModelViewerRenderer: OrbitCameraRenderer {}
extension LevelViewerRenderer: OrbitCameraRenderer {}

/// `MTKView` subclass that turns mouse drag into orbit and scroll into zoom.
/// Kept as a thin, dumb input adapter — all the actual camera math lives on
/// the renderer, this just forwards deltas to it.
final class InteractiveMTKView: MTKView {
    var renderer: OrbitCameraRenderer?
    /// Fired once when a gizmo-arrow drag ends — lets the SwiftUI side
    /// (whose coordinate nudge fields have no other way to observe a plain,
    /// non-`ObservableObject` renderer mutated straight from AppKit mouse
    /// events) resync its display *after* the drag, rather than needing
    /// per-pixel observation of a hot interactive loop.
    var onGizmoDragEnded: (() -> Void)?
    /// Fired once when a gizmo-arrow drag *starts* — lets the SwiftUI side
    /// snapshot the pre-drag position for an Undo step covering the whole
    /// gesture (see `LevelViewerWindow`), rather than one Undo step per
    /// mouse-moved event.
    var onGizmoDragStarted: (() -> Void)?
    /// Fired when the W/E/R hotkeys change `gizmoMode` — the SwiftUI-side
    /// mode picker has no other way to notice a change AppKit's `keyDown`
    /// made directly on the (plain, non-`ObservableObject`) renderer.
    var onGizmoModeChanged: (() -> Void)?

    /// Non-nil for the duration of a drag that grabbed a gizmo arrow on
    /// `mouseDown` — while set, `mouseDragged` moves the selected object
    /// along that axis instead of orbiting the camera.
    private var draggingGizmoAxis: GizmoAxis?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        draggingGizmoAxis = nil
        guard let gizmoRenderer = renderer as? GizmoInteractiveRenderer else { return }
        let point = convert(event.locationInWindow, from: nil)
        draggingGizmoAxis = gizmoRenderer.gizmoAxis(at: point, viewSize: bounds.size)
        if draggingGizmoAxis != nil { onGizmoDragStarted?() }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = draggingGizmoAxis != nil
        draggingGizmoAxis = nil
        if wasDragging { onGizmoDragEnded?() }
    }

    /// "F to Focus/Frame" plus W/E/R gizmo-mode switching (QoL sweep) —
    /// the standard 3D-tool convention for translate/rotate/scale.
    override func keyDown(with event: NSEvent) {
        var changedMode = false
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            renderer?.resetView()
        case "w" where renderer is GizmoInteractiveRenderer:
            (renderer as? GizmoInteractiveRenderer)?.gizmoMode = .translate
            changedMode = true
        case "e" where renderer is GizmoInteractiveRenderer:
            (renderer as? GizmoInteractiveRenderer)?.gizmoMode = .rotate
            changedMode = true
        case "r" where renderer is GizmoInteractiveRenderer:
            (renderer as? GizmoInteractiveRenderer)?.gizmoMode = .scale
            changedMode = true
        default:
            super.keyDown(with: event)
            return
        }
        if changedMode { onGizmoModeChanged?() }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        if let axis = draggingGizmoAxis, let gizmoRenderer = renderer as? GizmoInteractiveRenderer {
            gizmoRenderer.dragSelectedObject(axis: axis, viewportDelta: CGVector(dx: event.deltaX, dy: event.deltaY), viewSize: bounds.size)
            needsDisplay = true
            return
        }
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
    var onGizmoDragEnded: (() -> Void)?
    var onGizmoDragStarted: (() -> Void)?
    var onGizmoModeChanged: (() -> Void)?

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.onGizmoDragEnded = onGizmoDragEnded
        view.onGizmoDragStarted = onGizmoDragStarted
        view.onGizmoModeChanged = onGizmoModeChanged
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
        nsView.onGizmoDragEnded = onGizmoDragEnded
        nsView.onGizmoDragStarted = onGizmoDragStarted
        nsView.onGizmoModeChanged = onGizmoModeChanged
    }
}
