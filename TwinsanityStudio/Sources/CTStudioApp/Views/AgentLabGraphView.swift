import SwiftUI
import CTCore
import CTModels

/// "AgentLab Visual Node Graph" (roadmap 4.2, Part 3 of the Chunk-Based
/// Editor mandate) — a drag-and-drop canvas over a file's real `CustomAgent`
/// records.
///
/// What's real here: every node corresponds to an actual `CustomAgent`
/// leaf record in the currently open file (real `recordID`, real
/// `byteSize`, real leading bytes shown as hex) — nothing per-node is
/// invented. What's a shell, honestly: this build has no parser for the
/// record's internal bytecode. The disassembled retail engine (see
/// `OpenSanityNeo`'s `agentlab_control.cpp`/`percept_abstract.h`/
/// `action_abstract.h`) confirms *what* the format represents — a
/// `LayerControl` selecting `Percept`-scored `Action`s, `Action`s chained
/// via a `nextAction` link — but not the on-disk byte layout, so this view
/// cannot decode or draw the real Percept -> Action graph inside a record.
/// Nodes are therefore laid out independently with no fabricated
/// connections between them, matching this session's standing rule: real,
/// decoded data only, never a plausible-looking guess presented as fact.
struct AgentLabGraphView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let sectionNode: ChunkNode

    @State private var nodePositions: [UUID: CGPoint] = [:]
    @State private var dragStartPositions: [UUID: CGPoint] = [:]
    @State private var selectedNode: ChunkNode?

    private var agentNodes: [ChunkNode] { sectionNode.children }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                canvas
                if let selectedNode {
                    Divider()
                    inspector(for: selectedNode)
                        .frame(width: 260)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { layoutNodesIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AgentLab Graph — \(sectionNode.displayName)").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("\(agentNodes.count) real CustomAgent record(s) from this file. This build doesn't have a decoder for the Percept/Action bytecode inside each one (see this view's own doc comment) — nodes show real record metadata and a raw hex preview, not decoded behavior. Drag nodes to rearrange.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var canvas: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: max(proxy.size.width, canvasContentSize.width), height: max(proxy.size.height, canvasContentSize.height))
                    ForEach(agentNodes) { node in
                        agentCard(node)
                            .position(nodePositions[node.id] ?? .zero)
                            .gesture(dragGesture(for: node))
                    }
                }
            }
            .background(Self.gridBackground)
        }
    }

    private var canvasContentSize: CGSize {
        let maxX = nodePositions.values.map(\.x).max() ?? 400
        let maxY = nodePositions.values.map(\.y).max() ?? 400
        return CGSize(width: maxX + 200, height: maxY + 160)
    }

    private func agentCard(_ node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.purple)
                Text("Agent #\(node.recordID)").font(.caption.bold())
                Spacer()
            }
            Text("\(node.byteSize) bytes")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(hexPreview(for: node))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(width: 180, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.purple.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedNode?.id == node.id ? Color.purple : Color.purple.opacity(0.4), lineWidth: selectedNode?.id == node.id ? 2 : 1))
        .onTapGesture { selectedNode = node }
    }

    private func dragGesture(for node: ChunkNode) -> some Gesture {
        DragGesture(coordinateSpace: .local)
            .onChanged { value in
                let start = dragStartPositions[node.id] ?? nodePositions[node.id] ?? .zero
                if dragStartPositions[node.id] == nil { dragStartPositions[node.id] = start }
                nodePositions[node.id] = CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
            }
            .onEnded { _ in dragStartPositions[node.id] = nil }
    }

    private func hexPreview(for node: ChunkNode) -> String {
        guard let bytes = workspace.rawBytes(for: node), !bytes.isEmpty else { return "(no raw bytes available)" }
        let preview = bytes.prefix(16)
        return preview.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    @ViewBuilder
    private func inspector(for node: ChunkNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent #\(node.recordID)").font(.headline)
            LabeledContent("Byte Size", value: "\(node.byteSize)")
            LabeledContent("File Offset", value: "0x\(String(node.fileOffset, radix: 16))")
            Divider()
            Text("Raw Bytes").font(.caption.bold())
            ScrollView {
                Text(fullHex(for: node))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            Button("View in Hex Editor…") { workspace.hexViewerNode = node }
        }
        .padding(12)
    }

    private func fullHex(for node: ChunkNode) -> String {
        guard let bytes = workspace.rawBytes(for: node) else { return "(unavailable)" }
        return bytes.prefix(512).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Simple grid layout, 4 columns, generous spacing — no attempt at a
    /// force-directed/topological layout since there's no real edge data
    /// to lay out around (see this view's own doc comment).
    private func layoutNodesIfNeeded() {
        guard nodePositions.isEmpty else { return }
        let columns = 4
        let spacingX: CGFloat = 220
        let spacingY: CGFloat = 130
        for (index, node) in agentNodes.enumerated() {
            let column = index % columns
            let row = index / columns
            nodePositions[node.id] = CGPoint(x: 120 + CGFloat(column) * spacingX, y: 80 + CGFloat(row) * spacingY)
        }
    }

    private static var gridBackground: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var x: CGFloat = 0
            while x < size.width {
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(.secondary.opacity(0.08)))
                x += spacing
            }
            var y: CGFloat = 0
            while y < size.height {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(.secondary.opacity(0.08)))
                y += spacing
            }
        }
    }
}
