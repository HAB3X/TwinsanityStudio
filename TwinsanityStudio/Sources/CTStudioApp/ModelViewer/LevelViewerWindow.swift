import SwiftUI
import CTModels

/// Bundles a decoded `SceneryData` record with its already-resolved
/// placements (mesh + textures per object) — resolved once, when the user
/// clicks "Open Level Viewer" (`SceneryInspectorView`), rather than redone
/// on every render of this window.
public struct LevelViewerContext: Identifiable {
    public let id = UUID()
    public var scenery: SceneryAsset
    public var placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)]

    public init(scenery: SceneryAsset, placements: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)]) {
        self.scenery = scenery
        self.placements = placements
    }
}

/// "Scenery/Level Assembly": a multi-object Metal viewport drawing every
/// resolved scenery placement in one scene, positioned per the level's own
/// placement data.
struct LevelViewerWindow: View {
    let context: LevelViewerContext

    @State private var renderer: LevelViewerRenderer?

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 300)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { renderer = LevelViewerRenderer(placements: context.placements) }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if renderer.hasGeometry {
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
                    "No Resolvable Placements",
                    systemImage: "map",
                    description: Text("This level's scenery tree decoded (\(context.scenery.placements.count) placement(s) total), but none of their model IDs matched a RigidModel in this file's Graphics section.")
                )
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(context.scenery.chunkName.isEmpty ? "Level" : context.scenery.chunkName)
                    .font(.title3.bold())

                Form {
                    LabeledContent("Placements in tree", value: "\(context.scenery.placements.count)")
                    LabeledContent("Resolved & drawn", value: "\(context.placements.count)")
                }
                .formStyle(.grouped)

                Text("Objects are drawn at their correct world position, but not yet rotated or scaled to match the level data — only translation is currently applied (see LevelViewerRenderer). Shape/orientation of individual pieces may look off even though placement roughly matches the level layout.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            .padding(16)
        }
    }
}
