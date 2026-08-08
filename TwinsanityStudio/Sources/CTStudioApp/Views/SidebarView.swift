import SwiftUI
import CTModels

struct SidebarView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !workspace.rootNodes.isEmpty {
                filterBar
                Divider()
            }

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
            } else if workspace.filteredRootNodes.isEmpty {
                filteredEmptyState
            }
        }
        .searchable(text: $workspace.searchQuery, placement: .sidebar, prompt: "Filter chunks, assets, IDs…")
    }

    /// Type filter + "Scan Archive" — the type filter can only find assets
    /// inside files that have actually been parsed, so the scan action is
    /// surfaced right alongside it rather than buried in a menu.
    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $workspace.typeFilter) {
                Text("All Kinds").tag(ChunkPayload.Kind?.none)
                ForEach(ChunkPayload.Kind.allCases) { kind in
                    Text(kind.rawValue).tag(ChunkPayload.Kind?.some(kind))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)

            Spacer()

            if workspace.isScanning {
                ProgressView().controlSize(.small)
            } else if workspace.hasUnscannedArchives {
                Button {
                    workspace.scanAllArchives()
                } label: {
                    Label("Scan Archive", systemImage: "sparkle.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Parse every level file so the type filter and search can find assets anywhere in the archive.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(workspace.hasUnscannedArchives ? "No matches yet — try Scan Archive above" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
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
        case .material: return "paintpalette"
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
        case .material: return .pink
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
