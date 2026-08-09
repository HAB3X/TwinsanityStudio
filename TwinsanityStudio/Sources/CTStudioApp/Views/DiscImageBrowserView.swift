import SwiftUI
import CTParsers

/// "Native ISO & BIN/CUE Disc Image Mounting" (Task 7): browses a real
/// mounted ISO-9660 volume's directory tree. Selecting a file this build
/// recognizes (by extension — the same real chunk/archive/soundbank/
/// cross-engine extensions the regular Open panel accepts) offers to
/// extract it and hand it straight to the existing `open(url:)` pipeline,
/// so a `.RM2`/`.SM2`/`.BH` found inside a mounted disc goes through
/// exactly the same real parsing path a file picked from a regular folder
/// does. Read-only: no write-back/repacking of the disc image itself.
struct DiscImageBrowserView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let mounted: WorkspaceViewModel.MountedDiscImage
    @State private var expandedIDs: Set<UUID> = []

    private static let recognizedExtensions: Set<String> = ["RM2", "SM2", "RMX", "SMX", "BH", "BD", "MH", "MB", "CRT", "WMP"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                DiscEntryRow(entry: mounted.root, depth: 0, expandedIDs: $expandedIDs, onOpen: open)
            }
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Disc Image: \(mounted.displayName)").font(.title3.bold())
                Text("Real ISO-9660 volume, mounted read-only. Select a recognized file to open it in the main workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private func open(_ entry: ISO9660Entry) {
        workspace.openMountedEntry(entry)
        dismiss()
    }

    static func isRecognized(_ entry: ISO9660Entry) -> Bool {
        !entry.isDirectory && recognizedExtensions.contains((entry.name as NSString).pathExtension.uppercased())
    }
}

private struct DiscEntryRow: View {
    let entry: ISO9660Entry
    let depth: Int
    @Binding var expandedIDs: Set<UUID>
    let onOpen: (ISO9660Entry) -> Void

    var body: some View {
        if entry.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { expandedIDs.contains(entry.id) },
                set: { isExpanded in
                    if isExpanded { expandedIDs.insert(entry.id) } else { expandedIDs.remove(entry.id) }
                }
            )) {
                ForEach(entry.children.sorted { $0.name < $1.name }) { child in
                    DiscEntryRow(entry: child, depth: depth + 1, expandedIDs: $expandedIDs, onOpen: onOpen)
                }
            } label: {
                Label(entry.name.isEmpty ? "/" : entry.name, systemImage: "folder")
            }
        } else {
            let recognized = DiscImageBrowserView.isRecognized(entry)
            HStack {
                Label(entry.name, systemImage: recognized ? "doc.badge.gearshape" : "doc")
                    .foregroundStyle(recognized ? .primary : .secondary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if recognized {
                    Button("Open") { onOpen(entry) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }
}
