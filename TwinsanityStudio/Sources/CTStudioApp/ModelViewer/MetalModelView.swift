import SwiftUI
import MetalKit
import simd
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

/// "The Forge Palette" (Part 4C): implemented only by `LevelViewerRenderer`
/// — a `mouseDown` while `pendingPlacementObjectID` is armed places a new
/// object instead of orbiting or picking. Checked first in
/// `InteractiveMTKView.mouseDown`, ahead of the gizmo-grab/pick checks,
/// since placement mode takes over the click entirely.
protocol PlacementInteractiveRenderer: OrbitCameraRenderer {
    var pendingPlacementObjectID: UInt16? { get }
    @discardableResult
    func placeObject(at screenPoint: CGPoint, viewSize: CGSize) -> Int?
}

extension LevelViewerRenderer: PlacementInteractiveRenderer {}

/// "Free Camera System in Chunk Editor": implemented only by
/// `LevelViewerRenderer` — the single-model viewer has no use for a
/// flying camera over one small asset. Checked via `as?` the same way
/// `PlacementInteractiveRenderer` is.
protocol FreeCameraRenderer: OrbitCameraRenderer {
    var isFreeCameraMode: Bool { get set }
    var freeCameraSpeed: Float { get set }
    var freeCameraInputDirection: SIMD3<Float> { get set }
    func rotateFreeCameraLook(yawDelta: Float, pitchDelta: Float)
}

