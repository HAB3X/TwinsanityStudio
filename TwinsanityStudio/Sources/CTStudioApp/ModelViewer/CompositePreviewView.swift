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
        }
        .onAppear { renderer = ModelViewerRenderer(asset: asset) }
        .onChange(of: asset.id) { _, _ in renderer = ModelViewerRenderer(asset: asset) }
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
