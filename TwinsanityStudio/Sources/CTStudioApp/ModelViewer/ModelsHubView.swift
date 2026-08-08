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
    @State private var isBatchSelectionMode = false
    @State private var selectedIDs: Set<ResolvedModelAsset.ID> = []

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
                if let progress = workspace.batchExportProgress {
                    Text("Exporting \(progress.completed) of \(progress.total)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(filteredModels.count) of \(workspace.modelsHub.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if workspace.isScanning {
                ProgressView().controlSize(.small)
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
            if let progress = workspace.batchExportProgress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                    .frame(width: 100)
            } else if isBatchSelectionMode {
                Button("Export Selected (\(selectedIDs.count))…") { exportSelected() }
                    .disabled(selectedIDs.isEmpty)
                Button("Cancel") {
                    isBatchSelectionMode = false
                    selectedIDs.removeAll()
                }
            } else {
                Button("Select…") { isBatchSelectionMode = true }
                    .disabled(workspace.modelsHub.isEmpty)
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
                if isBatchSelectionMode {
                    Button {
                        toggleSelection(model.id)
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.contains(model.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(model.id) ? Color.accentColor : Color.secondary)
                            ModelsHubRow(model: model)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        workspace.modelViewerAsset = model
                        dismiss()
                    } label: {
                        ModelsHubRow(model: model)
                    }
                    .buttonStyle(.plain)
                }
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

    private func toggleSelection(_ id: ResolvedModelAsset.ID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// "One-Click Batch Export" (blueprint 3.1): one destination folder
    /// picker, then `WorkspaceViewModel.exportBatch` queues every selected
    /// model's full complete-asset export (mesh + textures + animations)
    /// into its own subfolder underneath it.
    private func exportSelected() {
        let assets = workspace.modelsHub.filter { selectedIDs.contains($0.id) }
        guard !assets.isEmpty, let directory = ExportPanel.chooseFolder(message: "Choose a folder to export \(assets.count) selected model(s) into — each gets its own subfolder.") else { return }
        isBatchSelectionMode = false
        selectedIDs.removeAll()
        Task { await workspace.exportBatch(assets, to: directory) }
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
