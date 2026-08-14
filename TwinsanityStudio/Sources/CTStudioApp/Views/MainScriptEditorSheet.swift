import SwiftUI
import CTModels
import CTParsers

/// Editor for `MainScript`: real write-back for `ScriptState.scriptIndexOrSlot`
/// (redirecting a state to a different script/slot — the same real
/// operation CrateModLoader's own cutscene-skip mods perform, patched at
/// `ScriptState.scriptIndexOrSlotFileOffset`), plus real command-argument
/// editing for every command in every state's body chain — `ScriptStateBody.
/// commands` is the exact same `[AgentLabCommand]` type `CustomAgent`
/// records already have real write-back for, so this reuses
/// `AgentLabArgumentEditorSheet` unchanged rather than re-deriving it.
///
/// `ScriptCondition` and `SupportType1` are shown factually, read-only —
/// no CrateModLoader mod this build ported ever edits either, and there's
/// no captured file offset for their fields yet.
struct MainScriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let script: ScriptAsset
    let mainScript: MainScript

    /// Non-`nil` presents the argument-editor sheet for one command —
    /// same pattern as `AgentLabGraphView.editingCommand`.
    @State private var editingCommand: AgentLabCommand?
    @State private var slotTexts: [Int: String] = [:]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, script: ScriptAsset, mainScript: MainScript) {
        self.node = node
        self.script = script
        self.mainScript = mainScript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Main Script — \(mainScript.name.isEmpty ? "<unnamed>" : mainScript.name)").font(.title3.bold())
                Text("Real write-back: redirecting a state's script/slot, or editing any command's arguments, patches straight into a copy of this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Start Unit") { Text("\(mainScript.startUnit)") }
                    LabeledContent("Actual State Count") { Text("\(mainScript.states.count)") }

                    ForEach(Array(mainScript.states.enumerated()), id: \.offset) { index, state in
                        stateSection(index: index, state: state)
                    }
                }
                .padding()
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(isSaving)
                    .padding()
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .sheet(item: $editingCommand) { command in
            AgentLabArgumentEditorSheet(node: node, command: command)
        }
    }

    private func stateSection(index: Int, state: ScriptState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("State #\(index)").font(.callout.bold())
            HStack {
                Text("Bitfield 0x\(String(UInt16(bitPattern: state.bitfieldRaw), radix: 16)) · Slot:")
                    .font(.caption)
                TextField("", text: Binding(
                    get: { slotTexts[index] ?? "\(state.scriptIndexOrSlot)" },
                    set: { slotTexts[index] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .font(.caption.monospaced())
                Button("Apply") { applySlot(index: index, state: state) }
                    .controlSize(.small)
                Text(state.isSlot ? "(is a slot)" : "(script index)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let type1 = state.type1 {
                Text("SupportType1: space \(type1.resolvedSpace.map { "\($0)" } ?? "?"), motion \(type1.resolvedMotion.map { "\($0)" } ?? "?"), \(type1.floats.count) float(s), \(type1.bytes.count) byte(s)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(state.bodies.enumerated()), id: \.offset) { bodyIndex, body in
                bodySection(index: bodyIndex, body: body)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private func bodySection(index: Int, body: ScriptStateBody) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Body #\(index)").font(.caption.bold())
                if !body.isEnabled { Text("(disabled)").font(.caption2).foregroundStyle(.secondary) }
            }
            if let condition = body.condition {
                Text("Condition: \(ScriptConditionCatalog.conditionName(forID: condition.vTableIndex) ?? "#\(condition.vTableIndex)")\(condition.notGate ? " (NOT)" : "") — interval \(condition.interval, specifier: "%.3f"), threshold \(condition.threshold, specifier: "%.3f")/\(condition.thresholdInverse, specifier: "%.3f")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(body.commands.enumerated()), id: \.offset) { _, command in
                HStack {
                    Text(command.commandName ?? "Command #\(command.commandID)")
                        .font(.caption.monospaced())
                    Text("(\(command.rawArguments.count) arg\(command.rawArguments.count == 1 ? "" : "s"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Arguments…") { editingCommand = command }
                        .controlSize(.small)
                        .disabled(!workspace.canSaveEdits(for: node))
                }
            }
        }
        .padding(.leading, 12)
    }

    private func applySlot(index: Int, state: ScriptState) {
        let text = (slotTexts[index] ?? "\(state.scriptIndexOrSlot)").trimmingCharacters(in: .whitespaces)
        guard let value = Int16(text) else {
            errorMessage = "State \(index)'s slot value (\"\(text)\") isn't a valid 16-bit integer."
            return
        }
        errorMessage = nil

        let encoded = ScriptWriter.writeScriptIndexOrSlot(value)
        let absoluteOffset = node.fileOffset + state.scriptIndexOrSlotFileOffset
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with state \(index)'s script/slot changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with state \(index)'s script/slot changed."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
