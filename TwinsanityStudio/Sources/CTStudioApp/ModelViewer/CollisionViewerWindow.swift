import SwiftUI
import CTModels

/// "Collision Mesh & Trigger Overlays" (blueprint 4.1): a dedicated Metal
/// viewport for a level's `ColData` collision mesh, rendered as a blue
/// wireframe — reusing the same orbit camera and line-drawing pipeline
/// `ModelViewerRenderer` already built for the skeleton overlay, just fed
/// collision triangle edges instead of joint segments.
struct CollisionViewerWindow: View {
    let mesh: CollisionMesh

    @State private var renderer: ModelViewerRenderer?

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 280)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { renderer = ModelViewerRenderer(collisionMesh: mesh) }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasCollisionWireframe {
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(renderer: renderer)
                    Text("Drag to orbit · Scroll to zoom")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
            } else {
                ContentUnavailableView(
                    "No Collision Geometry",
                    systemImage: "square.grid.3x1.below.line.grid.1x2",
                    description: Text("This record has no vertices/triangles to draw.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Collision Mesh #\(mesh.id)")
                    .font(.title3.bold())

                Form {
                    LabeledContent("Triangles", value: "\(mesh.triangles.count)")
                    LabeledContent("Vertices", value: "\(mesh.vertices.count)")
                    LabeledContent("Spatial Groups", value: "\(mesh.groups.count)")
                    LabeledContent("Trigger Boxes", value: "\(mesh.triggerBoxes.count)")
                }
                .formStyle(.grouped)

                Text("Every triangle edge is drawn — shared edges between adjacent triangles overlap rather than being deduplicated, and there's no per-surface-type color coding yet (see the inspector for why).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
