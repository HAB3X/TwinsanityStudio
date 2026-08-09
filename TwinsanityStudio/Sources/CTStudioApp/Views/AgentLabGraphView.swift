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
    /// "Snap-to-connect wires" — real UI, honestly scoped: these are the
    /// user's *own* organizational links between nodes (grouping, call-out
    /// notes, whatever the user means by connecting two agents), not a
    /// decoded Percept -> Action data/call flow — this build has no parser
    /// for that (see this view's own top-level doc comment). Session-only,
    /// same as node positions — no on-disk format exists to save either
    /// into.
    @State private var connections: Set<AgentConnection> = []
    @State private var pendingConnectionStart: UUID?
    @State private var pendingConnectionDragPoint: CGPoint?

    private struct AgentConnection: Hashable {
        let a: UUID
        let b: UUID
        init(_ x: UUID, _ y: UUID) {
            // Normalized so a<->b and b<->a are the same connection.
            if x.uuidString < y.uuidString { a = x; b = y } else { a = y; b = x }
        }
    }

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
            Text("\(agentNodes.count) real CustomAgent record(s) from this file. This build doesn't have a decoder for the Percept/Action bytecode inside each one (see this view's own doc comment) — nodes show real record metadata and a raw hex preview, not decoded behavior. Drag a card to rearrange it; drag from a card's connector dot (bottom-right) to another card to link them — those links are your own organizational notes, not decoded engine data.")
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
                    connectionsLayer
                    ForEach(agentNodes) { node in
                        agentCard(node)
                            .position(nodePositions[node.id] ?? .zero)
                            .gesture(dragGesture(for: node))
                    }
                }
                .coordinateSpace(name: "agentLabCanvas")
            }
            .background(Self.gridBackground)
        }
    }

    /// Every user-drawn connection, plus a live preview line while a
    /// connector-drag is in progress. Drawn *behind* the node cards (see
    /// `canvas`'s ZStack order) so cards remain fully clickable/draggable
    /// on top.
    private var connectionsLayer: some View {
        Canvas { context, _ in
            for connection in connections {
                guard let start = nodePositions[connection.a], let end = nodePositions[connection.b] else { continue }
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.purple.opacity(0.6)), lineWidth: 2)
            }
            if let startID = pendingConnectionStart, let start = nodePositions[startID], let end = pendingConnectionDragPoint {
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(.purple), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            ForEach(Array(connections), id: \.self) { connection in
                if let start = nodePositions[connection.a], let end = nodePositions[connection.b] {
                    let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    Button {
                        connections.remove(connection)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .background(Circle().fill(.background))
                    }
                    .buttonStyle(.plain)
                    .position(midpoint)
                }
            }
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
            HStack {
                Spacer()
                Circle()
                    .fill(pendingConnectionStart == node.id ? Color.purple : Color.purple.opacity(0.5))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
                    .gesture(connectorDragGesture(from: node))
                    .help("Drag to another card to link them (your own note, not decoded data)")
            }
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

    /// Drag from a card's connector dot to another card to link them.
    /// Uses the shared named coordinate space (`agentLabCanvas`) so
    /// `value.location` lands in the same space `nodePositions` is
    /// already stored in, regardless of how deep the connector dot sits
    /// inside the card's own view hierarchy.
    private func connectorDragGesture(from node: ChunkNode) -> some Gesture {
        DragGesture(coordinateSpace: .named("agentLabCanvas"))
            .onChanged { value in
                pendingConnectionStart = node.id
                pendingConnectionDragPoint = value.location
            }
            .onEnded { value in
                defer {
                    pendingConnectionStart = nil
                    pendingConnectionDragPoint = nil
                }
                guard let target = nearestNode(to: value.location, excluding: node.id), target != node.id else { return }
                connections.insert(AgentConnection(node.id, target))
            }
    }

    /// The nearest node to `point` within a generous drop radius — lets a
    /// connector drag land anywhere on the target card, not just its exact
    /// center.
    private func nearestNode(to point: CGPoint, excluding: UUID) -> UUID? {
        let dropRadius: CGFloat = 100
        var best: (id: UUID, distance: CGFloat)?
        for node in agentNodes where node.id != excluding {
            guard let position = nodePositions[node.id] else { continue }
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance < dropRadius, (best == nil || distance < best!.distance) {
                best = (node.id, distance)
            }
        }
        return best?.id
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
