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
                    OutlineGroup(root, children: \.displayChildren) { node in
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
                .foregroundStyle(node.isUninteresting ? AnyShapeStyle(.tertiary) : AnyShapeStyle(iconColor))
                .frame(width: 18)
            Text(node.displayName)
                .lineLimit(1)
                .foregroundStyle(node.isUninteresting ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
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
        .opacity(node.isUninteresting ? 0.55 : 1.0)
        .contextMenu {
            if let composite = workspace.resolveComposite(for: node) {
                Button {
                    workspace.modelViewerAsset = composite
                } label: {
                    Label("View Parent / Composite", systemImage: "cube.fill")
                }
                Button {
                    exportGroup(composite)
                } label: {
                    Label("Export as Group…", systemImage: "shippingbox")
                }
            }
        }
    }

    private func exportGroup(_ asset: ResolvedModelAsset) {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this composite object — mesh, textures, and animations — into.") else { return }
        workspace.exportCompleteAsset(asset, to: directory)
    }

    private var icon: String {
        switch node.payload {
        case .texture: return "photo"
        case .mesh(let mesh): return mesh.isSkinned ? "figure.walk" : "cube"
        case .rigidModel: return "cube.transparent"
        case .material: return "paintpalette"
        case .skeleton: return "figure.stand"
        case .animation: return "play.circle"
        case .position: return "mappin"
        case .instance: return "cube.transparent.fill"
        case .trigger: return "square.dashed"
        case .camera: return "video.fill"
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
        case .position: return .mint
        case .instance: return .indigo
        case .trigger: return .red
        case .camera: return .yellow
        case .raw, .none: return .secondary
        }
    }

    private func byteCountString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension ChunkNode {
    /// Coarse display priority: decoded, meaningful content (textures,
    /// models, skeletons, animations, materials) sorts before raw/unhandled
    /// records and empty containers, so browsing the tree surfaces the
    /// interesting stuff first instead of forcing a scroll past hundreds of
    /// undecoded Object/Script/Trigger/Position records to find it.
    private var displaySortRank: Int {
        switch payload {
        case .texture, .mesh, .rigidModel, .skeleton, .animation, .instance, .trigger, .camera: return 0
        case .material, .position: return 1
        case .none: return children.isEmpty ? 3 : 2
        case .raw: return 3
        }
    }

    /// `children`, sorted for display only (a stable sort — nodes with the
    /// same rank keep their on-disk order). `OutlineGroup` wants `nil` (not
    /// an empty array) to treat a row as a non-expandable leaf. Export/hex
    /// offset logic elsewhere keeps using `children` directly; this exists
    /// purely for the sidebar tree.
    var displayChildren: [ChunkNode]? {
        children.isEmpty ? nil : children.sorted { $0.displaySortRank < $1.displaySortRank }
    }

    /// A dead-end the user almost certainly doesn't care about browsing:
    /// no children of its own, and either undecoded or genuinely raw.
    /// Sections that merely *contain* raw children (e.g. an Instance
    /// section full of undecoded Object records) are not themselves dimmed
    /// — only the actual dead-end leaves are.
    var isUninteresting: Bool {
        guard children.isEmpty else { return false }
        switch payload {
        case .none: return true
        case .raw: return true
        default: return false
        }
    }
}
