import SwiftUI
import AppKit
import CTModels
import CTExport

struct TextureInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let texture: TextureAsset
    @State private var selectedMip: Int = -1 // -1 = base level
    @State private var upscaledTexture: TextureAsset?
    @State private var isUpscaling = false
    @State private var upscaleError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let upscaledTexture {
                upscaledPreview(upscaledTexture)
            } else if let nsImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .background(checkerboard)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            } else {
                ContentUnavailableView("Format Not Decoded", systemImage: "photo.badge.exclamationmark",
                    description: Text("\(texture.pixelFormat.rawValue.uppercased()) isn't fully decoded by this build — only the raw record is available."))
                    .frame(height: 200)
            }

            Form {
                LabeledContent("Dimensions", value: "\(texture.width) × \(texture.height)")
                Picker("Pixel Format", selection: .constant(texture.pixelFormat)) {
                    Text(texture.pixelFormat.rawValue.uppercased()).tag(texture.pixelFormat)
                }
                .disabled(true)
                if !texture.mips.isEmpty {
                    Picker("Preview Level", selection: $selectedMip) {
                        Text("Base (\(texture.width)×\(texture.height))").tag(-1)
                        ForEach(texture.mips.indices, id: \.self) { level in
                            let divisor = 1 << (level + 1)
                            Text("Mip \(level + 1) (\(texture.width / divisor)×\(texture.height / divisor))").tag(level)
                        }
                    }
                }
                LabeledContent("Fully Decoded", value: texture.pixelFormat.isFullyDecoded ? "Yes" : "No")
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    exportPNG()
                } label: {
                    Label("Export PNG…", systemImage: "square.and.arrow.up")
                }
                .disabled(!texture.pixelFormat.isFullyDecoded)
                Button {
                    presentUpscaleModelPanel()
                } label: {
                    Label(isUpscaling ? "Upscaling…" : "Upscale with CoreML Model…", systemImage: "sparkles")
                }
                .disabled(!texture.pixelFormat.isFullyDecoded || isUpscaling)
                if upscaledTexture != nil {
                    Button("Revert to Original") { upscaledTexture = nil }
                        .buttonStyle(.borderless)
                }
                Spacer()
                if isUpscaling { ProgressView().controlSize(.small) }
            }
            if let upscaleError {
                Label(upscaleError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// "Neural Texture Upscaling" (roadmap 5.4): real result of a real
    /// user-supplied model, shown alongside — never in place of, until the
    /// user explicitly reverts — the real decoded original, so it's never
    /// ambiguous which one is actually on disk versus model output.
    private func upscaledPreview(_ upscaled: TextureAsset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let cgImage = try? TextureExporter.cgImage(from: upscaled, mipLevel: nil) {
                Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .background(checkerboard)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            Text("Upscaled: \(upscaled.width) × \(upscaled.height) (from \(texture.width) × \(texture.height)) — real output from the model you selected, not decoded game data.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                exportUpscaledPNG(upscaled)
            } label: {
                Label("Export Upscaled PNG…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func presentUpscaleModelPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a real CoreML model (.mlmodel/.mlmodelc) trained for image super-resolution. No model ships with this build."
        guard panel.runModal() == .OK, let modelURL = panel.urls.first else { return }
        upscaleError = nil
        isUpscaling = true
        Task {
            do {
                let result = try await TextureUpscaler.upscale(texture, usingModelAt: modelURL)
                upscaledTexture = result
            } catch {
                upscaleError = error.localizedDescription
            }
            isUpscaling = false
        }
    }

    private func exportUpscaledPNG(_ upscaled: TextureAsset) {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export the upscaled texture into.") else { return }
        workspace.exportTexturePNG(upscaled, suggestedName: node.displayName.replacingOccurrences(of: " ", with: "_") + "_upscaled", to: directory)
    }

    private var nsImage: NSImage? {
        guard texture.pixelFormat.isFullyDecoded else { return nil }
        let mip = selectedMip >= 0 ? selectedMip : nil
        guard let cgImage = try? TextureExporter.cgImage(from: texture, mipLevel: mip) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = row
                while x < size.width {
                    let isDark = col.isMultiple(of: 2)
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)), with: .color(isDark ? Color(nsColor: .quaternaryLabelColor) : .clear))
                    x += tile
                    col += 1
                }
                y += tile
                row += 1
            }
        }
    }

    private func exportPNG() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this texture (and its mip levels) into.") else { return }
        workspace.exportTexturePNG(texture, suggestedName: node.displayName.replacingOccurrences(of: " ", with: "_"), to: directory)
    }
}
