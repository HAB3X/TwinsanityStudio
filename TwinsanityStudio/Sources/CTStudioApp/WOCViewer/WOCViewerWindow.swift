import SwiftUI

struct WOCViewerWindow: View {
    let asset: WOCLevelAsset

    @State private var renderer: WOCViewerRenderer?

    var body: some View {
        HStack(spacing: 0) {
            viewportArea
            Divider()
            sidebar
                .frame(width: 300)
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            renderer = WOCViewerRenderer(objects: asset.objects, objectCount: asset.distinctObjectCount)
        }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if asset.objects.isEmpty {
                ContentUnavailableView(
                    "No Placed Objects",
                    systemImage: "square.dashed",
                    description: Text("This level's INST section decoded to zero instances.")
                )
            } else {
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
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(asset.name)
                    .font(.title3.bold())

                Form {
                    LabeledContent("Placed Objects", value: "\(asset.objects.count)")
                    LabeledContent("Distinct Objects", value: "\(asset.distinctObjectCount)")
                    LabeledContent("Named Entries", value: "\(asset.objectNames.count)")
                    LabeledContent("Textures", value: "\(asset.textureCount)")
                    LabeledContent("Sections", value: asset.sectionTags.joined(separator: ", "))
                }
                .formStyle(.grouped)

                statusNote

                if !asset.objectNames.isEmpty {
                    Divider()
                    Text("Name Table (\(asset.objectNames.count))")
                        .font(.subheadline.bold())
                    ForEach(Array(asset.objectNames.prefix(60).enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if asset.objectNames.count > 60 {
                        Text("+ \(asset.objectNames.count - 60) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
        }
    }

    private var statusNote: some View {
        Text("Each point is one real, decoded placed-object position and world transform (WoC's INST section), color-coded by which distinct object it is. This is not yet real mesh geometry — WoC's per-object mesh boundaries (inside its OBJ0 section) aren't decoded yet, so there's no reliable per-object shape to draw. What's shown here is real, correctly-positioned data, just points rather than final meshes.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
