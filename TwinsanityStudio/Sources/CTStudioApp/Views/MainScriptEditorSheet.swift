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
///
/// "AgentLab Phase B": adding/removing a `ScriptState`, `ScriptStateBody`,
/// or `ScriptCommand`, and creating/deleting a `ScriptCondition`, are now
/// real too — `editableMain` is a locally-mutated copy of the record's
/// `MainScript`, and every structural button below (`addState`/
/// `deleteState`/`addBody`/`deleteBody`/`createCondition`/`deleteCondition`/
/// `addCommand`/`deleteCommand`) mutates it, then re-encodes the *entire*
/// record via `ScriptWriter.encode` and replaces it whole in a copy of this
/// file via `WorkspaceViewModel.patchedFileBytes(replacingWholeRecord:with:)`
/// — unlike every fixed-offset patch above, the saved record generally
/// isn't the same byte length as the original.
struct MainScriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let script: ScriptAsset

    /// Locally-mutated working copy of the record's `MainScript` — every
    /// structural edit (add/delete state/body/command, create/delete
    /// condition) mutates this directly; every field-level "Apply" button
    /// above still patches straight into a copy of the *original* file
    /// bytes, same as before, since those are all same-size patches that
    /// don't need this record's own structure re-derived.
    @State private var editableMain: MainScript

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
    /// New-command ID text, keyed by `"stateIndex-bodyIndex"`.
    @State private var newCommandIDTexts: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, script: ScriptAsset, mainScript: MainScript) {
        self.node = node
        self.script = script
        self._editableMain = State(initialValue: mainScript)
    }

    /// Which per-platform command-size table applies to this record —
    /// mirrors the reference's own `ParentType` check in `Script.Load`/
    /// `CodeModel.Load` (`ScriptX`/`CustomAgentX` -> Xbox, `ScriptDemo`/
    /// `CustomAgentDemo` -> Demo, everything else, including the
    /// unsupported-elsewhere `ScriptMB`, -> PS2), read directly from this
    /// leaf record's own `SectionType` rather than needing the enclosing
    /// file's kind threaded in separately.
    private var platform: AgentLabPlatformVariant {
        switch node.sectionType {
        case .scriptX: return .xbox
        case .scriptDemo: return .demo
        default: return .ps2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Main Script — \(editableMain.name.isEmpty ? "<unnamed>" : editableMain.name)").font(.title3.bold())
                Text("Real write-back: redirecting a state's script/slot, editing a command's arguments, or adding/removing a state/body/command/condition, each saves its own edited copy of this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Start Unit") { Text("\(editableMain.startUnit)") }
                    HStack {
                        LabeledContent("Actual State Count") { Text("\(editableMain.states.count)") }
                        Spacer()
                        Button("Add State") { addState() }
                            .controlSize(.small)
                            .disabled(!workspace.canSaveEdits(for: node))
                    }

                    ForEach(Array(editableMain.states.enumerated()), id: \.offset) { index, state in
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
            HStack {
                Text("State #\(index)").font(.callout.bold())
                Spacer()
                Button("Add Body") { addBody(stateIndex: index) }
                    .controlSize(.small)
                    .disabled(!workspace.canSaveEdits(for: node))
                Button("Delete State", role: .destructive) { deleteState(index: index) }
                    .controlSize(.small)
                    .disabled(!workspace.canSaveEdits(for: node))
            }
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
        let key = "\(stateIndex)-\(index)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Body #\(index)").font(.caption.bold())
                if !body.isEnabled { Text("(disabled)").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if body.condition == nil {
                    Button("Create Condition") { createCondition(stateIndex: stateIndex, bodyIndex: index) }
                        .controlSize(.small)
                        .disabled(!workspace.canSaveEdits(for: node))
                } else {
                    Button("Delete Condition", role: .destructive) { deleteCondition(stateIndex: stateIndex, bodyIndex: index) }
                        .controlSize(.small)
                        .disabled(!workspace.canSaveEdits(for: node))
                }
                Button("Delete Body", role: .destructive) { deleteBody(stateIndex: stateIndex, bodyIndex: index) }
                    .controlSize(.small)
                    .disabled(!workspace.canSaveEdits(for: node))
            }
            if let condition = body.condition {
                conditionSection(stateIndex: stateIndex, bodyIndex: index, condition: condition)
            }
            ForEach(Array(body.commands.enumerated()), id: \.offset) { commandIndex, command in
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
                    Button("Delete", role: .destructive) { deleteCommand(stateIndex: stateIndex, bodyIndex: index, commandIndex: commandIndex) }
                        .controlSize(.small)
                        .disabled(!workspace.canSaveEdits(for: node))
                }
            }
            HStack(spacing: 8) {
                Text("New command ID:").font(.caption2)
                TextField("", text: Binding(
                    get: { newCommandIDTexts[key] ?? "" },
                    set: { newCommandIDTexts[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .font(.caption2.monospaced())
                Button("Add Command") { addCommand(stateIndex: stateIndex, bodyIndex: index) }
                    .controlSize(.small)
                    .disabled(!workspace.canSaveEdits(for: node))
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

    // MARK: - AgentLab Phase B: structural edits

    private func addState() {
        editableMain.states.append(ScriptState(bitfieldRaw: 0, scriptIndexOrSlot: -1, type1: nil, bodies: []))
        saveStructuralChange(description: "a new state added")
    }

    private func deleteState(index: Int) {
        guard editableMain.states.indices.contains(index) else { return }
        editableMain.states.remove(at: index)
        saveStructuralChange(description: "state \(index) deleted")
    }

    private func addBody(stateIndex: Int) {
        guard editableMain.states.indices.contains(stateIndex) else { return }
        editableMain.states[stateIndex].bodies.append(ScriptStateBody(bitfieldRaw: 0, scriptStateListIndex: nil, condition: nil, commands: []))
        saveStructuralChange(description: "a new body added to state \(stateIndex)")
    }

    private func deleteBody(stateIndex: Int, bodyIndex: Int) {
        guard editableMain.states.indices.contains(stateIndex),
              editableMain.states[stateIndex].bodies.indices.contains(bodyIndex)
        else { return }
        editableMain.states[stateIndex].bodies.remove(at: bodyIndex)
        saveStructuralChange(description: "state \(stateIndex)'s body \(bodyIndex) deleted")
    }

    private func createCondition(stateIndex: Int, bodyIndex: Int) {
        guard editableMain.states.indices.contains(stateIndex),
              editableMain.states[stateIndex].bodies.indices.contains(bodyIndex)
        else { return }
        // Matches the reference's own `ScriptStateBody.CreateCondition`
        // defaults (`unkInt1 = 0`, `Interval = 0`, `Threshold = 0.5`,
        // `ThresholdInverse = 2.0`).
        editableMain.states[stateIndex].bodies[bodyIndex].condition = ScriptCondition(unkInt1Raw: 0, interval: 0, threshold: 0.5, thresholdInverse: 2.0)
        saveStructuralChange(description: "a condition created on state \(stateIndex)'s body \(bodyIndex)")
    }

    private func deleteCondition(stateIndex: Int, bodyIndex: Int) {
        guard editableMain.states.indices.contains(stateIndex),
              editableMain.states[stateIndex].bodies.indices.contains(bodyIndex)
        else { return }
        editableMain.states[stateIndex].bodies[bodyIndex].condition = nil
        saveStructuralChange(description: "state \(stateIndex)'s body \(bodyIndex) condition deleted")
    }

    private func addCommand(stateIndex: Int, bodyIndex: Int) {
        guard editableMain.states.indices.contains(stateIndex),
              editableMain.states[stateIndex].bodies.indices.contains(bodyIndex)
        else { return }
        let key = "\(stateIndex)-\(bodyIndex)"
        let text = (newCommandIDTexts[key] ?? "").trimmingCharacters(in: .whitespaces)
        guard let commandID = UInt16(text) else {
            errorMessage = "New command ID (\"\(text)\") isn't a valid 16-bit integer."
            return
        }
        errorMessage = nil
        let size = AgentLabCommandCatalog.commandSize(forID: commandID, platform: platform)
        let argCount = size > 0x0C ? (size - 0x0C) / 4 : 0
        let command = AgentLabCommand(
            commandID: commandID,
            unkShort: 0,
            commandName: AgentLabCommandCatalog.commandName(forID: commandID),
            rawArguments: Array(repeating: 0, count: argCount),
            decoded: AgentLabActionDecoder.decode(commandID: commandID, arguments: Array(repeating: 0, count: argCount)),
            fileOffset: 0
        )
        editableMain.states[stateIndex].bodies[bodyIndex].commands.append(command)
        newCommandIDTexts[key] = ""
        saveStructuralChange(description: "a new command added to state \(stateIndex)'s body \(bodyIndex)")
    }

    private func deleteCommand(stateIndex: Int, bodyIndex: Int, commandIndex: Int) {
        guard editableMain.states.indices.contains(stateIndex),
              editableMain.states[stateIndex].bodies.indices.contains(bodyIndex),
              editableMain.states[stateIndex].bodies[bodyIndex].commands.indices.contains(commandIndex)
        else { return }
        editableMain.states[stateIndex].bodies[bodyIndex].commands.remove(at: commandIndex)
        saveStructuralChange(description: "state \(stateIndex)'s body \(bodyIndex) command \(commandIndex) deleted")
    }

    /// Shared save path for every structural edit above: re-encodes the
    /// *entire* current `editableMain` via `ScriptWriter.encode` and
    /// replaces this record whole (not a fixed-offset patch) via
    /// `WorkspaceViewModel.patchedFileBytes(replacingWholeRecord:with:)`.
    private func saveStructuralChange(description: String) {
        let mutatedAsset = ScriptAsset(id: script.id, inlineID: script.inlineID, mask: script.mask, flag: script.flag, content: .main(editableMain), trailingBytes: script.trailingBytes)
        let encoded = ScriptWriter.encode(mutatedAsset)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with \(description). The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with \(description)."
                isSaving = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
