import SwiftUI
import CTModels

/// The center panel: dispatches to a payload-specific inspector, or a plain
/// hex/metadata view for records this package hasn't modeled yet.
struct InspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode?

    var body: some View {
        Group {
            if let node {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(for: node)
                        Divider()
                        switch node.payload {
                        case .texture(let texture):
                            TextureInspectorView(node: node, texture: texture)
                        case .mesh(let mesh):
                            MeshInspectorView(node: node, mesh: mesh)
                        case .rigidModel(let info):
                            RigidModelInspectorView(info: info)
                        case .skeleton(let skeleton):
                            SkeletonInspectorView(skeleton: skeleton)
                        case .animation(let animation):
                            AnimationInspectorView(animation: animation)
                        case .raw, .none:
                            RawInspectorView(node: node)
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.left",
                    description: Text("Select a chunk, texture, model, or animation from the sidebar.")
                )
            }
        }
    }

    private func header(for node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.displayName)
                .font(.title2.bold())
            HStack(spacing: 12) {
                Label(node.sectionType.rawValue, systemImage: "tag")
                Label("\(node.byteSize) bytes", systemImage: "shippingbox")
                Label("offset 0x\(String(node.fileOffset, radix: 16))", systemImage: "number")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct RigidModelInspectorView: View {
    let info: RigidModelInfo

    var body: some View {
        Form {
            LabeledContent("Header", value: "0x\(String(info.header, radix: 16))")
            LabeledContent("Mesh ID", value: "\(info.meshID)")
            LabeledContent("Material Count", value: "\(info.materialIDs.count)")
            if !info.materialIDs.isEmpty {
                DisclosureGroup("Material IDs") {
                    ForEach(info.materialIDs, id: \.self) { id in
                        Text("#\(id)").font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct RawInspectorView: View {
    let node: ChunkNode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if node.children.isEmpty {
                Label("Not decoded by this build — browsable as raw bytes only.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(node.children.count) child record(s). Select one to inspect it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
