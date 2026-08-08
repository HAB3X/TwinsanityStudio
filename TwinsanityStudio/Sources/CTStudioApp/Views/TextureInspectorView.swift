import SwiftUI
import AppKit
import CTModels
import CTExport

struct TextureInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let texture: TextureAsset
    @State private var selectedMip: Int = -1 // -1 = base level

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let nsImage {
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
                Spacer()
            }
        }
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to export this texture (and its mip levels) into."
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        workspace.exportTexturePNG(texture, suggestedName: node.displayName.replacingOccurrences(of: " ", with: "_"), to: directory)
    }
}
