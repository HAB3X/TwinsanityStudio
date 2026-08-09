import SwiftUI
import CTModels

/// Read-only inspector for a decoded `Skydome` record.
struct SkydomeInspectorView: View {
    let skydome: SkydomeInfo

    var body: some View {
        Form {
            Section("Skydome #\(skydome.id)") {
                LabeledContent("Unknown", value: "\(skydome.unknown)")
                LabeledContent("Mesh Count", value: "\(skydome.meshIDs.count)")
            }
            Section("Real Model/RigidModel IDs") {
                ForEach(Array(skydome.meshIDs.enumerated()), id: \.offset) { index, id in
                    LabeledContent("Mesh \(index)", value: "#\(id)")
                }
            }
        }
        .formStyle(.grouped)
    }
}
