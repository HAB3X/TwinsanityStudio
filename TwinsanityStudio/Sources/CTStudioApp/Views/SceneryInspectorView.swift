import SwiftUI
import CTModels

/// Read-only summary for a decoded `SceneryData` record, with a button into
/// the dedicated multi-object level viewport (`LevelViewerWindow`) — like
/// `CollisionInspectorView`, this is level-wide data, not a single
/// composite-eligible object.
struct SceneryInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let scenery: SceneryAsset

    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Chunk") {
                    LabeledContent("Name", value: scenery.chunkName.isEmpty ? "(unnamed)" : scenery.chunkName)
                    if let skydomeID = scenery.skydomeID {
                        LabeledContent("Skydome ID", value: "\(skydomeID)")
                    }
                }
                Section("Placements") {
                    LabeledContent("Total in tree", value: "\(scenery.placements.count)")
                }
                if !scenery.ambientLights.isEmpty || !scenery.directionalLights.isEmpty || !scenery.pointLights.isEmpty || !scenery.negativeLights.isEmpty {
                    Section("Lights") {
                        if !scenery.ambientLights.isEmpty { LabeledContent("Ambient", value: "\(scenery.ambientLights.count)") }
                        if !scenery.directionalLights.isEmpty { LabeledContent("Directional", value: "\(scenery.directionalLights.count)") }
                        if !scenery.pointLights.isEmpty { LabeledContent("Point", value: "\(scenery.pointLights.count)") }
                        if !scenery.negativeLights.isEmpty { LabeledContent("Negative", value: "\(scenery.negativeLights.count)") }
                    }
                }
            }
            .formStyle(.grouped)

            if scenery.placements.isEmpty {
                ContentUnavailableView("No Placements", systemImage: "map", description: Text("This record decoded but has no scenery tree — see its own Chunk Name/header fields above."))
            } else {
                Button {
                    isResolving = true
                    Task {
                        // Resolving every placement (mesh + material +
                        // texture lookups for potentially thousands of
                        // objects) runs off the main actor — this used to
                        // block the whole UI for however long that took.
                        let resolved = await workspace.resolvedLevelPlacements(for: scenery, node: node)
                        isResolving = false
                        workspace.levelViewerContext = LevelViewerContext(scenery: scenery, placements: resolved)
                    }
                } label: {
                    if isResolving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open Level Viewer", systemImage: "map")
                    }
                }
                .disabled(isResolving)
                Text("Objects are positioned correctly but not yet rotated/scaled — see the Level Viewer's own notes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DynamicSceneryInspectorView: View {
    let scenery: DynamicSceneryAsset

    var body: some View {
        if scenery.placements.isEmpty {
            ContentUnavailableView("No Dynamic Scenery", systemImage: "arrow.triangle.2.circlepath")
        } else {
            Form {
                Section("Placements (\(scenery.placements.count))") {
                    ForEach(Array(scenery.placements.enumerated()), id: \.offset) { _, placement in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Model #\(placement.modelID)").font(.callout.bold())
                            Text(String(format: "Resting position: %.2f, %.2f, %.2f", placement.worldPosition.x, placement.worldPosition.y, placement.worldPosition.z))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Resting position only — per-frame motion curves aren't modeled yet (see DynamicSceneryDataParser).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
