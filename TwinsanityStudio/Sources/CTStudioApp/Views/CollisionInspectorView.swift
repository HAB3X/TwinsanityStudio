import SwiftUI
import CTModels

/// Read-only summary for a decoded `ColData` record, with a button into the
/// dedicated wireframe viewer (`CollisionViewerWindow`) — this is a
/// level-wide collision mesh, not a single composite-eligible object, so it
/// doesn't go through `WorkspaceViewModel.resolveComposite`/the Model
/// Viewer sheet the way textures/meshes do.
struct CollisionInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let mesh: CollisionMesh

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mesh.isEmpty {
                ContentUnavailableView(
                    "No Collision Geometry",
                    systemImage: "square.grid.3x1.below.line.grid.1x2",
                    description: Text("This record decoded but has no vertices/triangles — the reference tool treats a short ColData record as an intentionally empty placeholder.")
                )
            } else {
                Form {
                    Section("Geometry") {
                        LabeledContent("Triangles", value: "\(mesh.triangles.count)")
                        LabeledContent("Vertices", value: "\(mesh.vertices.count)")
                        LabeledContent("Spatial Groups", value: "\(mesh.groups.count)")
                    }
                    if !mesh.triggerBoxes.isEmpty {
                        Section("Trigger Boxes (\(mesh.triggerBoxes.count))") {
                            Text("Axis-aligned volumes distinct from the gameplay Trigger/Camera records — see the reference tool's `ColData.Trigger`.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Text("Each triangle carries a raw `surfaceID` linking it to a `CollisionSurface` record's impact sound/particle/physics properties. This build doesn't yet decode `CollisionSurface` records or the game-logic data that assigns meaning (e.g. \"deadly\") to specific surface IDs, so the wireframe below is shown in a single color rather than an invented category-color scheme.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                Button {
                    workspace.collisionViewerMesh = mesh
                } label: {
                    Label("Open Collision Viewer", systemImage: "cube.transparent")
                }
            }
        }
    }
}
