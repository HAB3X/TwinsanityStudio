import SwiftUI
import CTModels
import CTParsers

/// "Recipe Book — Asset Swap & Quick-Test" (roadmap 6.4): reassigns which
/// real `GameObject` an existing `Instance` placement resolves to — a
/// character/prop swap built on `PlacedInstance.objectIDFileOffset`
/// (Task 1's arbitrary-offset patch, reused for a different field). Every
/// swap candidate offered here is a real `objectID` that already appears
/// somewhere in this level's own `Instance` records, resolved to its real
/// display name via the same `resolvedInstanceAssets` the 3D viewport
/// already uses — never an invented ID.
///
/// The roadmap's other half — "live Sprite-Sheet Canvas for quick texture
/// replacement" — isn't built *here*: it lives in `TextureInspectorView`'s
/// "Replace with Image…" instead, since it operates on `Texture` records,
/// not `Instance` placements, and this view has no access to a level's
/// individual textures, only the objects placed in it. That feature is
/// real now (`TextureWriter.replacingPixelData`, PSMCT32 only — see its
/// doc comment for why other GS formats aren't attempted), so this view
/// stays scoped to what its own data actually supports: character/prop
/// swap via `objectID` reassignment (see
/// `WorldPlacementWriter.writeInstanceObjectID`).
struct RecipeBookView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)]
    let resolvedInstanceAssets: [UUID: ResolvedModelAsset]
    let referenceNode: ChunkNode

    /// `node.id` -> chosen replacement `objectID` (only entries that
    /// differ from the placement's real, on-disk `objectID` end up here).
    @State private var pendingSwaps: [UUID: UInt16] = [:]
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if instanceMarkers.isEmpty {
                ContentUnavailableView("No Placements", systemImage: "shippingbox",
                    description: Text("This chunk has no Instance placements to swap."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Recipe Book").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Reassign which real object each placement resolves to. Every choice below is a real objectID already used somewhere in this chunk — nothing here is invented. Applying writes an edited copy of the file; the original is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search placements…", text: $searchText)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
    }

    private var swapCandidates: [(objectID: UInt16, displayName: String)] {
        var byID: [UInt16: String] = [:]
        for entry in instanceMarkers {
            guard byID[entry.instance.objectID] == nil else { continue }
            let name = resolvedInstanceAssets[entry.node.id]?.displayName ?? "Object #\(entry.instance.objectID) (unresolved)"
            byID[entry.instance.objectID] = name
        }
        return byID.map { (objectID: $0.key, displayName: $0.value) }.sorted { $0.displayName < $1.displayName }
    }

    private var filteredMarkers: [(node: ChunkNode, instance: PlacedInstance)] {
        guard !searchText.isEmpty else { return instanceMarkers }
        return instanceMarkers.filter { entry in
            let name = resolvedInstanceAssets[entry.node.id]?.displayName ?? "Object #\(entry.instance.objectID)"
            return name.localizedCaseInsensitiveContains(searchText) || "\(entry.instance.id)".contains(searchText)
        }
    }

    private var list: some View {
        List(filteredMarkers, id: \.node.id) { entry in
            RecipeRow(
                entry: entry,
                currentName: resolvedInstanceAssets[entry.node.id]?.displayName ?? "Object #\(entry.instance.objectID) (unresolved)",
                candidates: swapCandidates,
                selection: Binding(
                    get: { pendingSwaps[entry.node.id] ?? entry.instance.objectID },
                    set: { newValue in
                        if newValue == entry.instance.objectID {
                            pendingSwaps[entry.node.id] = nil
                        } else {
                            pendingSwaps[entry.node.id] = newValue
                        }
                    }
                ),
                applyToAllMatching: { newValue in
                    for match in instanceMarkers where match.instance.objectID == entry.instance.objectID {
                        pendingSwaps[match.node.id] = newValue == match.instance.objectID ? nil : newValue
                    }
                }
            )
        }
    }

    private var footer: some View {
        HStack {
            Text(pendingSwaps.isEmpty ? "No swaps queued." : "\(pendingSwaps.count) swap(s) queued.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Apply Recipe…") { applyRecipe() }
                .disabled(pendingSwaps.isEmpty)
        }
        .padding()
    }

    private func applyRecipe() {
        let edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = instanceMarkers.compactMap { entry in
            guard let newID = pendingSwaps[entry.node.id] else { return nil }
            let encoded = WorldPlacementWriter.writeInstanceObjectID(newID)
            return (entry.node, entry.node.fileOffset + entry.instance.objectIDFileOffset, encoded)
        }
        guard !edits.isEmpty, let patchedBytes = workspace.patchedFileBytes(applyingAbsoluteByteRangePatches: edits) else { return }
        guard let url = ExportPanel.chooseSaveLocation(
            suggestedName: "\(workspace.originalFileName(for: referenceNode) ?? "chunk")_recipe.rm2",
            message: "Save the edited copy of this file with \(edits.count) object swap(s) applied. The original file on disk is not modified."
        ) else { return }
        do {
            try patchedBytes.write(to: url)
            workspace.statusMessage = "Saved edited copy to \(url.lastPathComponent) with \(edits.count) object swap(s)."
            pendingSwaps.removeAll()
            dismiss()
        } catch {
            workspace.lastError = "Save failed: \(error)"
        }
    }
}

private struct RecipeRow: View {
    let entry: (node: ChunkNode, instance: PlacedInstance)
    let currentName: String
    let candidates: [(objectID: UInt16, displayName: String)]
    @Binding var selection: UInt16
    let applyToAllMatching: (UInt16) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentName).font(.callout)
                Text("Instance #\(entry.instance.id)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $selection) {
                ForEach(candidates, id: \.objectID) { candidate in
                    Text(candidate.displayName).tag(candidate.objectID)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            // "Toggleable preset" (roadmap 6.4): a real, non-fabricated
            // preset action — broadcasts this row's chosen swap to every
            // other placement in the level that started with the same
            // real objectID, instead of editing them one at a time.
            Menu {
                Button("Apply to all matching placements") { applyToAllMatching(selection) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 2)
    }
}