extension LevelViewerRenderer: FreeCameraRenderer {}

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
    /// "Click any rendered element to select it" (Level Editor overhaul):
    /// fired with the picked object's index when a `mouseDown` didn't grab
    /// a gizmo handle but did land on/near a visible object — see
    /// `GizmoInteractiveRenderer.pickObject`.
    var onObjectPicked: ((Int) -> Void)?
    /// "The Forge Palette" (Part 4C): fired with the newly spawned object's
    /// index right after a placement-mode click actually placed something
    /// — lets the SwiftUI side select it and register the matching Undo
    /// step, same reasoning as `onObjectPicked`.
    var onObjectPlaced: ((Int) -> Void)?

    /// Non-nil for the duration of a drag that grabbed a gizmo arrow on
    /// `mouseDown` — while set, `mouseDragged` moves the selected object
    /// along that axis instead of orbiting the camera.
    private var draggingGizmoAxis: GizmoAxis?
    /// "Broken Gizmos" fix: the cursor's own view-point location as of the
    /// last gizmo-drag event. `NSEvent.deltaX`/`deltaY` (used directly
    /// before this fix) are the *raw, unaccelerated hardware* mouse
    /// deltas — under macOS's pointer-acceleration curve (or on a
    /// trackpad) those numbers don't match how far the cursor actually
    /// moved on screen, so a gizmo driven straight from them visibly
    /// drifts out of alignment with the cursor mid-drag, exactly the
    /// "not smooth, not perfectly aligned with the camera" symptom. This
    /// tracks the real cursor position instead — `convert(event.
    /// locationInWindow, from: nil)`, the same call `mouseDown` already
    /// uses for its (already-correct) gizmo hit test — and diffs
    /// consecutive events, so the gizmo tracks the cursor 1:1 regardless
    /// of acceleration/input device.
    private var lastGizmoDragLocation: CGPoint?

    /// "Free Camera System": currently-held WASD/EQ keys — tracked across
    /// `keyDown`/`keyUp` rather than acted on per-keystroke, so holding a
    /// key produces continuous movement (integrated once per frame in
    /// the renderer's own `draw(in:)`) instead of one discrete nudge per
    /// key-repeat event.
    private var heldMovementKeys: Set<String> = []

    override var acceptsFirstResponder: Bool { true }

    /// Clicking away from this view (or the window losing key focus)
    /// doesn't reliably deliver `keyUp` for whatever WASD/EQ keys were
    /// down at the time — without this, a held key could get "stuck,"
    /// leaving the free camera drifting indefinitely after focus moves
    /// elsewhere.
    override func resignFirstResponder() -> Bool {
        if !heldMovementKeys.isEmpty {
            heldMovementKeys.removeAll()
            updateFreeCameraInputDirection()
        }
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        draggingGizmoAxis = nil
        let point = convert(event.locationInWindow, from: nil)

        // "The Forge Palette": an armed placement takes over the click
        // entirely — no gizmo grab, no orbit, no picking, just "put the
        // new object here."
        if let placementRenderer = renderer as? PlacementInteractiveRenderer, placementRenderer.pendingPlacementObjectID != nil {
            if let newIndex = placementRenderer.placeObject(at: point, viewSize: bounds.size) {
                onObjectPlaced?(newIndex)
                needsDisplay = true
            }
            return
        }

        guard let gizmoRenderer = renderer as? GizmoInteractiveRenderer else { return }
        draggingGizmoAxis = gizmoRenderer.gizmoAxis(at: point, viewSize: bounds.size)
        if draggingGizmoAxis != nil {
            lastGizmoDragLocation = point
            onGizmoDragStarted?()
            return
        }
        // No gizmo handle grabbed — try picking whatever's under the click
        // instead, so clicking an object directly selects it even before
        // its own gizmo exists (or for select-only layers like triggers).
        if let picked = gizmoRenderer.pickObject(at: point, viewSize: bounds.size) {
            onObjectPicked?(picked)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = draggingGizmoAxis != nil
        draggingGizmoAxis = nil
        lastGizmoDragLocation = nil
        if wasDragging { onGizmoDragEnded?() }
    }

    /// "F to Focus/Frame" plus W/E/R gizmo-mode switching (QoL sweep) —
    /// the standard 3D-tool convention for translate/rotate/scale. While
    /// the Free Camera is active, WASD/EQ mean movement instead — the two
    /// schemes share letters (W/E already meant translate/rotate mode),
    /// so free-camera mode takes over those keys entirely rather than
    /// trying to make one keystroke serve two conflicting purposes.
    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        if let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode {
            switch key {
            case "w", "a", "s", "d", "e", "q":
                if !event.isARepeat { heldMovementKeys.insert(key) }
                updateFreeCameraInputDirection()
                return
            case "f":
                renderer?.resetView()
                needsDisplay = true
                return
            default:
                break
            }
        }

        var changedMode = false
        switch key {
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

    override func keyUp(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), heldMovementKeys.remove(key) != nil else {
            super.keyUp(with: event)
            return
        }
        updateFreeCameraInputDirection()
    }

    private func updateFreeCameraInputDirection() {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer else { return }
        var direction = SIMD3<Float>(0, 0, 0)
        if heldMovementKeys.contains("w") { direction.z += 1 }
        if heldMovementKeys.contains("s") { direction.z -= 1 }
        if heldMovementKeys.contains("d") { direction.x += 1 }
        if heldMovementKeys.contains("a") { direction.x -= 1 }
        if heldMovementKeys.contains("e") { direction.y += 1 }
        if heldMovementKeys.contains("q") { direction.y -= 1 }
        freeCameraRenderer.freeCameraInputDirection = direction
    }

    /// Right-click-drag look — the Free Camera's own rotation input,
    /// entirely separate from `mouseDragged`'s left-click orbit/gizmo
    /// handling below (which keeps working unchanged; while free-camera
    /// mode is on, `currentViewProjection` simply ignores the orbit
    /// `yaw`/`pitch` it would otherwise mutate).
    override func rightMouseDown(with event: NSEvent) {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode else {
            super.rightMouseDown(with: event)
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode else {
            super.rightMouseDragged(with: event)
            return
        }
        freeCameraRenderer.rotateFreeCameraLook(yawDelta: Float(event.deltaX) * 0.01, pitchDelta: -Float(event.deltaY) * 0.01)
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode else {
            super.rightMouseUp(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let renderer else { return }
        if let axis = draggingGizmoAxis, let gizmoRenderer = renderer as? GizmoInteractiveRenderer {
            // See `lastGizmoDragLocation`'s doc comment: real cursor-point
            // deltas, not raw hardware `event.deltaX/deltaY` — sign
            // convention kept identical to what `event.deltaX/deltaY`
            // would have provided (dx positive = right, dy positive =
            // down) so every downstream gizmo-math sign/negation
            // (`axisProjectedWorldDelta`'s `-viewportDelta.dy`, etc.)
            // stays correct unchanged.
            let point = convert(event.locationInWindow, from: nil)
            let previous = lastGizmoDragLocation ?? point
            let viewportDelta = CGVector(dx: point.x - previous.x, dy: previous.y - point.y)
            lastGizmoDragLocation = point
            gizmoRenderer.dragSelectedObject(axis: axis, viewportDelta: viewportDelta, viewSize: bounds.size)
            needsDisplay = true
            return
        }
        renderer.yaw += Float(event.deltaX) * 0.01
        renderer.pitch += Float(event.deltaY) * 0.01
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let renderer else { return }
        // "Adjustable movement speeds (Scroll Wheel speed adjustment)":
        // while flying, the scroll wheel means "how fast do WASD move me,"
        // not "zoom" — there's no orbit distance to zoom while free-camera
        // mode is active anyway.
        if let freeCameraRenderer = renderer as? FreeCameraRenderer, freeCameraRenderer.isFreeCameraMode {
            let delta = Float(event.scrollingDeltaY) * 0.5
            freeCameraRenderer.freeCameraSpeed = max(1, min(500, freeCameraRenderer.freeCameraSpeed - delta))
            needsDisplay = true
            return
        }
        let delta = Float(event.scrollingDeltaY) * 0.01
        renderer.distanceMultiplier -= delta
        needsDisplay = true
    }
}

struct MetalModelView: NSViewRepresentable {
    let renderer: OrbitCameraRenderer
    var onGizmoDragEnded: (() -> Void)?
    var onGizmoDragStarted: (() -> Void)?
    var onGizmoModeChanged: (() -> Void)?
    var onObjectPicked: ((Int) -> Void)?
    var onObjectPlaced: ((Int) -> Void)?

    func makeNSView(context: Context) -> InteractiveMTKView {
        let view = InteractiveMTKView(frame: .zero, device: renderer.device)
        view.renderer = renderer
        view.onGizmoDragEnded = onGizmoDragEnded
        view.onGizmoDragStarted = onGizmoDragStarted
        view.onGizmoModeChanged = onGizmoModeChanged
        view.onObjectPicked = onObjectPicked
        view.onObjectPlaced = onObjectPlaced
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
        nsView.onObjectPicked = onObjectPicked
        nsView.onObjectPlaced = onObjectPlaced
    }
}
