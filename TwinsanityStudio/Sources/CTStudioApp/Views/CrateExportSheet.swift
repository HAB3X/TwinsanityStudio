import SwiftUI
import CTModels
import CTExport

/// Metadata prompt for "Export as Mod Crate…" (blueprint 3.3) — the
/// `modcrateinfo.txt` fields a real `CrateModLoader` install expects
/// (`Name`/`Description`/`Author`/`Version`/`Game`), collected once here
/// rather than guessed at, then handed to `CrateExporter.export`.
struct CrateExportSheet: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let node: ChunkNode
    let patchedBytes: Data

    @State private var name: String
    @State private var description = ""
    @State private var author = ""
    @State private var version = "1.0"

    init(node: ChunkNode, patchedBytes: Data) {
        self.node = node
        self.patchedBytes = patchedBytes
        _name = State(initialValue: "\(node.displayName) Edit")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export as Mod Crate").font(.title3.bold())

            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)
                TextField("Author", text: $author)
                TextField("Version", text: $version)
            }
            .formStyle(.grouped)

            Text("Packages the edited file into a real CrateModLoader-installable .crate (a modcrateinfo.txt manifest + a layer0 folder containing the edited file, zipped). The in-crate file name defaults to the original file's own name — this build doesn't track its exact in-archive install path, so double-check the destination subfolder after installing.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 420)
    }

    private func export() {
        let originalName = workspace.originalFileName(for: node) ?? node.displayName
        guard let url = ExportPanel.chooseSaveLocation(suggestedName: "\(sanitizedFileName(name)).crate", message: "Save the mod crate.") else { return }
        let metadata = CrateMetadata(name: name, description: description, author: author, version: version, targetGame: "Crash Twinsanity")
        workspace.exportAsCrate(patchedBytes: patchedBytes, originalFileName: originalName, metadata: metadata, to: url)
        dismiss()
    }

    private func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "mod" : cleaned
    }
}
