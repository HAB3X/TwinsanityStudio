import SwiftUI
import CTModels
import CTParsers

/// Editor for MainScript: name, start unit, state chain manipulation
struct MainScriptEditorSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let script: ScriptAsset
    let mainScript: MainScript

    init(node: ChunkNode, script: ScriptAsset, mainScript: MainScript) {
        self.node = node
        self.script = script
        self.mainScript = mainScript
    }

    var body: some View {
        Form {
            Section("Main Script Information") {
                LabeledContent("Name") { Text(mainScript.name.isEmpty ? "<unnamed>" : mainScript.name) }
                LabeledContent("Start Unit") { Text("\(mainScript.startUnit)") }
                LabeledContent("States Amount Raw") { Text("\(mainScript.statesAmountRaw)") }
                LabeledContent("Actual State Count") { Text("\(mainScript.states.count)") }
            }

            Section("State Chain") {
                if mainScript.states.isEmpty {
                    Text("No states in chain")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(mainScript.states.enumerated()), id: \.offset) { index, state in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("State #\(index)")
                                .font(.caption.bold())
                            LabeledContent("Bitfield Raw") { Text("\(state.bitfieldRaw)") }
                            LabeledContent("Script Index/Slot") { Text("\(state.scriptIndexOrSlot)") }
                            LabeledContent("Declared Body Count") { Text("\(state.declaredBodyCount)") }
                            LabeledContent("Actual Body Count") { Text("\(state.bodies.count)") }
                            LabeledContent("Has Type1") { Text("\(state.type1 != nil ? "Yes" : "No")") }
                            LabeledContent("Is Slot") { Text("\(state.isSlot ? "Yes" : "No")") }
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