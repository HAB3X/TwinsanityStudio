import SwiftUI
import CTModels

/// Read-only inspector for a decoded `ChunkLinks` record — "Chunk-Based
/// Architecture" (Part 2). No write-back yet (unlike Trigger/Camera): this
/// build has no verified byte-exact encoder for the record's variable-length
/// `path`/tree-chain shape, so editing here would risk producing a file this
/// build itself can't parse back.
struct ChunkLinksInspectorView: View {
    let node: ChunkNode
    let chunkLinks: ChunkLinksAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Chunk Links (\(chunkLinks.links.count))") {
                    Text("Every neighboring chunk file this level can stream in, decoded from the real on-disk `ChunkLinks` record. Open the Level Viewer to see boundary walls and load adjoining chunks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(chunkLinks.links) { link in
                    Section("Link \(link.id): \(link.path)") {
                        LabeledContent("Type", value: "\(link.type)")
                        LabeledContent("Flags", value: "0x\(String(link.flags, radix: 16))")
                        LabeledContent("Has Boundary Wall", value: link.hasWall ? "Yes" : "No")
                        LabeledContent("Load-Zone Nodes", value: "\(link.treeNodes.count)")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
