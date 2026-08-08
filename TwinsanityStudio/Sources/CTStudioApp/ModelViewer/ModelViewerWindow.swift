import SwiftUI
import AppKit
import simd
import CTModels
import CTExport

/// The dedicated Model Viewer: a Metal viewport showing the fully resolved
/// (mesh + textures, and skeleton if rigged) asset on the left, and a
/// sidebar on the right with asset info, animation search/playback, and the
/// unified export action.
struct ModelViewerWindow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let asset: ResolvedModelAsset

    @State private var renderer: ModelViewerRenderer?
    @State private var showSkeletonOverlay = false
    @State private var animationSearch = ""
    @State private var selectedAnimation: AnimationAsset?
    @State private var currentFrame: Double = 0
    @State private var playbackTimer: Timer?
    @State private var isPlaying = false
    @State private var hiddenSubmeshIndices: Set<Int> = []

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 320)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { renderer = ModelViewerRenderer(asset: asset) }
        .onDisappear { stopPlayback() }
        .onChange(of: showSkeletonOverlay) { _, _ in updateSkeletonOverlay() }
        .onChange(of: selectedAnimation?.id) { _, _ in updateSkeletonOverlay() }
        .onChange(of: currentFrame) { _, _ in updateSkeletonOverlay() }
    }

    /// Drives the skeleton line overlay: the animated (experimental —
    /// see `ExperimentalAnimationPose`) pose at the current playback frame
    /// when an animation is selected, otherwise the bind pose. Both only
    /// show when the user has opted into the overlay at all.
    private func updateSkeletonOverlay() {
        guard showSkeletonOverlay, let skeleton = asset.skeleton else {
            renderer?.skeletonJointWorldPositions = []
            return
        }
        if let selectedAnimation {
            let frameIndex = min(selectedAnimation.body.totalFrames - 1, max(0, Int(currentFrame)))
            renderer?.skeletonJointWorldPositions = ExperimentalAnimationPose.jointSegments(skeleton: skeleton, track: selectedAnimation.body, frameIndex: frameIndex)
        } else {
            renderer?.skeletonJointWorldPositions = bindPoseSkeletonSegments()
        }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasGeometry {
                // `MetalModelView` wraps an `NSViewRepresentable` `MTKView`,
                // which has no intrinsic content size SwiftUI can infer.
                // `maxWidth/maxHeight: .infinity` alone visibly reserves the
                // space (confirmed — the viewport area isn't collapsed) but
                // still isn't a concrete number for a `.sheet()`'s first
                // layout pass to resolve against, and empirically that's
                // enough for the underlying `MTKView`/`CAMetalLayer` to end
                // up not actually driving pixels even though the area looks
                // right. `CompositePreviewView`'s inline preview — which
                // *does* render correctly — gives its own `MetalModelView` a
                // hard `.frame(height: 320)`; a real min alongside the max
                // is the same fix without hardcoding this one to a fixed
                // size.
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(renderer: renderer)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The asset resolved (mesh + material lookups all
                // succeeded), but every submesh ended up with zero
                // triangles after upload — surface that plainly instead of
                // showing an indistinguishable-from-broken blank canvas.
                ContentUnavailableView(
                    "No Drawable Geometry",
                    systemImage: "cube.transparent",
                    description: Text("This model resolved (\(asset.mesh.submeshes.count) submesh(es)), but none produced any triangles to draw — the source mesh record may be empty or use an unsupported strip layout.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(asset.displayName)
                    .font(.title3.bold())
                    .lineLimit(2)

                infoSection
                Divider()
                componentVisibilitySection
                Divider()
                if asset.skeleton != nil {
                    skeletonSection
                    Divider()
                }
                animationSection
                Divider()
                exportSection
            }
            .padding(16)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Asset Info", systemImage: "info.circle").font(.headline)
            LabeledContent("Submeshes", value: "\(asset.mesh.submeshes.count)")
            LabeledContent("Vertices", value: "\(asset.mesh.totalVertexCount)")
            LabeledContent("Triangles", value: "\(asset.mesh.totalTriangleCount)")
            let texturedCount = asset.submeshMaterials.filter { $0.texture != nil }.count
            LabeledContent("Textured Submeshes", value: "\(texturedCount) / \(asset.submeshMaterials.count)")
            if !asset.isFullyTextured {
                Label("Some submeshes have no resolved texture (missing material/texture link) — shown in white.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "Granular Component Visibility": a checklist of the materials/
    /// textures making up this object — unchecking one hides every submesh
    /// that uses it in the viewport immediately (see
    /// `ModelViewerRenderer.hiddenSubmeshIndices`). Built from the same
    /// `RelationalChain` the inspector's relational-chain panel uses, so
    /// the two stay in agreement about what this object is made of.
    private var componentVisibilitySection: some View {
        let toggleable = RelationalChain(asset: asset).components.filter {
            ($0.kind == .material || $0.kind == .texture) && !$0.submeshIndices.isEmpty
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label("Components", systemImage: "checklist").font(.headline)
            if toggleable.isEmpty {
                Text("No separately toggleable components.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(toggleable) { component in
                    Toggle(component.displayName, isOn: visibilityBinding(for: component))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func visibilityBinding(for component: LinkedComponent) -> Binding<Bool> {
        Binding(
            get: { !component.submeshIndices.contains(where: hiddenSubmeshIndices.contains) },
            set: { isVisible in
                if isVisible {
                    hiddenSubmeshIndices.subtract(component.submeshIndices)
                } else {
                    hiddenSubmeshIndices.formUnion(component.submeshIndices)
                }
                renderer?.hiddenSubmeshIndices = hiddenSubmeshIndices
            }
        )
    }

    private var skeletonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Skeleton", systemImage: "figure.stand").font(.headline)
            if let skeleton = asset.skeleton {
                LabeledContent("Joints", value: "\(skeleton.joints.count)")
            }
            Toggle("Show Skeleton Overlay (experimental)", isOn: $showSkeletonOverlay)
                .toggleStyle(.checkbox)
            Text("Bind-pose joint positions are a best-effort visualization — the exact matrix layout isn't fully confirmed. Select an animation below to see an experimental (illustrative, not verified-accurate) animated pose instead.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var animationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Animations (\(asset.availableAnimations.count))", systemImage: "play.circle").font(.headline)
            if asset.availableAnimations.isEmpty {
                Text("No animations found in this file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Filter by ID…", text: $animationSearch)
                    .textFieldStyle(.roundedBorder)

                List(filteredAnimations, id: \.id, selection: Binding(
                    get: { selectedAnimation?.id },
                    set: { newID in
                        stopPlayback()
                        selectedAnimation = asset.availableAnimations.first { $0.id == newID }
                        currentFrame = 0
                    }
                )) { animation in
                    HStack {
                        Text("Animation #\(animation.id)")
                        Spacer()
                        Text("\(animation.body.totalFrames)f")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(animation.id)
                }
                .frame(height: 140)
                .listStyle(.bordered)

                if let selectedAnimation, selectedAnimation.body.totalFrames > 1 {
                    playbackControls(for: selectedAnimation)
                }
            }
        }
    }

    private func playbackControls(for animation: AnimationAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    togglePlayback(frameCount: animation.body.totalFrames)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                Slider(value: $currentFrame, in: 0...Double(animation.body.totalFrames - 1), step: 1)
                Text("\(Int(currentFrame))/\(animation.body.totalFrames - 1)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 50, alignment: .trailing)
            }
            let frameIndex = min(animation.body.totalFrames - 1, max(0, Int(currentFrame)))
            let frame = animation.body.frames[frameIndex]
            Text("Frame \(frameIndex): \(frame.values.count) channel value(s) — see the Animation record's own inspector for the full breakdown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Export", systemImage: "square.and.arrow.up").font(.headline)
            Button {
                exportCompleteAsset()
            } label: {
                Label("Export Complete Asset…", systemImage: "shippingbox")
            }
            Text("Bundles the mesh (OBJ), every resolved texture (PNG), a material map (MTL), and decoded animation data into one folder.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var filteredAnimations: [AnimationAsset] {
        guard !animationSearch.isEmpty else {
            return asset.availableAnimations.sorted { $0.id < $1.id }
        }
        return asset.availableAnimations
            .filter { String($0.id).contains(animationSearch) }
            .sorted { $0.id < $1.id }
    }

    private func togglePlayback(frameCount: Int) {
        isPlaying.toggle()
        if isPlaying {
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
                currentFrame = (currentFrame + 1).truncatingRemainder(dividingBy: Double(max(1, frameCount)))
            }
        } else {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    /// Best-effort bind-pose joint positions: `Joint.matrix[3].xyz` treated
    /// as a parent-relative local offset, accumulated down the hierarchy.
    /// See `skeletonSection`'s caption — this is a visualization aid, not a
    /// confirmed-correct decode of the matrix layout.
    private func bindPoseSkeletonSegments() -> [(SIMD3<Float>, SIMD3<Float>)] {
        guard let skeleton = asset.skeleton, let root = skeleton.joints.first else { return [] }
        func localPosition(_ joint: Joint) -> SIMD3<Float> {
            guard joint.matrix.count > 3 else { return .zero }
            let v = joint.matrix[3]
            return SIMD3<Float>(v.x, v.y, v.z)
        }
        var worldPositions: [UInt32: SIMD3<Float>] = [root.jointIndex: localPosition(root)]
        var segments: [(SIMD3<Float>, SIMD3<Float>)] = []
        for joint in skeleton.joints.dropFirst() {
            let parentPos = worldPositions[joint.parentJointIndex] ?? .zero
            let pos = parentPos + localPosition(joint)
            worldPositions[joint.jointIndex] = pos
            segments.append((parentPos, pos))
        }
        return segments
    }

    private func exportCompleteAsset() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this model, its textures, and its animations into.") else { return }
        workspace.exportCompleteAsset(asset, to: directory)
    }
}
