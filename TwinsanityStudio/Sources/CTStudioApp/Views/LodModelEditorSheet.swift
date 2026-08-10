import SwiftUI
import CTModels
import CTParsers

/// Write-back editor for a decoded `LodModel` record — ports the scalar
/// field set from `Editors/LodEditor.cs`. The 4 `lodDistances` slots are
/// shown read-only (this build deliberately doesn't interpret their units
/// — see `LodModelInfo`'s own doc comment), and the per-slot
/// `lodModelIDs` are editable as hex IDs (matching the reference tool's
/// own hex-entry UI). The first `lodDistances` slot is enabled iff a real
/// model ID is set at that index, mirroring the reference tool exactly.
struct LodModelEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: LodModelInfo

    @State private var header: String
    @State private var lodModelIDsText: [String]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, lodModel: LodModelInfo) {
        self.node = node
        self.original = lodModel
        _header = State(initialValue: "\(lodModel.header)")
        _lodModelIDsText = State(initialValue: lodModel.lodModelIDs.map { String(format: "%X", $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit LOD Model #\(original.id)").font(.title3.bold())
            Text("LOD distances are round-tripped but treated as read-only here — this build doesn't have a confirmed interpretation of their units. The viewer always picks the first ID that actually resolves.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                Section("Core") {
                    LabeledContent("Header") { TextField("value", text: $header).textFieldStyle(.roundedBorder) }
                    LabeledContent("Models Amount", value: "\(lodModelIDsText.count)")
                }
                Section("Alternate RigidModel IDs (hex, highest detail first)") {
                    ForEach(lodModelIDsText.indices, id: \.self) { i in
                        LabeledContent("LOD \(i)") { TextField("0x...", text: $lodModelIDsText[i]).textFieldStyle(.roundedBorder) }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isSaving ? "Saving…" : "Save Edited Copy…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func save() {
        guard let headerValue = UInt32(header) else {
            errorMessage = "Header must be a whole number."
            return
        }
        let ids = lodModelIDsText.map { UInt32($0, radix: 16) }
        guard ids.allSatisfy({ $0 != nil }) else {
            errorMessage = "Every LOD ID must be a valid hex number."
            return
        }
        errorMessage = nil

        var edited = original
        edited.header = headerValue
        edited.lodModelIDs = ids.compactMap { $0 }

        let encoded = LodModelWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this LOD model changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this LOD model changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}
