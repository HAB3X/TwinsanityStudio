import SwiftUI
import AppKit
import CTModels
import CTExport

/// "Font & Particle Sheets": browses every standalone `.ptc`/`.psm`/`.psf`
/// texture-atlas container opened this session — ports the reference
/// editor's `PTCViewer` (prev/next entry navigation, PNG export) plus the
/// read side of `PSMWorker`'s atlas browsing. Real decode (embedded
/// Texture+Material pairs via `TwinsPTCParser`) and real PNG export
/// (`TextureExporter`, the same path `TextureInspectorView` uses) — no
/// write-back: the reference's own texture *importer* is dead code
/// (`TextureImport.cs`'s `btnImport_Click` throws `NotImplementedException`
/// on its first line — see `TextureInspectorView`'s own "Replace with
/// Image…" for why this project already exceeds that baseline for
/// chunk-tree textures), and building a from-scratch PS2 texture *encoder*
/// (swizzle + palette generation) to support importing into a `.ptc`/
/// `.psm`/`.psf` entry is real, separate, higher-risk work this pass
/// doesn't attempt.
struct PTCSheetsHubView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSheetID: String?
    @State private var selectedEntryID: UInt32?

    private enum SheetRef: Identifiable, Hashable {
        case psm(String)
        case font(String)
        var id: String {
            switch self {
            case .psm(let label): return "psm:\(label)"
            case .font(let label): return "font:\(label)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sheetList
                Divider()
                entryList
                Divider()
                detail
            }
        }
        .frame(minWidth: 880, minHeight: 540)
        .onAppear {
            if selectedSheetID == nil {
                selectedSheetID = (workspace.ptcSheets.first.map { SheetRef.psm($0.sourceLabel) } ?? workspace.fontSheets.first.map { SheetRef.font($0.sourceLabel) })?.id
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Font & Particle Sheets").font(.title2.bold())
                Text("\(workspace.ptcSheets.count) sheet(s), \(workspace.fontSheets.count) font container(s) loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var sheetRefs: [SheetRef] {
        workspace.ptcSheets.map { .psm($0.sourceLabel) } + workspace.fontSheets.map { .font($0.sourceLabel) }
    }

    private var sheetList: some View {
        List(sheetRefs, selection: $selectedSheetID) { ref in
            switch ref {
            case .psm(let label):
                let sheet = workspace.ptcSheets.first { $0.sourceLabel == label }
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.callout.bold())
                    Text("\(sheet?.entries.count ?? 0) entries").font(.caption2).foregroundStyle(.secondary)
                }
                .tag(ref.id)
            case .font(let label):
                let font = workspace.fontSheets.first { $0.sourceLabel == label }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(label) (font)").font(.callout.bold())
                    Text("\(font?.fontPages.count ?? 0) pages, \(font?.vectors.count ?? 0) vectors").font(.caption2).foregroundStyle(.secondary)
                }
                .tag(ref.id)
            }
        }
        .frame(width: 220)
        .listStyle(.sidebar)
    }

    private var selectedEntries: [TwinsPTCEntry] {
        guard let selectedSheetID else { return [] }
        if let sheet = workspace.ptcSheets.first(where: { SheetRef.psm($0.sourceLabel).id == selectedSheetID }) {
            return sheet.entries
        }
        if let font = workspace.fontSheets.first(where: { SheetRef.font($0.sourceLabel).id == selectedSheetID }) {
            return font.fontPages
        }
        return []
    }

    @ViewBuilder
    private var entryList: some View {
        List(selectedEntries, selection: $selectedEntryID) { entry in
            HStack {
                Image(systemName: "photo")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tex #\(entry.texID) / Mat #\(entry.matID)").lineLimit(1)
                    Text("\(entry.texture.width)×\(entry.texture.height) · \(entry.material.name.isEmpty ? "<unnamed>" : entry.material.name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(entry.texID)
        }
        .frame(width: 280)
        .onChange(of: selectedSheetID) { _, _ in selectedEntryID = selectedEntries.first?.texID }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedEntryID, let entry = selectedEntries.first(where: { $0.texID == selectedEntryID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let nsImage = Self.nsImage(for: entry.texture) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 320)
                            .background(Color(nsColor: .underPageBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    }
                    Form {
                        Section("Texture") {
                            LabeledContent("ID", value: "\(entry.texID)")
                            LabeledContent("Size", value: "\(entry.texture.width) × \(entry.texture.height)")
                            LabeledContent("Format", value: entry.texture.pixelFormat.rawValue)
                        }
                        Section("Material") {
                            LabeledContent("ID", value: "\(entry.matID)")
                            LabeledContent("Name", value: entry.material.name.isEmpty ? "<unnamed>" : entry.material.name)
                            LabeledContent("Shaders", value: "\(entry.material.shaders.count)")
                        }
                    }
                    .formStyle(.grouped)
                    Button {
                        exportPNG(entry.texture)
                    } label: {
                        Label("Export PNG…", systemImage: "square.and.arrow.up")
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("No Entry Selected", systemImage: "photo.on.rectangle")
        }
    }

    private static func nsImage(for texture: TextureAsset) -> NSImage? {
        guard let cgImage = try? TextureExporter.cgImage(from: texture, mipLevel: nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func exportPNG(_ texture: TextureAsset) {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this texture as a .png file into.") else { return }
        let url = directory.appendingPathComponent("texture_\(texture.id)").appendingPathExtension("png")
        do {
            try TextureExporter.exportPNG(texture, to: url)
            workspace.statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            workspace.lastError = "Export failed: \(error)"
        }
    }
}
