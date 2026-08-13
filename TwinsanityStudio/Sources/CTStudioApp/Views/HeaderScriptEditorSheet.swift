import SwiftUI
import CTModels
import CTParsers

/// Editor for HeaderScript participant entries (object ID, assignment types, localities, statuses, preferences)
struct HeaderScriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let script: ScriptAsset
    let header: HeaderScript

    init(node: ChunkNode, script: ScriptAsset, header: HeaderScript) {
        self.node = node
        self.script = script
        self.header = header
    }

    var body: some View {
        Form {
            Section("Header Information") {
                LabeledContent("Entries") { Text("\(header.entries.count)") }
            }

            Section("Participant Entries") {
                if header.entries.isEmpty {
                    Text("No participant entries")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(header.entries.enumerated()), id: \.offset) { index, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Entry #\(index)")
                                .font(.caption.bold())
                            LabeledContent("Main Script Index") { Text("\(entry.mainScriptIndex)") }
                            LabeledContent("Object ID") { Text("\(entry.objectID ?? 0)") }
                            LabeledContent("Assignment Type") { Text("\(entry.resolvedAssignType?.rawValue ?? 255)") }
                            LabeledContent("Locality") { Text("\(entry.resolvedAssignLocality?.rawValue ?? 255)") }
                            LabeledContent("Status") { Text("\(entry.resolvedAssignStatus?.rawValue ?? 255)") }
                            LabeledContent("Preference") { Text("\(entry.resolvedAssignPreference?.rawValue ?? 255)") }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    // In a full implementation, this would save changes
                    dismiss()
                }
                .disabled(true) // Enable when editing is implemented
            }
        }
    }
}