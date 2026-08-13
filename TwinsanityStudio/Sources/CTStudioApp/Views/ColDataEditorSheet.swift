import SwiftUI
import CTModels
import CTParsers
import simd

/// Write-back editor for a decoded `ColData` record — ports the
/// `ColDataEditor`'s trigger-tree visualization as an editable list of
/// the underlying trigger boxes, since the reference editor itself only
/// surfaces the tree (no per-trigger fields). The triangles/vertices/
/// groups sections of the on-disk blob are shown read-only: editing
/// individual vertex/triangle bytes is meaningless (any change would
/// silently break the surface-index math), so the only safe edit is the
/// trigger box set, which the writer re-emits verbatim.
struct ColDataEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let original: CollisionMesh

    @State private var triggerBoxes: [CollisionTriggerBox]
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(node: ChunkNode, mesh: CollisionMesh) {
        self.node = node
        self.original = mesh
        _triggerBoxes = State(initialValue: mesh.triggerBoxes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit ColData #\(original.id)").font(.title3.bold())
            Text("Triggers are editable. Vertices, triangles, and groups are read-only — editing them would silently corrupt the surface-ID math.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Form {
                Section("Triggers (\(triggerBoxes.count))") {
                    ForEach(triggerBoxes.indices, id: \.self) { i in
                        TriggerBoxFields(box: $triggerBoxes[i])
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
        .frame(minWidth: 520, minHeight: 480)
    }

    private func save() {
        errorMessage = nil
        var edited = original
        edited.triggerBoxes = triggerBoxes

        let encoded = ColDataWriter.write(edited)
        guard let patchedBytes = workspace.patchedFileBytes(replacing: node, with: encoded) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(node.displayName)_edited.rm2",
            message: "Save the edited copy of this file, with this ColData changed. The original file on disk is not modified."
        ) else { return }
        isSaving = true
        Task {
            do {
                try await workspace.writeDataAsync(patchedBytes, to: url)
                workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with this ColData changed. The original file was not modified."
                isSaving = false
                dismiss()
            } catch {
                workspace.lastError = "Save failed: \(error)"
                isSaving = false
            }
        }
    }
}

private struct TriggerBoxFields: View {
    @Binding var box: CollisionTriggerBox

    var body: some View {
        DisclosureGroup("Trigger \(box.flag1) → \(box.flag2)") {
            VStack(alignment: .leading) {
                FloatField("Min X", value: Binding(get: { Double(box.min.x) }, set: { box.min.x = Float($0) }))
                FloatField("Min Y", value: Binding(get: { Double(box.min.y) }, set: { box.min.y = Float($0) }))
                FloatField("Min Z", value: Binding(get: { Double(box.min.z) }, set: { box.min.z = Float($0) }))
                FloatField("Max X", value: Binding(get: { Double(box.max.x) }, set: { box.max.x = Float($0) }))
                FloatField("Max Y", value: Binding(get: { Double(box.max.y) }, set: { box.max.y = Float($0) }))
                FloatField("Max Z", value: Binding(get: { Double(box.max.z) }, set: { box.max.z = Float($0) }))
                LabeledContent("Flag 1") { TextField("value", text: Binding(get: { "\(box.flag1)" }, set: { box.flag1 = Int32($0) ?? box.flag1 })).textFieldStyle(.roundedBorder) }
                LabeledContent("Flag 2") { TextField("value", text: Binding(get: { "\(box.flag2)" }, set: { box.flag2 = Int32($0) ?? box.flag2 })).textFieldStyle(.roundedBorder) }
            }
        }
    }
}

private struct FloatField: View {
    let label: String
    @Binding var value: Double
    @State private var text: String = ""

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        LabeledContent(label) {
            TextField("value", text: $text)
                .textFieldStyle(.roundedBorder)
                .onAppear { text = Self.format(value) }
                .onChange(of: value) { _, newValue in text = Self.format(newValue) }
                .onChange(of: text) { _, _ in commit() }
                .onSubmit { commit() }
        }
    }

    private func commit() {
        if let parsed = Double(text) { value = parsed }
    }

    private static func format(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(v)) : "\(v)"
    }
}
