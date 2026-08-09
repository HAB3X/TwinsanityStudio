import SwiftUI
import CTModels
import CTExport

/// "Textures Hub" (QoL sweep): a searchable thumbnail grid of every decoded
/// texture in the workspace, the same role `ModelsHubView` plays for
/// models — browsing hundreds of textures as a flat name list (the sidebar)
/// doesn't give any visual sense of what's actually in them.
struct TexturesHubView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selected: TextureHubEntry?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 640, minHeight: 520)
        .sheet(item: $selected) { entry in
            TextureHubDetailView(entry: entry)
                .environmentObject(workspace)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Textures Hub").font(.title2.bold())
                Text("\(filteredEntries.count) of \(workspace.texturesHub.count) textures")
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
        TextField("Search textures by name or source file…", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if workspace.texturesHub.isEmpty {
            ContentUnavailableView(
                workspace.isScanning ? "Scanning…" : "No Textures Found Yet",
                systemImage: "photo.stack",
                description: Text(workspace.isScanning
                    ? "Textures will appear here as the archive scan finds them."
                    : "Load a .BH archive or a .RM2/.SM2 file — scanning starts automatically.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredEntries) { entry in
                        Button {
                            selected = entry
                        } label: {
                            TextureThumbnailCell(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
            }
        }
    }

    private var filteredEntries: [TextureHubEntry] {
        guard !searchText.isEmpty else { return workspace.texturesHub }
        return workspace.texturesHub.filter {
            "\($0.texture.id)".localizedCaseInsensitiveContains(searchText)
                || $0.sourceLabel.localizedCaseInsensitiveContains(searchText)
        }
    }
}

private struct TextureThumbnailCell: View {
    let entry: TextureHubEntry
    /// Decoding is a computed property recomputed on every `body`
    /// evaluation — cheap once, but `LazyVGrid` re-evaluates every
    /// currently-visible cell's `body` on each scroll-driven relayout, so an
    /// uncached version re-decodes the same bytes into a fresh
    /// `CGDataProvider`/`CGImage` repeatedly while scrolling through a large
    /// hub. Same fix shape as `InspectorView`'s cached `resolveComposite`
    /// elsewhere in this app: decode once into `@State`, keyed off the
    /// entry's own identity.
    @State private var cachedImage: NSImage?
    /// Distinct from "hasn't decoded yet" (`cachedImage == nil` before the
    /// `.task` below runs) — this is only set once decode has genuinely
    /// failed, so the cell can show a real labeled placeholder instead of
    /// leaving the user staring at a spinner forever or an unlabeled
    /// warning triangle.
    @State private var decodeFailed = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let cachedImage {
                    Image(nsImage: cachedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if decodeFailed {
                    ZStack {
                        Color.red.opacity(0.18)
                        VStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.red)
                            Text("#\(entry.texture.id)")
                                .font(.caption2.bold())
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 4)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 96)
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            Text("#\(entry.texture.id)")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
            Text("\(entry.texture.width)×\(entry.texture.height) · \(entry.texture.pixelFormat.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: entry.id) {
            guard let cgImage = try? TextureExporter.cgImage(from: entry.texture) else {
                decodeFailed = true
                return
            }
            cachedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }
}

private struct TextureHubDetailView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    let entry: TextureHubEntry
    @State private var cachedImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Texture #\(entry.texture.id)").font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            if let cachedImage {
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Form {
                LabeledContent("Source File", value: entry.sourceLabel)
                LabeledContent("Dimensions", value: "\(entry.texture.width) × \(entry.texture.height)")
                LabeledContent("Pixel Format", value: entry.texture.pixelFormat.rawValue)
                LabeledContent("Mip Levels", value: "\(entry.texture.mips.count)")
            }
            .formStyle(.grouped)
            Button("Export PNG…") { export() }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 420)
        .task(id: entry.id) {
            guard let cgImage = try? TextureExporter.cgImage(from: entry.texture) else { return }
            cachedImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
    }

    private func export() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this texture into.") else { return }
        workspace.exportTexturePNG(entry.texture, suggestedName: "texture_\(entry.texture.id)", to: directory)
    }
}
