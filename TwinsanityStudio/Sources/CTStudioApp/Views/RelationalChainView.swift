import SwiftUI
import CTModels

/// "Deep Hierarchy & Linked Asset Resolution": shows the selected node's
/// parent composite object and every component that composite is built
/// from, each clickable to jump the sidebar selection straight to it.
struct RelationalChainView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    @State private var isExpanded = true

    var body: some View {
        if let chain = workspace.relationalChain(for: node) {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.forward.circle")
                            .foregroundStyle(.secondary)
                        Text("Parent: \(chain.parentDisplayName)")
                            .font(.callout.bold())
                    }
                    .padding(.top, 4)

                    ForEach(groupedComponents(chain), id: \.kind) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.kind.rawValue + "s")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            ForEach(group.items) { component in
                                Button {
                                    workspace.selectComponent(component)
                                } label: {
                                    HStack {
                                        Image(systemName: icon(for: component.kind))
                                            .frame(width: 16)
                                        Text(component.displayName)
                                        Spacer()
                                        if component.recordID == node.recordID {
                                            Text("selected")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(component.recordID == node.recordID ? .primary : Color.accentColor)
                            }
                        }
                    }
                }
                .padding(.leading, 4)
            } label: {
                Label("Relational Chain", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
            }
        } else {
            EmptyView()
        }
    }

    private struct ComponentGroup {
        let kind: LinkedComponent.Kind
        let items: [LinkedComponent]
    }

    /// Groups by kind in a fixed, sensible reading order rather than
    /// however `RelationalChain.components` happens to be ordered.
    private func groupedComponents(_ chain: RelationalChain) -> [ComponentGroup] {
        let order: [LinkedComponent.Kind] = [.mesh, .skeleton, .material, .texture, .animation]
        return order.compactMap { kind in
            let items = chain.components.filter { $0.kind == kind }
            return items.isEmpty ? nil : ComponentGroup(kind: kind, items: items)
        }
    }

    private func icon(for kind: LinkedComponent.Kind) -> String {
        switch kind {
        case .mesh: return "cube"
        case .material: return "paintpalette"
        case .texture: return "photo"
        case .skeleton: return "figure.stand"
        case .animation: return "play.circle"
        }
    }
}
