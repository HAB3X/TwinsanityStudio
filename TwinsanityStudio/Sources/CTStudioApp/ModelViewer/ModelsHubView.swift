import SwiftUI
import CTModels

/// A flat, globally searchable list of every model resolved so far —
/// "Global Asset Indexing": rather than hunting through the chunk tree for a
/// specific RigidModel or rigged skeleton, this is every one of them, from
/// every scanned file, in one place. Clicking a row loads it straight into
/// the Model Viewer using the *already-resolved* asset — no re-parsing, no
/// tree walking, so this is also the most reliable way to open the viewer.
struct ModelsHubView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var onlyRigged = false
    @State private var onlyFullyTextured = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Models Hub").font(.title2.bold())
                Text("\(filteredModels.count) of \(workspace.modelsHub.count) models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("Search models by name…", text: $searchText)
                .textFieldStyle(.roundedBorder)
            Toggle("Rigged only", isOn: $onlyRigged)
                .toggleStyle(.checkbox)
            Toggle("Fully textured only", isOn: $onlyFullyTextured)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.modelsHub.isEmpty {
            ContentUnavailableView(
                workspace.isScanning ? "Scanning…" : "No Models Found Yet",
                systemImage: "cube.transparent",
                description: Text(workspace.isScanning
                    ? "Models will appear here as the archive scan finds them."
                    : "Load a .BH archive or a .RM2/.SM2 file — scanning starts automatically.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredModels.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try a different search or clear the filters above."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filteredModels) { model in
                Button {
                    workspace.modelViewerAsset = model
                    dismiss()
                } label: {
                    ModelsHubRow(model: model)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private var filteredModels: [ResolvedModelAsset] {
        workspace.modelsHub.filter { model in
            (searchText.isEmpty || model.displayName.localizedCaseInsensitiveContains(searchText))
                && (!onlyRigged || model.skeleton != nil)
                && (!onlyFullyTextured || model.isFullyTextured)
        }
    }
}

private struct ModelsHubRow: View {
    let model: ResolvedModelAsset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.skeleton != nil ? "figure.stand" : "cube.fill")
                .foregroundStyle(model.skeleton != nil ? .orange : .teal)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(model.mesh.submeshes.count) submeshes")
                    Text("· \(model.mesh.totalVertexCount) verts")
                    if model.skeleton != nil {
                        Text("· rigged")
                    }
                    if !model.availableAnimations.isEmpty {
                        Text("· \(model.availableAnimations.count) anim(s)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.isFullyTextured {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Some submeshes have no resolved texture")
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
