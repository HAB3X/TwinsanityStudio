import SwiftUI
import CTModels

/// Read-only inspectors for "AI Pathfinding/Navmesh Editor" (roadmap 5.1)
/// records. No write-back — see `ChunkLinksInspectorView`'s doc comment for
/// the same reasoning: no verified byte-exact encoder to round-trip
/// through yet.
struct AIPositionInspectorView: View {
    let marker: AIPositionMarker

    var body: some View {
        Form {
            Section("AI Waypoint #\(marker.id)") {
                LabeledContent("Position X", value: String(format: "%.3f", marker.position.x))
                LabeledContent("Position Y", value: String(format: "%.3f", marker.position.y))
                LabeledContent("Position Z", value: String(format: "%.3f", marker.position.z))
                LabeledContent("W (node weight?)", value: String(format: "%.3f", marker.position.w))
                if let nodeType = marker.nodeType {
                    LabeledContent("Node Type", value: nodeType.displayName)
                } else {
                    LabeledContent("Node Type", value: "Unrecognized (raw \(marker.rawNodeType))")
                }
            }
            Section {
                Text("Real, decoded AIPosition record. Open this level's Level Viewer to see every waypoint in the file plotted in 3D.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AIPathInspectorView: View {
    let path: AIPathRecord

    var body: some View {
        Form {
            Section("AI Path #\(path.id)") {
                ForEach(Array(path.args.enumerated()), id: \.offset) { index, value in
                    LabeledContent("Argument \(index)", value: "\(value)")
                }
            }
            Section {
                Text("This record has no position of its own and no confirmed link to any AIPosition waypoint — the reference tool's own editor shows these same 5 raw values with no further interpretation, so this build doesn't guess at one either.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
