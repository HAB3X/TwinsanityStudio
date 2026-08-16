import SwiftUI
import CTModels
import CTParsers

/// "Parity Phase D": write-back editor for a decoded `GameObject` record —
/// ports `Editors/ObjectEditor.cs`'s field set (minus create/delete/
/// duplicate-object, which need chunk-section-insert wiring for a brand-new
/// record ID and are out of scope for this pass; editing an *existing*
/// object's own data is the real gap this fills). Unlike every field-level
/// "Apply" sheet elsewhere in this app, `GameObject` has no individually
/// offset-patchable fields worth the complexity — `ScriptSlots`/`PHeader`/
/// `LinkedIDs.flag` are all derived caches recomputed from list contents on
/// save (see `GameObjectWriter`), so any edit here already needs a whole-
/// record re-encode. One editable working copy, one "Save Edited Copy…"
/// button, same as `SkydomeEditorSheet`'s simpler pattern.
struct GameObjectEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode

    @State private var editableObject: GameObjectInfo
    @State private var editingCommand: AgentLabCommand?
    @State private var newCommandIDText = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, gameObject: GameObjectInfo) {
        self.node = node
        _editableObject = State(initialValue: gameObject)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("GameObject — \(editableObject.name.isEmpty ? "<unnamed>" : editableObject.name)").font(.title3.bold())
                Text("Real write-back: every change here re-encodes and saves the whole record as an edited copy of this file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    generalSection
                    idListsSection
                    instancePropertiesSection
                    linkedIDsSection
                    scriptCommandsSection
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
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 600)
        .sheet(item: $editingCommand) { command in
            AgentLabArgumentEditorSheet(node: node, command: command)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("General").font(.callout.bold())
            LabeledContent("Object ID") { Text("\(editableObject.id)").font(.caption.monospaced()) }
            LabeledContent("Name") {
                TextField("", text: $editableObject.name).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 12) {
                Picker("Object Type", selection: Binding(
                    get: { editableObject.resolvedObjectType },
                    set: { newValue in guard let newValue else { return }; setBitfieldField(mask: 0xFF, shift: 0x14, value: UInt32(newValue.rawValue)) }
                )) {
                    Text("(raw \(editableObject.objectTypeRaw))").tag(GameObjectInfo.ObjectTypeID?.none)
                    ForEach(GameObjectInfo.ObjectTypeID.allCases, id: \.self) { type in
                        Text(String(describing: type)).tag(GameObjectInfo.ObjectTypeID?.some(type))
                    }
                }
                .frame(width: 240)

                Picker("Mobile Type", selection: Binding(
                    get: { editableObject.resolvedMobileType },
                    set: { newValue in guard let newValue else { return }; setBitfieldField(mask: 0xFF, shift: 0xC, value: UInt32(newValue.rawValue)) }
                )) {
                    Text("(raw \(editableObject.mobileTypeRaw))").tag(GameObjectInfo.MobileTypeID?.none)
                    ForEach(GameObjectInfo.MobileTypeID.allCases, id: \.self) { type in
                        Text(String(describing: type)).tag(GameObjectInfo.MobileTypeID?.some(type))
                    }
                }
                .frame(width: 220)
            }
            .font(.caption)

            HStack(spacing: 16) {
                Stepper("Joint IDs: \(editableObject.jointIDCount)", value: Binding(
                    get: { Int(editableObject.jointIDCount) },
                    set: { setBitfieldField(mask: 0x3F, shift: 0x6, value: UInt32(clamping: $0)) }
                ), in: 0...63)
                Stepper("Exit Points: \(editableObject.exitPointCount)", value: Binding(
                    get: { Int(editableObject.exitPointCount) },
                    set: { setBitfieldField(mask: 0x3F, shift: 0x0, value: UInt32(clamping: $0)) }
                ), in: 0...63)
            }
            .font(.caption)

            HStack(spacing: 16) {
                Toggle("Use Template", isOn: Binding(
                    get: { editableObject.useTemplate },
                    set: { setBitfieldBit(0x1C, $0) }
                ))
                Toggle("Bitfield Flag 4", isOn: Binding(
                    get: { editableObject.bitfieldFlag4 },
                    set: { setBitfieldBit(0x1F, $0) }
                ))
            }
            .font(.caption)
            .toggleStyle(.checkbox)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    /// Replaces an arbitrary-width field within `unkBitfield` at `shift`,
    /// masked to `mask` bits — same "clear then OR in" pattern
    /// `MainScriptEditorSheet.applyType1` already uses for `SupportType1.
    /// unkInt1Raw`.
    private func setBitfieldField(mask: UInt32, shift: UInt32, value: UInt32) {
        editableObject.unkBitfield &= ~(mask << shift)
        editableObject.unkBitfield |= (value & mask) << shift
    }

    private func setBitfieldBit(_ bit: UInt32, _ value: Bool) {
        if value { editableObject.unkBitfield |= (1 << bit) } else { editableObject.unkBitfield &= ~(1 << bit) }
    }

    // MARK: - ID lists

    private var idListsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ID Lists").font(.callout.bold())
            uint32ListEditor(title: "UI32 (Events)", values: $editableObject.ui32)
            uint32ListEditor(title: "Graphics Info (OGI) Links", values: $editableObject.ogiIDs)
            uint16ListEditor(title: "Animations", values: $editableObject.animIDs)
            uint16ListEditor(title: "Scripts", values: $editableObject.scriptIDs)
            uint16ListEditor(title: "Objects", values: $editableObject.objectIDs)
            uint16ListEditor(title: "Sounds", values: $editableObject.soundIDs)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
    }

    // MARK: - Instance properties ("Template")

    private var instancePropertiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Instance Properties (Template)").font(.callout.bold())
                Spacer()
                Toggle("Present", isOn: Binding(
                    get: { editableObject.instanceProperties != nil },
                    set: { present in
                        if present {
                            editableObject.unkBitfield |= 0x2000_0000
                            if editableObject.instanceProperties == nil {
                                editableObject.instanceProperties = GameObjectInfo.InstanceProperties(pHeader: 0, pUI32: 0, flags: [], floats: [], integers: [])
                            }
                        } else {
                            editableObject.unkBitfield &= ~0x2000_0000
                            editableObject.instanceProperties = nil
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            if editableObject.instanceProperties != nil {
                LabeledContent("PUI32 (Flags)") {
                    TextField("", text: Binding(
                        get: { "\(editableObject.instanceProperties?.pUI32 ?? 0)" },
                        set: { if let v = UInt32($0) { editableObject.instanceProperties?.pUI32 = v } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                }
                .font(.caption)
                uint32ListEditor(title: "Instance Flags", values: Binding(
                    get: { editableObject.instanceProperties?.flags ?? [] },
                    set: { editableObject.instanceProperties?.flags = $0 }
                ))
                floatListEditor(title: "Instance Floats", values: Binding(
                    get: { editableObject.instanceProperties?.floats ?? [] },
                    set: { editableObject.instanceProperties?.floats = $0 }
                ))
                uint32ListEditor(title: "Instance Integers", values: Binding(
                    get: { editableObject.instanceProperties?.integers ?? [] },
                    set: { editableObject.instanceProperties?.integers = $0 }
                ))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.06)))
    }

    // MARK: - Linked IDs ("Resources")

    private var linkedIDsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Linked Resource IDs").font(.callout.bold())
                Spacer()
                Toggle("Present", isOn: Binding(
                    get: { editableObject.linkedIDs != nil },
                    set: { present in
                        if present {
                            editableObject.unkBitfield |= 0x4000_0000
                            if editableObject.linkedIDs == nil {
                                editableObject.linkedIDs = GameObjectInfo.LinkedIDs(flag: 0, objects: [], ogis: [], anims: [], codeModels: [], scripts: [], unk: [], sounds: [])
                            }
                        } else {
                            editableObject.unkBitfield &= ~0x4000_0000
                            editableObject.linkedIDs = nil
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            if editableObject.linkedIDs != nil {
                Text("Each list's presence bit is recomputed on save from whether it's non-empty — no separate toggle needed per list.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                uint16ListEditor(title: "Linked Objects", values: Binding(get: { editableObject.linkedIDs?.objects ?? [] }, set: { editableObject.linkedIDs?.objects = $0 }))
                uint16ListEditor(title: "Linked OGIs", values: Binding(get: { editableObject.linkedIDs?.ogis ?? [] }, set: { editableObject.linkedIDs?.ogis = $0 }))
                uint16ListEditor(title: "Linked Animations", values: Binding(get: { editableObject.linkedIDs?.anims ?? [] }, set: { editableObject.linkedIDs?.anims = $0 }))
                uint16ListEditor(title: "Linked Code Models", values: Binding(get: { editableObject.linkedIDs?.codeModels ?? [] }, set: { editableObject.linkedIDs?.codeModels = $0 }))
                uint16ListEditor(title: "Linked Scripts", values: Binding(get: { editableObject.linkedIDs?.scripts ?? [] }, set: { editableObject.linkedIDs?.scripts = $0 }))
                uint16ListEditor(title: "Linked Unknown", values: Binding(get: { editableObject.linkedIDs?.unk ?? [] }, set: { editableObject.linkedIDs?.unk = $0 }))
                uint16ListEditor(title: "Linked Sounds", values: Binding(get: { editableObject.linkedIDs?.sounds ?? [] }, set: { editableObject.linkedIDs?.sounds = $0 }))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.06)))
    }

    // MARK: - Script commands

    private var scriptCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Script Commands (\(editableObject.scriptCommands.count))").font(.callout.bold())
            ForEach(Array(editableObject.scriptCommands.enumerated()), id: \.offset) { index, command in
                HStack {
                    Text(command.commandName ?? "Command #\(command.commandID)")
                        .font(.caption.monospaced())
                    Text("(\(command.rawArguments.count) arg\(command.rawArguments.count == 1 ? "" : "s"))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Arguments…") { editingCommand = command }
                        .controlSize(.small)
                        .disabled(!workspace.canSaveEdits(for: node) || command.fileOffset == 0)
                        .help(command.fileOffset == 0 ? "Save, then reopen the saved file, before editing this newly-added command's arguments — it has no real on-disk offset yet." : "")
                    Button("Delete", role: .destructive) { editableObject.scriptCommands.remove(at: index) }
                        .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Text("New command ID:").font(.caption2)
                TextField("", text: $newCommandIDText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .font(.caption2.monospaced())
                Button("Add Command") { addCommand() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.06)))
    }

    private func addCommand() {
        let text = newCommandIDText.trimmingCharacters(in: .whitespaces)
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
        editableObject.scriptCommands.append(command)
        newCommandIDText = ""
    }

    /// Which per-platform command-size table applies — same reasoning as
    /// `MainScriptEditorSheet.platform`, read from this leaf record's own
    /// `SectionType` (`.objectDemo` -> demo, everything else -> PS2; there
    /// is no `.objectX` on disk, matching `TwinsFileKind`'s own coverage).
    private var platform: AgentLabPlatformVariant {
        node.sectionType == .objectDemo ? .demo : .ps2
    }

    // MARK: - Generic list editors

    @ViewBuilder
    private func uint32ListEditor(title: String, values: Binding<[UInt32]>) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = UInt32($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func uint16ListEditor(title: String, values: Binding<[UInt16]>) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = UInt16($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func floatListEditor(title: String, values: Binding<[Float]>) -> some View {
        DisclosureGroup("\(title) (\(values.wrappedValue.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(values.wrappedValue.indices, id: \.self) { i in
                    HStack {
                        TextField("value", text: Binding(
                            get: { "\(values.wrappedValue[i])" },
                            set: { if let v = Float($0) { values.wrappedValue[i] = v } }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        Button(role: .destructive) { values.wrappedValue.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add") { values.wrappedValue.append(0) }
                    .controlSize(.small)
            }
            .padding(.leading, 8)
        }
        .font(.caption)
    }

    private func save() {
        errorMessage = nil
        let encoded = GameObjectWriter.encode(editableObject)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this GameObject changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with GameObject #\(editableObject.id) changed."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
