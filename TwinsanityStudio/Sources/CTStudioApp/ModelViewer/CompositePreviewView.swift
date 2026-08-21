import SwiftUI
import AppKit
import CTModels
import CTExport

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
    /// "Cross-Engine Texture Variant" — `nil` shows this object's own
    /// real textures (the default); a real ID selects one real, decoded
    /// Wrath of Cortex texture (from `workspace.wocCrateTextureLibrary`)
    /// to preview in its place, using this asset's own real, working
    /// UVs. See `ResolvedModelAsset.applyingTextureOverride(_:)`'s doc
    /// comment for exactly what this does and doesn't touch.
    @State private var wocOverrideTextureID: UUID?
    /// "Cross-Engine Texture Variant" crate export — presents
    /// `CrateExportSheet` for `workspace.
    /// exportCrossEngineTextureOverrideAsCrate`, the same "bundle a real
    /// override into an installable .crate" flow `ModelViewerWindow`'s own
    /// "Export as Group…" dependency crate already uses for a whole asset,
    /// applied here to just the currently-previewed override texture.
    @State private var isTextureOverrideCrateSheetPresented = false

    private var wocOverrideTexture: TextureAsset? {
        guard let wocOverrideTextureID else { return nil }
        return workspace.wocCrateTextureLibrary.first { $0.id == wocOverrideTextureID }?.texture
    }

    private var effectiveAsset: ResolvedModelAsset {
        asset.applyingTextureOverride(wocOverrideTexture)
    }

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
                    workspace.modelViewerAsset = effectiveAsset
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

            Divider()
            crossEngineTextureVariant

            if asset.skeleton != nil, !asset.availableAnimations.isEmpty {
                Divider()
                animationSandbox
            }
        }
        .onAppear { renderer = ModelViewerRenderer(asset: effectiveAsset) }
        .onChange(of: asset.id) { _, _ in
            wocOverrideTextureID = nil
            renderer = ModelViewerRenderer(asset: effectiveAsset)
            stopSandboxPlayback()
            sandboxAnimationID = nil
        }
        .onChange(of: wocOverrideTextureID) { _, _ in
            renderer = ModelViewerRenderer(asset: effectiveAsset)
        }
        .onDisappear { stopSandboxPlayback() }
        .sheet(isPresented: $isTextureOverrideCrateSheetPresented) {
            if let wocOverrideTexture {
                CrateExportSheet(
                    suggestedName: "\(asset.displayName) WoC Texture Override",
                    caption: "Bundles this WoC texture override into a real CrateModLoader-installable .crate — installing it patches every real texture record this object's submeshes reference, without touching mesh geometry, collision, or entity/trigger data."
                ) { metadata, url in
                    workspace.exportCrossEngineTextureOverrideAsCrate(asset: asset, overrideTexture: wocOverrideTexture, metadata: metadata, to: url)
                }
            }
        }
    }

    /// "Cross-Engine Texture Variant": lets the user preview one of this
    /// object's own submesh textures swapped for a real, decoded Wrath
    /// of Cortex texture — geometry, skeleton, and every other real field
    /// on `asset` stay exactly as resolved; only the in-memory preview's
    /// `texture` changes, never anything on disk. Empty state offers
    /// loading a real `.GSC` file directly (typically `CRATES.GSC`); once
    /// loaded, a horizontal picker of real thumbnails lets the user
    /// choose (or revert to "Original").
    private var crossEngineTextureVariant: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cross-Engine Texture Variant", systemImage: "arrow.left.arrow.right.square")
                .font(.headline)

            if workspace.wocCrateTextureLibrary.isEmpty {
                Button {
                    presentLoadWOCTexturesPanel()
                } label: {
                    Label("Load WoC Crate Textures…", systemImage: "square.and.arrow.down")
                }
                Text("Loads every real, decoded texture from a real Wrath of Cortex .GSC file (e.g. CRATES.GSC) as candidates. This object's own real UVs do the wrapping — only the pixel data changes, so this works even though WoC's own per-vertex UVs aren't decoded.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        variantChip(label: "Original", isSelected: wocOverrideTextureID == nil) {
                            wocOverrideTextureID = nil
                        }
                        ForEach(workspace.wocCrateTextureLibrary) { entry in
                            variantThumbnail(entry: entry, isSelected: wocOverrideTextureID == entry.id) {
                                wocOverrideTextureID = entry.id
                            }
                        }
                        Button {
                            presentLoadWOCTexturesPanel()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Load more WoC textures from another .GSC file")
                    }
                    .padding(.vertical, 2)
                }
                if wocOverrideTextureID != nil {
                    Text("Previewing a real WoC texture on this object's own UVs — a real, disk-untouched visual override. Geometry, collision, and entity behavior are unaffected. Pick \"Original\" to revert.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        isTextureOverrideCrateSheetPresented = true
                    } label: {
                        Label("Export as Mod Crate…", systemImage: "shippingbox")
                    }
                    .disabled(wocOverrideTexture == nil)
                }
            }
        }
    }

    private func variantChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(nsColor: .underPageBackgroundColor))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func variantThumbnail(entry: TextureHubEntry, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let cgImage = try? TextureExporter.cgImage(from: entry.texture) {
                    Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Color.accentColor : Color(.separatorColor), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(entry.sourceLabel)
    }

    private func presentLoadWOCTexturesPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a real Wrath of Cortex .GSC file (e.g. CRATES.GSC) to load its real, decoded textures as candidates."
        panel.prompt = "Load"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.loadWOCCrateTextureLibrary(from: url)
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
                Text("The model itself deforms live as you scrub — see the Animation record's own inspector for the raw decoded data.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    /// Deforms the actual previewed mesh to the current sandbox frame's
    /// real, verified pose (`AnimationSkeletonBinding` — see its doc
    /// comment for where this math comes from) and updates the skeleton
    /// line overlay to match.
    private func applySandboxPose() {
        guard let skeleton = asset.skeleton, let sandboxAnimation else {
            renderer?.resetToBindPose()
            renderer?.skeletonJointWorldPositions = []
            return
        }
        let frameIndex = min(sandboxAnimation.body.totalFrames - 1, max(0, Int(sandboxFrame)))
        renderer?.applySkeletalPose(skeleton: skeleton, track: sandboxAnimation.body, frameIndex: frameIndex)
        renderer?.skeletonJointWorldPositions = AnimationSkeletonBinding.jointSegments(
            skeleton: skeleton,
            track: sandboxAnimation.body,
            frameIndex: frameIndex
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
