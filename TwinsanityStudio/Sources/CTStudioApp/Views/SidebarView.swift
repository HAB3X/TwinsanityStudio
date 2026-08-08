import SwiftUI
import CTModels

struct SidebarView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { workspace.selectedNode?.id },
                set: { newID in
                    workspace.select(findNode(id: newID, in: workspace.filteredRootNodes))
                }
            )) {
                ForEach(workspace.filteredRootNodes) { root in
                    OutlineGroup(root, children: \.childrenIfAny) { node in
                        SidebarRow(node: node, rootID: root.id)
                            .tag(node.id)
                    }
                }
            }
            .listStyle(.sidebar)

            if workspace.rootNodes.isEmpty {
                emptyState
            }
        }
        .searchable(text: $workspace.searchQuery, placement: .sidebar, prompt: "Filter chunks, assets, IDs…")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No archives or level files open")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func findNode(id: UUID?, in nodes: [ChunkNode]) -> ChunkNode? {
        guard let id else { return nil }
        for node in nodes {
            if node.id == id { return node }
            if let match = findNode(id: id, in: node.children) { return match }
        }
        return nil
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let rootID: UUID

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            Text(node.displayName)
                .lineLimit(1)
            Spacer()
            if workspace.isExpandableArchiveEntry(node) {
                Button("Parse") {
                    workspace.expandArchiveEntry(node, rootID: rootID)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else if node.byteSize > 0 {
                Text(byteCountString(node.byteSize))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        switch node.payload {
        case .texture: return "photo"
        case .mesh(let mesh): return mesh.isSkinned ? "figure.walk" : "cube"
        case .rigidModel: return "cube.transparent"
        case .skeleton: return "figure.stand"
        case .animation: return "play.circle"
        case .raw, .none: return node.children.isEmpty ? "doc" : "folder"
        }
    }

    private var iconColor: Color {
        switch node.payload {
        case .texture: return .purple
        case .mesh: return .blue
        case .rigidModel: return .teal
        case .skeleton: return .orange
        case .animation: return .green
        case .raw, .none: return .secondary
        }
    }

    private func byteCountString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension ChunkNode {
    /// `OutlineGroup` wants `nil` (not an empty array) to treat a row as a
    /// non-expandable leaf.
    var childrenIfAny: [ChunkNode]? { children.isEmpty ? nil : children }
}
