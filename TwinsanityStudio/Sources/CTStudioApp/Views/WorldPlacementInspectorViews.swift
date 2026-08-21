import SwiftUI
import CTModels
import CTParsers
import CTExport
import simd

/// Phase 3.4 property inspectors: plain-language `Form`s over the raw
/// `Position`/`Instance`/`Trigger` records, so browsing the placement data
/// no longer means eyeballing hex. Read-only for now — there's no
/// write-back/repackage path wired to the UI yet, so these mirror
/// `MaterialInspectorView`/`TextureInspectorView` rather than promising
/// in-place editing.
/// "Editing GUI" proof of concept: the one record type in this build with
/// a real write path all the way through (see `WorldPlacementWriter`,
/// `WorkspaceViewModel.patchedFileBytes`). Every other inspector in this
/// file stays read-only — this one specifically demonstrates decode -> edit
/// -> encode -> patch -> save, not "editing everywhere now."
struct PositionInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let position: PositionMarker

    @State private var x: String = ""
    @State private var y: String = ""
    @State private var z: String = ""
    @State private var w: String = ""
    @State private var isCrateSheetPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Point") {
                    LabeledContent("X") { TextField("X", text: $x).textFieldStyle(.roundedBorder) }
                    LabeledContent("Y") { TextField("Y", text: $y).textFieldStyle(.roundedBorder) }
                    LabeledContent("Z") { TextField("Z", text: $z).textFieldStyle(.roundedBorder) }
                    LabeledContent("W") { TextField("W", text: $w).textFieldStyle(.roundedBorder) }
                }
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            HStack {
                Button("Copy Viewer Pos") { copyViewerPosition() }
                    .disabled(workspace.currentViewerCameraPositionProvider?() == nil)
                    .help("Fills X/Y/Z from the currently open Level Viewer's camera — same as the reference editor's own \"Copy Viewer Pos.\"")
                Spacer()
            }
            .padding(.horizontal)

            HStack {
                Button("Save Edited Copy…") { save() }
                    .disabled(editedPoint == nil || !workspace.canSaveEdits(for: node))
                Button("Export as Mod Crate…") { isCrateSheetPresented = true }
                    .disabled(editedPoint == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            Divider().padding(.vertical, 4)

            HStack {
                Button("Add Position…") { addPosition() }
                    .disabled(!workspace.canSaveEdits(for: node) || workspace.positionCollectionNode(inSameFileAs: node) == nil)
                Button("Duplicate…") { duplicatePosition() }
                    .disabled(!workspace.canSaveEdits(for: node))
                Button("Delete…", role: .destructive) { deletePosition() }
                    .disabled(!workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)
            Text("Add/Duplicate/Delete are real structural edits (a new or removed record, not just a field patch) — each immediately prompts for where to save the edited copy, same as every other write path in this app.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if !workspace.canSaveEdits(for: node) {
                Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this record's file is archive-packed, which this build doesn't have a write path for yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                Text("Saves an edited copy under a new name — the file you opened is never modified in place. \"Export as Mod Crate…\" packages the same edited bytes into a real CrateModLoader-installable .crate instead of a loose file.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .sheet(isPresented: $isCrateSheetPresented) {
            if let patchedBytes = patchedBytesForCrate() {
                CrateExportSheet(suggestedName: "\(node.displayName) Edit") { metadata, url in
                    let originalName = workspace.originalFileName(for: node) ?? node.displayName
                    workspace.exportAsCrate(patchedBytes: patchedBytes, originalFileName: originalName, metadata: metadata, to: url)
                }
            }
        }
    }

    /// Re-derives the patched bytes on demand for the crate sheet — mirrors
    /// `save()`'s own encode-and-patch step rather than caching a stale copy
    /// from whenever the button was clicked, so editing the fields further
    /// while the sheet is closed is always reflected next time it opens.
    private func patchedBytesForCrate() -> Data? {
        guard let point = editedPoint else { return nil }
        let edited = PositionMarker(id: position.id, point: point)
        let encoded = WorldPlacementWriter.writePosition(edited)
        return workspace.patchedFileBytes(replacing: node, with: encoded)
    }

    private func loadFields() {
        x = String(position.point.x)
        y = String(position.point.y)
        z = String(position.point.z)
        w = String(position.point.w)
    }

    private var editedPoint: SIMD4<Float>? {
        guard let fx = Float(x), let fy = Float(y), let fz = Float(z), let fw = Float(w) else { return nil }
        return SIMD4(fx, fy, fz, fw)
    }

    private func save() {
        guard let point = editedPoint else { return }
        let edited = PositionMarker(id: position.id, point: point)
        let encoded = WorldPlacementWriter.writePosition(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        saveAsCopy(patchedBytes, suffix: "edited")
    }

    /// Fills X/Y/Z (never W — that's a homogeneous-coordinate marker flag
    /// on this record type, not part of "where the camera is") from
    /// whichever Level Viewer is currently open, same "ask right now"
    /// semantics as the reference editor's own button — see
    /// `WorkspaceViewModel.currentViewerCameraPositionProvider`'s doc
    /// comment.
    private func copyViewerPosition() {
        guard let eye = workspace.currentViewerCameraPositionProvider?() else { return }
        x = String(eye.x)
        y = String(eye.y)
        z = String(eye.z)
    }

    /// A fresh record at the origin (`0,0,0,1`) — same default the
    /// reference editor's own "Add" uses (`new Pos(0, 0, 0, 1)`), not a
    /// copy of whatever's currently selected (that's "Duplicate"'s job).
    private func addPosition() {
        guard let patchedBytes = workspace.patchedFileBytes(insertingPosition: SIMD4<Float>(0, 0, 0, 1), inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "position_added")
    }

    /// Inserts a copy of *this* record (its currently-edited field values,
    /// not necessarily what's still on disk) as a brand-new record with
    /// its own fresh ID, offset `+1` on Y — same offset the reference
    /// editor's own "Duplicate" applies, so the copy doesn't land exactly
    /// on top of the original. The original record is untouched either
    /// way.
    private func duplicatePosition() {
        guard let point = editedPoint else { return }
        let offsetPoint = SIMD4<Float>(point.x, point.y + 1, point.z, point.w)
        guard let patchedBytes = workspace.patchedFileBytes(insertingPosition: offsetPoint, inSameFileAs: node) else { return }
        saveAsCopy(patchedBytes, suffix: "position_duplicated")
    }

    private func deletePosition() {
        guard let patchedBytes = workspace.patchedFileBytes(removingPosition: node) else { return }
        saveAsCopy(patchedBytes, suffix: "position_deleted")
    }

    private func saveAsCopy(_ patchedBytes: Data, suffix: String) {
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_\(suffix).rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
            } catch {
                workspace.lastError = "Save failed: \(error)"
            }
        }
    }
}

/// "Direct .RM2 Write-Back": position/rotation save through the fast,
/// fixed-size transform-prefix patch `PositionInspectorView` established
/// (`WorldPlacementWriter.writeInstanceTransform`) whenever only those
/// change size-unchanged. Everything else on the record — the three child
/// ID lists, `objectID`/`refList`/`scriptID`, and the three undocumented
/// trailing lists — is *also* now writable, through
/// `WorldPlacementWriter.writeInstance` (a full, arbitrary-field encoder)
/// and `WorkspaceViewModel.patchedFileBytes(replacingWholeRecord:with:)`,
/// since editing a list's length changes this record's total on-disk
/// size. Two separate "Save" buttons reflect that split: the fast prefix
/// patch for the common case (just moving something), and "Save Full
/// Record…" when a list actually changed.
struct InstanceInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let instance: PlacedInstance

    @State private var x: String = ""
    @State private var y: String = ""
    @State private var z: String = ""
    @State private var w: String = ""
    @State private var rotX: String = ""
    @State private var rotY: String = ""
    @State private var rotZ: String = ""
    @State private var isEditingFlags = false
    @State private var objectIDText = ""
    @State private var refListText = ""
    @State private var scriptIDText = ""
    @State private var childInstanceIDsText = ""
    @State private var childPositionIDsText = ""
    @State private var childPathIDsText = ""
    @State private var unknownUInt32ListText = ""
    @State private var unknownFloatListText = ""
    @State private var unknownUInt32List2Text = ""
    @State private var fullRecordError: String?
    @State private var isSavingFullRecord = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Placement") {
                    LabeledContent("X") { TextField("X", text: $x).textFieldStyle(.roundedBorder) }
                    LabeledContent("Y") { TextField("Y", text: $y).textFieldStyle(.roundedBorder) }
                    LabeledContent("Z") { TextField("Z", text: $z).textFieldStyle(.roundedBorder) }
                    LabeledContent("W") { TextField("W", text: $w).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation X°") { TextField("X°", text: $rotX).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation Y°") { TextField("Y°", text: $rotY).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation Z°") { TextField("Z°", text: $rotZ).textFieldStyle(.roundedBorder) }
                    LabeledContent("COM Rotation", value: degreesString(SIMD3(
                        PlacedInstance.degrees(fromRawAngle: instance.comRotationRaw.x),
                        PlacedInstance.degrees(fromRawAngle: instance.comRotationRaw.y),
                        PlacedInstance.degrees(fromRawAngle: instance.comRotationRaw.z)
                    )))
                }
                Section("Identity") {
                    LabeledContent("Object ID") { TextField("", text: $objectIDText).textFieldStyle(.roundedBorder) }
                    LabeledContent("Script ID") { TextField("-1 = none", text: $scriptIDText).textFieldStyle(.roundedBorder) }
                    LabeledContent("Ref List") { TextField("-1 = none", text: $refListText).textFieldStyle(.roundedBorder) }
                    LabeledContent("Flags") {
                        HStack {
                            Text("0x\(String(instance.flags, radix: 16))")
                            Button("Edit…") { isEditingFlags = true }
                                .disabled(!workspace.canSaveEdits(for: node))
                        }
                    }
                }
                Section("Child Instances") {
                    idListField($childInstanceIDsText)
                }
                Section("Referenced Positions") {
                    idListField($childPositionIDsText)
                }
                Section("Referenced Paths") {
                    idListField($childPathIDsText)
                }
                Section("Undocumented Lists (real data, no confirmed meaning)") {
                    LabeledContent("UInt32 List") { TextField("comma-separated", text: $unknownUInt32ListText).textFieldStyle(.roundedBorder) }
                    LabeledContent("Float List") { TextField("comma-separated", text: $unknownFloatListText).textFieldStyle(.roundedBorder) }
                    LabeledContent("UInt32 List 2") { TextField("comma-separated", text: $unknownUInt32List2Text).textFieldStyle(.roundedBorder) }
                }
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            HStack {
                Button("Save Edited Copy…") { save() }
                    .disabled(editedTransform == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            if !workspace.canSaveEdits(for: node) {
                Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this record's file is archive-packed, which this build doesn't have a write path for yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                Text("\"Save Edited Copy…\" is the fast, fixed-size patch for position/rotation only. Editing any list above changes this record's total size — use \"Save Full Record…\" below for those.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Divider().padding(.vertical, 4)
            HStack {
                Button(isSavingFullRecord ? "Saving…" : "Save Full Record…") { saveFullRecord() }
                    .disabled(isSavingFullRecord || editedFullRecord == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)
            if let fullRecordError {
                Text(fullRecordError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            } else {
                Text("Re-encodes and saves the *whole* record — every field above, including list lengths — as an edited copy.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .sheet(isPresented: $isEditingFlags) {
            InstanceFlagsEditorSheet(node: node, instance: instance)
        }
    }

    private func idListField(_ text: Binding<String>) -> some View {
        TextField("comma-separated IDs", text: text)
            .textFieldStyle(.roundedBorder)
    }

    private func loadFields() {
        x = String(instance.position.x)
        y = String(instance.position.y)
        z = String(instance.position.z)
        w = String(instance.position.w)
        rotX = String(format: "%.2f", instance.rotationDegrees.x)
        rotY = String(format: "%.2f", instance.rotationDegrees.y)
        rotZ = String(format: "%.2f", instance.rotationDegrees.z)
        objectIDText = "\(instance.objectID)"
        refListText = "\(instance.refList)"
        scriptIDText = "\(instance.scriptID)"
        childInstanceIDsText = instance.childInstanceIDs.map { "\($0)" }.joined(separator: ", ")
        childPositionIDsText = instance.childPositionIDs.map { "\($0)" }.joined(separator: ", ")
        childPathIDsText = instance.childPathIDs.map { "\($0)" }.joined(separator: ", ")
        unknownUInt32ListText = instance.unknownUInt32List.map { "\($0)" }.joined(separator: ", ")
        unknownFloatListText = instance.unknownFloatList.map { "\($0)" }.joined(separator: ", ")
        unknownUInt32List2Text = instance.unknownUInt32List2.map { "\($0)" }.joined(separator: ", ")
        fullRecordError = nil
    }

    /// Parses a comma/whitespace-separated list of `UInt16` IDs — empty
    /// input decodes to an empty list, not a parse failure (a record with
    /// no child references is entirely normal).
    private static func parseUInt16List(_ text: String) -> [UInt16]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let parsed = parts.map { UInt16($0) }
        return parsed.allSatisfy { $0 != nil } ? parsed.compactMap { $0 } : nil
    }

    private static func parseUInt32List(_ text: String) -> [UInt32]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let parsed = parts.map { UInt32($0) }
        return parsed.allSatisfy { $0 != nil } ? parsed.compactMap { $0 } : nil
    }

    private static func parseFloatList(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let parsed = parts.map { Float($0) }
        return parsed.allSatisfy { $0 != nil } ? parsed.compactMap { $0 } : nil
    }

    /// Every field the "Save Full Record…" button writes — built fresh
    /// from `instance` plus every staged text field, `nil` if anything
    /// fails to parse. `someNum1`/`2`/`3` are always carried through
    /// unedited from `instance` — no UI exposes them (the reference tool
    /// itself has none either; see `PlacedInstance.someNum1`'s own doc
    /// comment), just preserved so this save never corrupts them.
    private var editedFullRecord: PlacedInstance? {
        guard let objectID = UInt16(objectIDText.trimmingCharacters(in: .whitespaces)),
              let refList = Int16(refListText.trimmingCharacters(in: .whitespaces)),
              let scriptID = Int16(scriptIDText.trimmingCharacters(in: .whitespaces)),
              let childInstanceIDs = Self.parseUInt16List(childInstanceIDsText),
              let childPositionIDs = Self.parseUInt16List(childPositionIDsText),
              let childPathIDs = Self.parseUInt16List(childPathIDsText),
              let unknownUInt32List = Self.parseUInt32List(unknownUInt32ListText),
              let unknownFloatList = Self.parseFloatList(unknownFloatListText),
              let unknownUInt32List2 = Self.parseUInt32List(unknownUInt32List2Text)
        else { return nil }
        return PlacedInstance(
            id: instance.id, position: instance.position, rotationRaw: instance.rotationRaw, comRotationRaw: instance.comRotationRaw,
            childInstanceIDs: childInstanceIDs, childPositionIDs: childPositionIDs, childPathIDs: childPathIDs,
            someNum1: instance.someNum1, someNum2: instance.someNum2, someNum3: instance.someNum3,
            objectID: objectID, refList: refList, scriptID: scriptID, flags: instance.flags,
            unknownUInt32List: unknownUInt32List, unknownFloatList: unknownFloatList, unknownUInt32List2: unknownUInt32List2
        )
    }

    private func saveFullRecord() {
        guard let edited = editedFullRecord else {
            fullRecordError = "One or more fields don't parse — IDs must be whole numbers, lists comma-separated."
            return
        }
        fullRecordError = nil
        let encoded = WorldPlacementWriter.writeInstance(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacingWholeRecord: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this Instance's full record changed. The original file on disk is not modified."
        ) else { return }
        isSavingFullRecord = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this Instance's full record changed."
                isSavingFullRecord = false
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSavingFullRecord = false
            }
        }
    }

    private var editedTransform: (position: SIMD4<Float>, rotationRaw: SIMD3<UInt16>)? {
        guard let fx = Float(x), let fy = Float(y), let fz = Float(z), let fw = Float(w),
              let frx = Float(rotX), let fry = Float(rotY), let frz = Float(rotZ)
        else { return nil }
        return (SIMD4(fx, fy, fz, fw), SIMD3(
            PlacedInstance.rawAngle(fromDegrees: frx),
            PlacedInstance.rawAngle(fromDegrees: fry),
            PlacedInstance.rawAngle(fromDegrees: frz)
        ))
    }

    private func save() {
        guard let edited = editedTransform else { return }
        let encoded = WorldPlacementWriter.writeInstanceTransform(position: edited.position, rotationRaw: edited.rotationRaw, comRotationRaw: instance.comRotationRaw)
        guard let patchedBytes = workspace.patchedFileBytes(replacingPrefixOf: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_edited.rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
            } catch {
                workspace.lastError = "Save failed: \(error)"
            }
        }
    }
}

/// "Make Trigger/Camera inspectors writable": position/size/rotation are
/// editable and save through the same decode -> edit -> encode -> patch ->
/// save-as-copy loop `PositionInspectorView`/`InstanceInspectorView`
/// established — see `WorldPlacementWriter.writeTriggerOrCameraPrefix`'s
/// doc comment for why only this leading fixed-size prefix (not the whole
/// variable-length record) is writable. `header`/`enabledMask`/`someFloat`/
/// `arg1`-`arg4` stay read-only and round-trip through unedited: their bit
/// patterns carry no decoded meaning anywhere in this codebase, so exposing
/// them as editable fields would invite editing values whose effect is
/// genuinely unknown, not a real capability.
struct TriggerInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let trigger: TriggerVolume

    @State private var x = ""
    @State private var y = ""
    @State private var z = ""
    @State private var w = ""
    @State private var sx = ""
    @State private var sy = ""
    @State private var sz = ""
    @State private var rotX = ""
    @State private var rotY = ""
    @State private var rotZ = ""
    @State private var isEditingArguments = false

    /// "Parity Phase G" — `Header`'s named bit flags (`Arg1_Used`..
    /// `Arg4_Used` at bits 0xB/0x8/0x9/0xA, `UnkFlag0`..`UnkFlag6` at bits
    /// 0–6), ported from `Trigger.cs`'s own bit-accessor properties.
    /// `writeTriggerOrCameraPrefix` already accepts an edited `header`/
    /// `enabledMask` — only the UI to actually change them was missing.
    @State private var arg1Used = false
    @State private var arg2Used = false
    @State private var arg3Used = false
    @State private var arg4Used = false
    @State private var unkFlags: [Bool] = Array(repeating: false, count: 7)
    /// `Enabled`'s 9-bit `Mask` array (`Trigger.cs`'s own `Mask` property).
    @State private var maskBits: [Bool] = Array(repeating: false, count: 9)
    @State private var someFloatText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Volume") {
                    LabeledContent("Position X") { TextField("X", text: $x).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position Y") { TextField("Y", text: $y).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position Z") { TextField("Z", text: $z).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position W") { TextField("W", text: $w).textFieldStyle(.roundedBorder) }
                    LabeledContent("Size X") { TextField("X", text: $sx).textFieldStyle(.roundedBorder) }
                    LabeledContent("Size Y") { TextField("Y", text: $sy).textFieldStyle(.roundedBorder) }
                    LabeledContent("Size Z") { TextField("Z", text: $sz).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation X°") { TextField("X°", text: $rotX).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation Y°") { TextField("Y°", text: $rotY).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation Z°") { TextField("Z°", text: $rotZ).textFieldStyle(.roundedBorder) }
                }
                Section("Header") {
                    LabeledContent("Some Float") { TextField("value", text: $someFloatText).textFieldStyle(.roundedBorder) }
                    Toggle("Arg 1 Used", isOn: $arg1Used)
                    Toggle("Arg 2 Used", isOn: $arg2Used)
                    Toggle("Arg 3 Used", isOn: $arg3Used)
                    Toggle("Arg 4 Used", isOn: $arg4Used)
                    ForEach(0..<7, id: \.self) { i in
                        Toggle("Unk Flag \(i)", isOn: Binding(
                            get: { unkFlags.indices.contains(i) ? unkFlags[i] : false },
                            set: { if unkFlags.indices.contains(i) { unkFlags[i] = $0 } }
                        ))
                    }
                }
                .toggleStyle(.checkbox)
                Section("Enabled Mask (9 bits)") {
                    ForEach(0..<9, id: \.self) { i in
                        Toggle("Bit \(i)", isOn: Binding(
                            get: { maskBits.indices.contains(i) ? maskBits[i] : false },
                            set: { if maskBits.indices.contains(i) { maskBits[i] = $0 } }
                        ))
                    }
                }
                .toggleStyle(.checkbox)
                Section("Arguments") {
                    LabeledContent("Arg 1", value: "\(trigger.arg1)")
                    LabeledContent("Arg 2", value: "\(trigger.arg2)")
                    LabeledContent("Arg 3", value: "\(trigger.arg3)")
                    LabeledContent("Arg 4", value: "\(trigger.arg4)")
                    Button("Edit Arguments…") { isEditingArguments = true }
                        .disabled(!workspace.canSaveEdits(for: node))
                }
                if !trigger.instanceIDs.isEmpty {
                    Section("Referenced Instances (\(trigger.instanceIDs.count))") {
                        Text(trigger.instanceIDs.map { "#\($0)" }.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            HStack {
                Button("Save Edited Copy…") { save() }
                    .disabled(editedPrefix == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            if !workspace.canSaveEdits(for: node) {
                Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this record's file is archive-packed, which this build doesn't have a write path for yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                Text("Saves an edited copy under a new name — the file you opened is never modified in place.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
        .sheet(isPresented: $isEditingArguments) {
            TriggerArgumentsEditorSheet(node: node, trigger: trigger)
        }
    }

    private func loadFields() {
        x = String(trigger.position.x); y = String(trigger.position.y); z = String(trigger.position.z); w = String(trigger.position.w)
        sx = String(trigger.size.x); sy = String(trigger.size.y); sz = String(trigger.size.z)
        let degrees = eulerDegrees(from: trigger.rotationQuaternion)
        rotX = String(format: "%.2f", degrees.x); rotY = String(format: "%.2f", degrees.y); rotZ = String(format: "%.2f", degrees.z)
        someFloatText = String(format: "%.3f", trigger.someFloat)

        arg1Used = (trigger.header >> 0xB) & 1 != 0
        arg2Used = (trigger.header >> 0x8) & 1 != 0
        arg3Used = (trigger.header >> 0x9) & 1 != 0
        arg4Used = (trigger.header >> 0xA) & 1 != 0
        unkFlags = (0..<7).map { (trigger.header >> $0) & 1 != 0 }
        maskBits = (0..<9).map { (trigger.enabledMask >> $0) & 1 != 0 }
    }

    /// Recomputes `Header` from the same bit positions `Trigger.cs`'s own
    /// `Arg1_Used`..`Arg4_Used`/`UnkFlag0`..`UnkFlag6` setters use, keeping
    /// every other bit (there are more than these 11 named ones) untouched
    /// by starting from the original `trigger.header`.
    private var editedHeader: UInt32 {
        var value = trigger.header
        func setBit(_ bit: UInt32, _ on: Bool) {
            if on { value |= (1 << bit) } else { value &= ~(1 << bit) }
        }
        setBit(0xB, arg1Used)
        setBit(0x8, arg2Used)
        setBit(0x9, arg3Used)
        setBit(0xA, arg4Used)
        for i in 0..<7 { setBit(UInt32(i), unkFlags.indices.contains(i) ? unkFlags[i] : false) }
        return value
    }

    /// Recomputes `Enabled` fully from `maskBits` — `Trigger.cs`'s own
    /// `Mask` setter starts from `Enabled = 0` and ORs in each set bit,
    /// so (unlike `editedHeader`) nothing here needs preserving from the
    /// original value.
    private var editedEnabledMask: UInt32 {
        var value: UInt32 = 0
        for i in 0..<9 where maskBits.indices.contains(i) && maskBits[i] { value |= (1 << i) }
        return value
    }

    private var editedPrefix: Data? {
        guard let fx = Float(x), let fy = Float(y), let fz = Float(z), let fw = Float(w),
              let fsx = Float(sx), let fsy = Float(sy), let fsz = Float(sz),
              let frx = Float(rotX), let fry = Float(rotY), let frz = Float(rotZ),
              let someFloat = Float(someFloatText)
        else { return nil }
        let quaternion = quaternionFromEuler(SIMD3(frx, fry, frz))
        return WorldPlacementWriter.writeTriggerOrCameraPrefix(
            header: editedHeader, enabledMask: editedEnabledMask, someFloat: someFloat,
            rotationQuaternion: quaternion, position: SIMD4(fx, fy, fz, fw), size: SIMD4(fsx, fsy, fsz, trigger.size.w)
        )
    }

    private func save() {
        guard let encoded = editedPrefix else { return }
        guard let patchedBytes = workspace.patchedFileBytes(replacingPrefixOf: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_edited.rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
            } catch {
                workspace.lastError = "Save failed: \(error)"
            }
        }
    }
}

struct CameraInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let camera: PlacedCamera

    @State private var x = ""
    @State private var y = ""
    @State private var z = ""
    @State private var w = ""
    @State private var sx = ""
    @State private var sy = ""
    @State private var sz = ""
    @State private var rotX = ""
    @State private var rotY = ""
    @State private var rotZ = ""

    /// "Parity Phase F" — the fixed camera-specific block's own editable
    /// text, keyed by field name for `fixedFieldTexts["camHeader"]` etc.
    /// rather than one `@State` var per field: there are 18 of them, all
    /// following the same `TextField -> parse -> patch` shape, so a
    /// dictionary keeps `loadFields`/`editedFixedFields` from repeating
    /// that shape 18 times over.
    @State private var fixedFieldTexts: [String: String] = [:]
    /// `Coords1`/`Coords2` — real fields already written by
    /// `WorldPlacementWriter.writeCameraFixedFields` (it's always taken
    /// `camera.unkCoords1`/`unkCoords2` verbatim from whatever `PlacedCamera`
    /// it's handed), so making these editable needed no new writer support
    /// — only threading edited values through `editedFixedFields` instead
    /// of always passing the original, unedited camera through.
    @State private var coords1Texts: (x: String, y: String, z: String, w: String) = ("", "", "", "")
    @State private var coords2Texts: (x: String, y: String, z: String, w: String) = ("", "", "", "")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Volume") {
                    LabeledContent("Position X") { TextField("X", text: $x).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position Y") { TextField("Y", text: $y).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position Z") { TextField("Z", text: $z).textFieldStyle(.roundedBorder) }
                    LabeledContent("Position W") { TextField("W", text: $w).textFieldStyle(.roundedBorder) }
                    LabeledContent("Size X") { TextField("X", text: $sx).textFieldStyle(.roundedBorder) }
                    LabeledContent("Size Y") { TextField("Y", text: $sy).textFieldStyle(.roundedBorder) }
                    LabeledContent("Size Z") { TextField("Z", text: $sz).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation X°") { TextField("X°", text: $rotX).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation Y°") { TextField("Y°", text: $rotY).textFieldStyle(.roundedBorder) }
                    LabeledContent("Rotation Z°") { TextField("Z°", text: $rotZ).textFieldStyle(.roundedBorder) }
                }
                Section("Camera Types") {
                    LabeledContent("Slot 1", value: camera.cameraType1.displayName)
                    LabeledContent("Slot 2", value: camera.cameraType2.displayName)
                }
                if let subtype1 = camera.subtype1 {
                    Section("Slot 1 Data") {
                        CameraSubtypeSummaryView(subtype: subtype1)
                    }
                }
                if let subtype2 = camera.subtype2 {
                    Section("Slot 2 Data") {
                        CameraSubtypeSummaryView(subtype: subtype2)
                    }
                }
                if !camera.instanceIDs.isEmpty {
                    Section("Referenced Instances (\(camera.instanceIDs.count))") {
                        Text(camera.instanceIDs.map { "#\($0)" }.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Camera-Specific Fields") {
                    LabeledContent("Header (read-only)", value: "0x\(String(camera.header, radix: 16))")
                    LabeledContent("Enabled Mask (read-only)", value: "0b\(String(camera.enabledMask, radix: 2))")
                    fixedField("camHeader", label: "Cam Header")
                    fixedField("unkFloat1", label: "Unk Float 1")
                    fixedField("unkFloat2", label: "Unk Float 2")
                    fixedField("unkFloat3", label: "Unk Float 3")
                    fixedField("unkUInt1", label: "Unk UInt 1")
                    fixedField("unkUInt2", label: "Unk UInt 2")
                    fixedField("unkUInt3", label: "Unk UInt 3")
                    fixedField("unkUInt4", label: "Unk UInt 4")
                    fixedField("unkInt5", label: "Unk Int 5")
                    fixedField("unkInt6", label: "Unk Int 6")
                    fixedField("unkFloat4", label: "Unk Float 4")
                    fixedField("unkFloat5", label: "Unk Float 5")
                    fixedField("unkFloat6", label: "Unk Float 6")
                    fixedField("unkFloat7", label: "Unk Float 7")
                    fixedField("unkUInt7", label: "Unk UInt 7")
                    fixedField("unkInt8", label: "Unk Int 8")
                    fixedField("unkUInt9", label: "Unk UInt 9")
                    fixedField("unkFloat8", label: "Unk Float 8")
                    Text("These are the record's own fixed-size scalar fields, real and now writable — same \"never trusted from any prior stored value, but never invented either\" naming the reference tool itself uses for its `unk`-prefixed fields. Everything from the camera type onward (subtype payloads) stays read-only: changing which `CameraKind` a slot uses would reshape the trailing variable-length payload, real, separate structural work.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    coordsField("Coords 1", $coords1Texts)
                    coordsField("Coords 2", $coords2Texts)
                }
            }
            .formStyle(.grouped)
            .onAppear { loadFields() }
            .onChange(of: node.id) { _, _ in loadFields() }

            HStack {
                Button("Save Edited Copy…") { save() }
                    .disabled(editedPrefix == nil || editedFixedFields == nil || !workspace.canSaveEdits(for: node))
                Spacer()
            }
            .padding(.horizontal)

            if !workspace.canSaveEdits(for: node) {
                Text("Editing only saves for a standalone-opened .RM2/.SM2 file — this record's file is archive-packed, which this build doesn't have a write path for yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                Text("Saves an edited copy under a new name — the file you opened is never modified in place.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func fixedField(_ key: String, label: String) -> some View {
        LabeledContent(label) {
            TextField("", text: Binding(
                get: { fixedFieldTexts[key] ?? "" },
                set: { fixedFieldTexts[key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private func coordsField(_ label: String, _ texts: Binding<(x: String, y: String, z: String, w: String)>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("x", text: texts.x).textFieldStyle(.roundedBorder)
                TextField("y", text: texts.y).textFieldStyle(.roundedBorder)
                TextField("z", text: texts.z).textFieldStyle(.roundedBorder)
                TextField("w", text: texts.w).textFieldStyle(.roundedBorder)
            }
        }
    }

    private func loadFields() {
        x = String(camera.position.x); y = String(camera.position.y); z = String(camera.position.z); w = String(camera.position.w)
        sx = String(camera.size.x); sy = String(camera.size.y); sz = String(camera.size.z)
        let degrees = eulerDegrees(from: camera.rotationQuaternion)
        rotX = String(format: "%.2f", degrees.x); rotY = String(format: "%.2f", degrees.y); rotZ = String(format: "%.2f", degrees.z)

        fixedFieldTexts = [
            "camHeader": "\(camera.camHeader)",
            "unkFloat1": "\(camera.unkFloat1)",
            "unkFloat2": "\(camera.unkFloat2)",
            "unkFloat3": "\(camera.unkFloat3)",
            "unkUInt1": "\(camera.unkUInt1)",
            "unkUInt2": "\(camera.unkUInt2)",
            "unkUInt3": "\(camera.unkUInt3)",
            "unkUInt4": "\(camera.unkUInt4)",
            "unkInt5": "\(camera.unkInt5)",
            "unkInt6": "\(camera.unkInt6)",
            "unkFloat4": "\(camera.unkFloat4)",
            "unkFloat5": "\(camera.unkFloat5)",
            "unkFloat6": "\(camera.unkFloat6)",
            "unkFloat7": "\(camera.unkFloat7)",
            "unkUInt7": "\(camera.unkUInt7)",
            "unkInt8": "\(camera.unkInt8)",
            "unkUInt9": "\(camera.unkUInt9)",
            "unkFloat8": "\(camera.unkFloat8)"
        ]
        coords1Texts = ("\(camera.unkCoords1.x)", "\(camera.unkCoords1.y)", "\(camera.unkCoords1.z)", "\(camera.unkCoords1.w)")
        coords2Texts = ("\(camera.unkCoords2.x)", "\(camera.unkCoords2.y)", "\(camera.unkCoords2.z)", "\(camera.unkCoords2.w)")
    }

    private var editedPrefix: Data? {
        guard let fx = Float(x), let fy = Float(y), let fz = Float(z), let fw = Float(w),
              let fsx = Float(sx), let fsy = Float(sy), let fsz = Float(sz),
              let frx = Float(rotX), let fry = Float(rotY), let frz = Float(rotZ)
        else { return nil }
        let quaternion = quaternionFromEuler(SIMD3(frx, fry, frz))
        return WorldPlacementWriter.writeTriggerOrCameraPrefix(
            header: camera.header, enabledMask: camera.enabledMask, someFloat: camera.someFloat,
            rotationQuaternion: quaternion, position: SIMD4(fx, fy, fz, fw), size: SIMD4(fsx, fsy, fsz, camera.size.w)
        )
    }

    /// "Parity Phase F" — builds a full `PlacedCamera` reflecting every
    /// `fixedFieldTexts` entry, so `WorldPlacementWriter.
    /// writeCameraFixedFields` can encode the whole block in one pass;
    /// `nil` if any field fails to parse.
    private var editedFixedFields: Data? {
        guard let camHeader = UInt32(fixedFieldTexts["camHeader"] ?? ""),
              let unkFloat1 = Float(fixedFieldTexts["unkFloat1"] ?? ""),
              let unkFloat2 = Float(fixedFieldTexts["unkFloat2"] ?? ""),
              let unkFloat3 = Float(fixedFieldTexts["unkFloat3"] ?? ""),
              let unkUInt1 = UInt32(fixedFieldTexts["unkUInt1"] ?? ""),
              let unkUInt2 = UInt32(fixedFieldTexts["unkUInt2"] ?? ""),
              let unkUInt3 = UInt32(fixedFieldTexts["unkUInt3"] ?? ""),
              let unkUInt4 = UInt32(fixedFieldTexts["unkUInt4"] ?? ""),
              let unkInt5 = Int32(fixedFieldTexts["unkInt5"] ?? ""),
              let unkInt6 = Int32(fixedFieldTexts["unkInt6"] ?? ""),
              let unkFloat4 = Float(fixedFieldTexts["unkFloat4"] ?? ""),
              let unkFloat5 = Float(fixedFieldTexts["unkFloat5"] ?? ""),
              let unkFloat6 = Float(fixedFieldTexts["unkFloat6"] ?? ""),
              let unkFloat7 = Float(fixedFieldTexts["unkFloat7"] ?? ""),
              let unkUInt7 = UInt32(fixedFieldTexts["unkUInt7"] ?? ""),
              let unkInt8 = Int32(fixedFieldTexts["unkInt8"] ?? ""),
              let unkUInt9 = UInt32(fixedFieldTexts["unkUInt9"] ?? ""),
              let unkFloat8 = Float(fixedFieldTexts["unkFloat8"] ?? ""),
              let c1x = Float(coords1Texts.x), let c1y = Float(coords1Texts.y), let c1z = Float(coords1Texts.z), let c1w = Float(coords1Texts.w),
              let c2x = Float(coords2Texts.x), let c2y = Float(coords2Texts.y), let c2z = Float(coords2Texts.z), let c2w = Float(coords2Texts.w)
        else { return nil }
        var edited = camera
        edited.unkCoords1 = SIMD4(c1x, c1y, c1z, c1w)
        edited.unkCoords2 = SIMD4(c2x, c2y, c2z, c2w)
        edited.camHeader = camHeader
        edited.unkFloat1 = unkFloat1
        edited.unkFloat2 = unkFloat2
        edited.unkFloat3 = unkFloat3
        edited.unkUInt1 = unkUInt1
        edited.unkUInt2 = unkUInt2
        edited.unkUInt3 = unkUInt3
        edited.unkUInt4 = unkUInt4
        edited.unkInt5 = unkInt5
        edited.unkInt6 = unkInt6
        edited.unkFloat4 = unkFloat4
        edited.unkFloat5 = unkFloat5
        edited.unkFloat6 = unkFloat6
        edited.unkFloat7 = unkFloat7
        edited.unkUInt7 = unkUInt7
        edited.unkInt8 = unkInt8
        edited.unkUInt9 = unkUInt9
        edited.unkFloat8 = unkFloat8
        return WorldPlacementWriter.writeCameraFixedFields(edited, isDemo: camera.unkShort == nil)
    }

    private func save() {
        guard let prefix = editedPrefix, let fixedFields = editedFixedFields else { return }
        guard let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: [
            (node: node, absoluteOffset: node.fileOffset, encoded: prefix),
            (node: node, absoluteOffset: node.fileOffset + camera.fixedFieldsFileOffset, encoded: fixedFields)
        ]) else { return }
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(node.displayName)_edited.rm2", message: "Save the edited copy of this file. The original file on disk is not modified.") else { return }
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
            } catch {
                workspace.lastError = "Save failed: \(error)"
            }
        }
    }
}

/// Quaternion <-> XYZ-order Euler degrees, for the Trigger/Camera
/// inspectors' rotation fields — the same technique `LevelViewerRenderer`
/// uses for its own gizmo rotation fields, reimplemented locally here since
/// that one is `private` to a different, unrelated type (a 3D renderer);
/// this is plain, self-contained trig, not logic worth sharing machinery for.
private func eulerDegrees(from quaternion: SIMD4<Float>) -> SIMD3<Float> {
    let q = simd_quatf(vector: quaternion)
    let m = simd_float3x3(q)
    let sy = sqrt(m.columns.0.x * m.columns.0.x + m.columns.0.y * m.columns.0.y)
    let singular = sy < 1e-6
    let x: Float, y: Float, z: Float
    if !singular {
        x = atan2(m.columns.1.z, m.columns.2.z)
        y = atan2(-m.columns.0.z, sy)
        z = atan2(m.columns.0.y, m.columns.0.x)
    } else {
        x = atan2(-m.columns.2.y, m.columns.1.y)
        y = atan2(-m.columns.0.z, sy)
        z = 0
    }
    let toDegrees: Float = 180 / .pi
    return SIMD3(x * toDegrees, y * toDegrees, z * toDegrees)
}

private func quaternionFromEuler(_ degrees: SIMD3<Float>) -> SIMD4<Float> {
    let toRadians: Float = .pi / 180
    let r = degrees * toRadians
    let qx = simd_quatf(angle: r.x, axis: SIMD3(1, 0, 0))
    let qy = simd_quatf(angle: r.y, axis: SIMD3(0, 1, 0))
    let qz = simd_quatf(angle: r.z, axis: SIMD3(0, 0, 1))
    return (qz * qy * qx).vector
}

/// Compact, per-subtype field summary — full raw byte-for-byte detail
/// (matrices, control-point arrays, undecoded trailing blobs) is available
/// but not exhaustively spelled out here; counts/sizes are shown instead of
/// dumping e.g. a Spline's full control-point list into a form.
private struct CameraSubtypeSummaryView: View {
    let subtype: CameraSubtype

    var body: some View {
        switch subtype {
        case .boss(let boss):
            LabeledContent("Vector", value: vectorString(boss.unkVector))
            LabeledContent("Floats", value: String(format: "%.2f, %.2f, %.2f, %.2f", boss.unkFloat3, boss.unkFloat4, boss.unkFloat5, boss.unkFloat6))
        case .point(let point):
            LabeledContent("Point", value: vectorString(point.unkVector))
        case .line(let line):
            LabeledContent("Box Min", value: vectorString(line.boundingBoxVector1))
            LabeledContent("Box Max", value: vectorString(line.boundingBoxVector2))
        case .path(let path):
            LabeledContent("Control Points", value: "\(path.unkVectors.count)")
            LabeledContent("Trailing Data", value: "\(path.trailingData.count) bytes")
        case .null1C05:
            Text("No payload for this sub-camera type.").foregroundStyle(.secondary)
        case .spline(let spline):
            LabeledContent("Segments", value: "\(spline.segmentCount)")
            LabeledContent("Control Points", value: "\(spline.unkVectors.count)")
            LabeledContent("Trailing Data", value: "\(spline.trailingData.count) bytes")
        case .unused1C09(let minor):
            LabeledContent("Floats", value: String(format: "%.2f, %.2f", minor.unkFloat1, minor.unkFloat2))
        case .point2(let point2):
            LabeledContent("Point", value: vectorString(point2.unkVector))
        case .unused1C0C(let bytes):
            LabeledContent("Bytes", value: "\(bytes.byte1), \(bytes.byte2), \(bytes.byte3), \(bytes.byte4)")
        case .line2(let line2):
            LabeledContent("Box Min", value: vectorString(line2.boundingBoxVector1))
            LabeledContent("Box Max", value: vectorString(line2.boundingBoxVector2))
        case .empty1C0E:
            Text("No payload for this sub-camera type.").foregroundStyle(.secondary)
        case .zone(let zone):
            LabeledContent("Data 1 Vectors", value: "\(zone.data1Vectors.count)")
            LabeledContent("Data 2 Vectors", value: "\(zone.data2Vectors.count)")
        }
    }
}

private func vectorString(_ v: SIMD4<Float>) -> String {
    String(format: "%.3f, %.3f, %.3f, %.3f", v.x, v.y, v.z, v.w)
}

private func degreesString(_ v: SIMD3<Float>) -> String {
    String(format: "%.1f°, %.1f°, %.1f°", v.x, v.y, v.z)
}
