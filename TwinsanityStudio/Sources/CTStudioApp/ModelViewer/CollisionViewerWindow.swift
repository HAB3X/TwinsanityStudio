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
    @State private var colorBySurface = false

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 280)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { renderer = ModelViewerRenderer(collisionMesh: mesh) }
        .onChange(of: colorBySurface) { _, newValue in
            renderer?.collisionColorMode = newValue ? .bySurfaceID : .solid
        }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasCollisionWireframe {
                // See `ModelViewerWindow`'s matching comment — a `maxWidth/
                // maxHeight: .infinity`-only frame isn't a concrete enough
                // size for a `.sheet()`'s first layout pass to reliably
                // drive the underlying `MTKView`'s `CAMetalLayer` from; a
                // real minimum alongside it is.
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

                Toggle("Color by Surface ID", isOn: $colorBySurface)
                    .toggleStyle(.checkbox)

                if colorBySurface {
                    surfaceLegend
                }

                Text(colorBySurface
                     ? "Each color is one raw, decoded surfaceID from the collision data — not a semantic category like \"deadly\" or \"solid.\" That classification lives in the undecoded CollisionSurface/Object records this build doesn't have a verified mapping for; coloring by the real ID still makes distinct physical-material regions visible without guessing at what they mean."
                     : "Every triangle edge is drawn — shared edges between adjacent triangles overlap rather than being deduplicated.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var surfaceLegend: some View {
        let ids = renderer?.collisionSurfaceIDs ?? []
        VStack(alignment: .leading, spacing: 4) {
            Text("Surface IDs (\(ids.count))")
                .font(.caption.bold())
            ForEach(ids.prefix(24), id: \.self) { surfaceID in
                HStack(spacing: 6) {
                    let c = ModelViewerRenderer.color(forSurfaceID: surfaceID)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                        .frame(width: 12, height: 12)
                    Text("#\(surfaceID)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if ids.count > 24 {
                Text("+ \(ids.count - 24) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
