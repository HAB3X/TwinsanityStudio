import SwiftUI
import CTModels

/// Hosts for the three GPU-heavy viewers (Model/Collision/Level), each
/// backed by a real `Window` scene (see `CTStudioApp`) instead of a
/// `.sheet()`. This is a direct response to the blank-viewport
/// investigation: every Swift-side diagnostic (GPU upload, drawable size,
/// `draw(in:)` actually presenting a committed frame, vertex/texture alpha)
/// came back healthy, which narrows the remaining suspects to something in
/// how macOS composites an `MTKView`'s `CAMetalLayer` specifically within a
/// `.sheet()`'s window — a real, if unconfirmed, class of quirk. A `Window`
/// scene is a completely different AppKit window-hosting path, so this
/// sidesteps that whole class of bug if that's what this is, rather than
/// adding another layer of guesswork on top of the existing diagnostics.
///
/// `workspace`'s existing `modelViewerAsset`/`collisionViewerMesh`/
/// `levelViewerContext` stay the single source of truth exactly as they
/// were for the `.sheet()` versions — every call site that sets them
/// (`ModelsHubView`, `SidebarView`, `RelationalChainView`, ...) is
/// unchanged; only `ContentView` (which already centrally coordinates every
/// presentation) needed to change, opening the matching `Window` when one
/// of these transitions from `nil` to non-`nil`.
struct ModelViewerWindowHost: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let asset = workspace.modelViewerAsset {
                ModelViewerWindow(asset: asset)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.modelViewerAsset = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        // Covers both our own Close button (which nils the state directly)
        // and the window's standard red-traffic-light close (which only
        // tears down this view, so this is the one place that can catch
        // that and keep `workspace` in sync either way).
        .onDisappear { workspace.modelViewerAsset = nil }
        .onChange(of: workspace.modelViewerAsset == nil) { _, isNil in
            if isNil { dismissWindow(id: GPUViewerWindowID.model) }
        }
    }
}

struct CollisionViewerWindowHost: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let mesh = workspace.collisionViewerMesh {
                CollisionViewerWindow(mesh: mesh)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.collisionViewerMesh = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { workspace.collisionViewerMesh = nil }
        .onChange(of: workspace.collisionViewerMesh == nil) { _, isNil in
            if isNil { dismissWindow(id: GPUViewerWindowID.collision) }
        }
    }
}

struct LevelViewerWindowHost: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let context = workspace.levelViewerContext {
                LevelViewerWindow(context: context)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { workspace.levelViewerContext = nil }
                        }
                    }
            } else {
                Color.clear
            }
        }
        .onDisappear { workspace.levelViewerContext = nil }
        .onChange(of: workspace.levelViewerContext == nil) { _, isNil in
            if isNil { dismissWindow(id: GPUViewerWindowID.level) }
        }
    }
}

enum GPUViewerWindowID {
    static let model = "model-viewer"
    static let collision = "collision-viewer"
    static let level = "level-viewer"
}
