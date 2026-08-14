import SwiftUI
import CTModels
import CTParsers

/// Script Editor — the entry point into real write-back for `ScriptAsset`
/// records. Each field this build has a verified, fixed-offset writer for
/// is edited (and saved as its own edited copy) in one of the two child
/// sheets below:
/// - `HeaderScriptEditorSheet`: participant entries (`mainScriptIndex`/
///   `unkInt2`, `ScriptWriter.writeHeaderScriptEntry`).
/// - `MainScriptEditorSheet`: each state's `scriptIndexOrSlot`
///   (`ScriptWriter.writeScriptIndexOrSlot`) and every command's raw
///   arguments (`AgentLabArgumentEditorSheet`, reused unchanged — a
///   `Script`'s commands are the same `[AgentLabCommand]` type
///   `CustomAgent` records already have write-back for).
///
/// Not editable: `ScriptCondition`/`SupportType1` fields (no captured file
/// offset, and no CrateModLoader mod this build ported ever needs to edit
/// them), and structural changes (adding/removing states, bodies, or
/// commands) — every write path in this app patches a fixed-size range at
/// a captured offset, never re-encodes a whole variable-length record.
struct ScriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let script: ScriptAsset

    @State private var showHeaderEditor = false
    @State private var showMainEditor = false

    init(node: ChunkNode, script: ScriptAsset) {
        self.node = node
        self.script = script
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Script Editor").font(.title3.bold())
            Text("Edit \(script.flag == 0 ? "MainScript" : "HeaderScript") record #\(script.id)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                Section("Script Info") {
                    LabeledContent("ID") { Text("\(script.id)") }
                    LabeledContent("Inline ID") { Text("\(script.inlineID)") }
                    LabeledContent("Priority (mask)") { Text("\(script.mask)") }
                    LabeledContent("Flag") {
                        Text(script.flag == 0 ? "0 (MainScript)" : "\(script.flag) (HeaderScript)")
                    }
                    if !script.trailingBytes.isEmpty {
                        LabeledContent("Trailing Bytes") {
                            Text("\(script.trailingBytes.count) (real — see doc comment)")
                        }
                    }
                }

                switch script.content {
                case .header(let header):
                    Section("HeaderScript (\(header.entries.count) entries)") {
                        Button("Edit Participants…") { showHeaderEditor = true }
                            .disabled(!workspace.canSaveEdits(for: node))
                    }

                case .main:
                    Section("Main Script") {
                        Button("Edit Main Script…") { showMainEditor = true }
                            .disabled(!workspace.canSaveEdits(for: node))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 300)
        .sheet(isPresented: $showHeaderEditor) {
            if case .header(let header) = script.content {
                HeaderScriptEditorSheet(node: node, script: script, header: header)
            }
        }
        .sheet(isPresented: $showMainEditor) {
            if case .main(let main) = script.content {
                MainScriptEditorSheet(node: node, script: script, mainScript: main)
            }
        }
    }
}