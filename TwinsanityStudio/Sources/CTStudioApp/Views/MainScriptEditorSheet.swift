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
/// "AgentLab Phase C": `ScriptCondition` (vTableIndex/parameter/notGate,
/// packed into `unkInt1Raw`, plus interval/threshold/thresholdInverse) and
/// `SupportType1.unkInt1Raw` (every `resolved*`/flag accessor it packs)
/// are real, byte-exact patch targets now — see `ScriptCondition.
/// fileOffset`/`SupportType1.unkInt1RawFileOffset` and `ScriptWriter.
/// writeCondition`/`writeSupportType1UnkInt1Raw`. `SupportType1`'s own
/// variable-length `bytes`/`floats` lists stay read-only (editing their
/// *count* would mean re-encoding this variable-length record, not a
/// same-size patch); only `unkInt1Raw`'s packed fields are exposed here.
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
    /// Keyed by `"stateIndex-bodyIndex"` — a condition's own live-edited
    /// field text, separate from `slotTexts`'s per-state keying.
    @State private var conditionVTableTexts: [String: String] = [:]
    @State private var conditionParameterTexts: [String: String] = [:]
    @State private var conditionNotGates: [String: Bool] = [:]
    @State private var conditionIntervalTexts: [String: String] = [:]
    @State private var conditionThresholdTexts: [String: String] = [:]
    @State private var conditionThresholdInverseTexts: [String: String] = [:]
    /// SupportType1 edits, keyed by state index.
    @State private var type1Motions: [Int: SupportType1.MotionType] = [:]
    @State private var type1Spaces: [Int: SupportType1.SpaceType] = [:]
    @State private var type1Translates: [Int: Bool] = [:]
    @State private var type1Rotates: [Int: Bool] = [:]
    @State private var type1TracksDestination: [Int: Bool] = [:]
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
                type1Section(index: index, type1: type1)
            }

            ForEach(Array(state.bodies.enumerated()), id: \.offset) { bodyIndex, body in
                bodySection(stateIndex: index, index: bodyIndex, body: body)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    private func type1Section(index: Int, type1: SupportType1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SupportType1").font(.caption2.bold())
                Text("(\(type1.floats.count) float(s), \(type1.bytes.count) byte(s), not editable)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Picker("Space", selection: Binding(
                    get: { type1Spaces[index] ?? type1.resolvedSpace ?? .worldSpace },
                    set: { type1Spaces[index] = $0 }
                )) {
                    ForEach(SupportType1.SpaceType.allCases, id: \.self) { space in
                        Text(String(describing: space)).tag(space)
                    }
                }
                .frame(width: 220)

                Picker("Motion", selection: Binding(
                    get: { type1Motions[index] ?? type1.resolvedMotion ?? .noMotion },
                    set: { type1Motions[index] = $0 }
                )) {
                    ForEach(SupportType1.MotionType.allCases, id: \.self) { motion in
                        Text(String(describing: motion)).tag(motion)
                    }
                }
                .frame(width: 220)
            }
            .font(.caption2)

            HStack(spacing: 16) {
                Toggle("Translates", isOn: Binding(
                    get: { type1Translates[index] ?? type1.translates },
                    set: { type1Translates[index] = $0 }
                ))
                Toggle("Rotates", isOn: Binding(
                    get: { type1Rotates[index] ?? type1.rotates },
                    set: { type1Rotates[index] = $0 }
                ))
                Toggle("Tracks Destination", isOn: Binding(
                    get: { type1TracksDestination[index] ?? type1.tracksDestination },
                    set: { type1TracksDestination[index] = $0 }
                ))
                Button("Apply") { applyType1(index: index, type1: type1) }
                    .controlSize(.small)
            }
            .font(.caption2)
            .toggleStyle(.checkbox)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.06)))
    }

    private func bodySection(stateIndex: Int, index: Int, body: ScriptStateBody) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Body #\(index)").font(.caption.bold())
                if !body.isEnabled { Text("(disabled)").font(.caption2).foregroundStyle(.secondary) }
            }
            if let condition = body.condition {
                conditionSection(stateIndex: stateIndex, bodyIndex: index, condition: condition)
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

    private func conditionSection(stateIndex: Int, bodyIndex: Int, condition: ScriptCondition) -> some View {
        let key = "\(stateIndex)-\(bodyIndex)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Condition").font(.caption2.bold())
                Text(ScriptConditionCatalog.conditionName(forID: condition.vTableIndex) ?? "#\(condition.vTableIndex)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("vTable:").font(.caption2)
                TextField("", text: Binding(
                    get: { conditionVTableTexts[key] ?? "\(condition.vTableIndex)" },
                    set: { conditionVTableTexts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .font(.caption2.monospaced())

                Text("Param:").font(.caption2)
                TextField("", text: Binding(
                    get: { conditionParameterTexts[key] ?? "\(condition.parameter)" },
                    set: { conditionParameterTexts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .font(.caption2.monospaced())

                Toggle("NOT", isOn: Binding(
                    get: { conditionNotGates[key] ?? condition.notGate },
                    set: { conditionNotGates[key] = $0 }
                ))
                .toggleStyle(.checkbox)
            }
            .font(.caption2)

            HStack(spacing: 8) {
                Text("Interval:").font(.caption2)
                TextField("", text: Binding(
                    get: { conditionIntervalTexts[key] ?? "\(condition.interval)" },
                    set: { conditionIntervalTexts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.caption2.monospaced())

                Text("Threshold:").font(.caption2)
                TextField("", text: Binding(
                    get: { conditionThresholdTexts[key] ?? "\(condition.threshold)" },
                    set: { conditionThresholdTexts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.caption2.monospaced())

                Text("/Inverse:").font(.caption2)
                TextField("", text: Binding(
                    get: { conditionThresholdInverseTexts[key] ?? "\(condition.thresholdInverse)" },
                    set: { conditionThresholdInverseTexts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(.caption2.monospaced())

                Button("Apply") { applyCondition(stateIndex: stateIndex, bodyIndex: bodyIndex, condition: condition) }
                    .controlSize(.small)
            }
            .font(.caption2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.06)))
    }

    private func setBit(_ raw: UInt32, _ bit: UInt32, _ value: Bool) -> UInt32 {
        value ? (raw | (1 << bit)) : (raw & ~(1 << bit))
    }

    private func applyType1(index: Int, type1: SupportType1) {
        var raw = type1.unkInt1Raw
        let space = type1Spaces[index] ?? type1.resolvedSpace ?? .worldSpace
        let motion = type1Motions[index] ?? type1.resolvedMotion ?? .noMotion
        let translates = type1Translates[index] ?? type1.translates
        let rotates = type1Rotates[index] ?? type1.rotates
        let tracksDestination = type1TracksDestination[index] ?? type1.tracksDestination

        raw &= ~UInt32(0x7)
        raw |= UInt32(space.rawValue) & 0x7
        raw &= ~(UInt32(0xF) << 3)
        raw |= (UInt32(motion.rawValue) & 0xF) << 3
        raw = setBit(raw, 0xD, translates)
        raw = setBit(raw, 0xE, rotates)
        raw = setBit(raw, 0x10, tracksDestination)

        errorMessage = nil
        let encoded = ScriptWriter.writeSupportType1UnkInt1Raw(raw)
        let absoluteOffset = node.fileOffset + type1.unkInt1RawFileOffset
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with state \(index)'s SupportType1 changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with state \(index)'s SupportType1 changed."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }

    private func applyCondition(stateIndex: Int, bodyIndex: Int, condition: ScriptCondition) {
        let key = "\(stateIndex)-\(bodyIndex)"
        let vText = (conditionVTableTexts[key] ?? "\(condition.vTableIndex)").trimmingCharacters(in: .whitespaces)
        let pText = (conditionParameterTexts[key] ?? "\(condition.parameter)").trimmingCharacters(in: .whitespaces)
        let intervalText = (conditionIntervalTexts[key] ?? "\(condition.interval)").trimmingCharacters(in: .whitespaces)
        let thresholdText = (conditionThresholdTexts[key] ?? "\(condition.threshold)").trimmingCharacters(in: .whitespaces)
        let thresholdInverseText = (conditionThresholdInverseTexts[key] ?? "\(condition.thresholdInverse)").trimmingCharacters(in: .whitespaces)

        guard let vTableIndex = UInt16(vText) else {
            errorMessage = "Condition's vTable index (\"\(vText)\") isn't a valid 16-bit integer."
            return
        }
        guard let parameter = UInt16(pText), parameter <= 0x7FFF else {
            errorMessage = "Condition's parameter (\"\(pText)\") isn't a valid 15-bit integer (0–32767)."
            return
        }
        guard let interval = Float(intervalText) else {
            errorMessage = "Condition's interval (\"\(intervalText)\") isn't a valid number."
            return
        }
        guard let threshold = Float(thresholdText) else {
            errorMessage = "Condition's threshold (\"\(thresholdText)\") isn't a valid number."
            return
        }
        guard let thresholdInverse = Float(thresholdInverseText) else {
            errorMessage = "Condition's inverse threshold (\"\(thresholdInverseText)\") isn't a valid number."
            return
        }
        let notGate = conditionNotGates[key] ?? condition.notGate

        errorMessage = nil
        let rawValue = UInt32(vTableIndex) | (notGate ? 0x10000 : 0) | (UInt32(parameter) << 17)
        let newCondition = ScriptCondition(
            unkInt1Raw: Int32(bitPattern: rawValue),
            interval: interval,
            threshold: threshold,
            thresholdInverse: thresholdInverse,
            fileOffset: condition.fileOffset
        )
        let encoded = ScriptWriter.writeCondition(newCondition)
        let absoluteOffset = node.fileOffset + condition.fileOffset
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: node, absoluteOffset: absoluteOffset, encoded: encoded)]) else {
            return
        }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with state \(stateIndex)'s body \(bodyIndex) condition changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with state \(stateIndex)'s condition changed."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
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
