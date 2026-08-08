import SwiftUI
import CTModels

/// The "View Parent / Composite" inline preview (blueprint 2.1/2.3): an
/// embedded, live Metal viewport showing the complete object a selected
/// component (texture/mesh/material/animation) belongs to, right in the
/// inspector — no modal, no extra click, so selecting an isolated texture
/// no longer feels disconnected from what it actually textures.
struct CompositePreviewView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let asset: ResolvedModelAsset

    @State private var renderer: ModelViewerRenderer?
    /// Selected by ID, not by value — `AnimationAsset` doesn't conform to
    /// `Hashable` (nothing else in the codebase has needed it to), and a
    /// `Picker` selection/`tag` needs a `Hashable` type. Same pattern
    /// `ModelViewerWindow`'s own animation list already uses.
    @State private var sandboxAnimationID: UInt32?
    @State private var sandboxFrame: Double = 0
    @State private var sandboxTimer: Timer?
    @State private var sandboxPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            viewport
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            Text(asset.displayName)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text("\(asset.mesh.submeshes.count) submesh(es)")
                Text("· \(asset.mesh.totalVertexCount) verts")
                if asset.skeleton != nil { Text("· rigged") }
                if !asset.availableAnimations.isEmpty { Text("· \(asset.availableAnimations.count) anim(s)") }
                if !asset.isFullyTextured { Text("· missing some textures") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    workspace.modelViewerAsset = asset
                } label: {
                    Label("Open Full Model Viewer", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button {
                    exportGroup()
                } label: {
                    Label("Export as Group…", systemImage: "shippingbox")
                }
                Spacer()
            }

            if asset.skeleton != nil, !asset.availableAnimations.isEmpty {
                Divider()
                animationSandbox
            }
        }
        .onAppear { renderer = ModelViewerRenderer(asset: asset) }
        .onChange(of: asset.id) { _, _ in
            renderer = ModelViewerRenderer(asset: asset)
            stopSandboxPlayback()
            sandboxAnimationID = nil
        }
        .onDisappear { stopSandboxPlayback() }
    }

    private var sandboxAnimation: AnimationAsset? {
        guard let sandboxAnimationID else { return nil }
        return asset.availableAnimations.first { $0.id == sandboxAnimationID }
    }

    /// "Integrated Animation Sandbox": every animation available to this
    /// object, playable directly against the composited preview above.
    private var animationSandbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Animation Sandbox", systemImage: "figure.run")
                .font(.headline)

            Picker("Animation", selection: $sandboxAnimationID) {
                Text("None").tag(UInt32?.none)
                ForEach(asset.availableAnimations.sorted { $0.id < $1.id }) { animation in
                    Text("Animation #\(animation.id) (\(animation.body.totalFrames)f)").tag(Optional(animation.id))
                }
            }
            .labelsHidden()
            .onChange(of: sandboxAnimationID) { _, _ in
                stopSandboxPlayback()
                sandboxFrame = 0
                applySandboxPose()
            }

            if let sandboxAnimation, sandboxAnimation.body.totalFrames > 1 {
                HStack {
                    Button {
                        toggleSandboxPlayback(frameCount: sandboxAnimation.body.totalFrames)
                    } label: {
                        Image(systemName: sandboxPlaying ? "pause.fill" : "play.fill")
                    }
                    Slider(value: $sandboxFrame, in: 0...Double(sandboxAnimation.body.totalFrames - 1), step: 1)
                        .onChange(of: sandboxFrame) { _, _ in applySandboxPose() }
                    Text("\(Int(sandboxFrame))/\(sandboxAnimation.body.totalFrames - 1)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Experimental: joint-channel semantics aren't confirmed against the original engine, so this is an illustrative pose, not a verified deformation — see the Animation record's own inspector for the raw decoded data.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func toggleSandboxPlayback(frameCount: Int) {
        sandboxPlaying.toggle()
        if sandboxPlaying {
            sandboxTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                sandboxFrame = (sandboxFrame + 1).truncatingRemainder(dividingBy: Double(max(1, frameCount)))
                applySandboxPose()
            }
        } else {
            sandboxTimer?.invalidate()
            sandboxTimer = nil
        }
    }

    private func stopSandboxPlayback() {
        sandboxPlaying = false
        sandboxTimer?.invalidate()
        sandboxTimer = nil
    }

    /// Pushes the current sandbox frame's (experimental) joint pose to the
    /// renderer — see `ExperimentalAnimationPose`'s doc comment for exactly
    /// what "experimental" means here.
    private func applySandboxPose() {
        guard let skeleton = asset.skeleton, let sandboxAnimation else {
            renderer?.skeletonJointWorldPositions = []
            return
        }
        renderer?.skeletonJointWorldPositions = ExperimentalAnimationPose.jointSegments(
            skeleton: skeleton,
            track: sandboxAnimation.body,
            frameIndex: min(sandboxAnimation.body.totalFrames - 1, max(0, Int(sandboxFrame)))
        )
    }

    @ViewBuilder
    private var viewport: some View {
        if let renderer, renderer.hasGeometry {
            MetalModelView(renderer: renderer)
        } else if renderer != nil {
            ContentUnavailableView(
                "No Drawable Geometry",
                systemImage: "cube.transparent",
                description: Text("This object resolved but produced no triangles to draw.")
            )
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle")
        }
    }

    private func exportGroup() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this composite object — mesh, textures, and animations — into.") else { return }
        workspace.exportCompleteAsset(asset, to: directory)
    }
}
