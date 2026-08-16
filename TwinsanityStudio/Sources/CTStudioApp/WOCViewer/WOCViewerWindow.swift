import SwiftUI
import CoreGraphics
import CTParsers

enum WOCViewerTab: String, CaseIterable, Identifiable {
    case objects = "Placed Objects"
    case textures = "Textures"
    case entities = "AI / Entities"
    case scenery = "Scenery"
    case animations = "Animations"
    case paths = "Paths"
    case terrain = "Terrain"
    var id: String { rawValue }
}

struct WOCViewerWindow: View {
    let asset: WOCLevelAsset

    @State private var renderer: WOCViewerRenderer?
    @State private var tab: WOCViewerTab = .objects

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $tab) {
                ForEach(WOCViewerTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()

            switch tab {
            case .objects:
                HStack(spacing: 0) {
                    viewportArea
                    Divider()
                    objectSidebar
                        .frame(width: 300)
                }
            case .textures:
                WOCTextureGalleryView(textures: asset.textures)
            case .entities:
                WOCEntityListView(entities: asset.entities)
            case .scenery:
                WOCFoliageListView(foliage: asset.foliage)
            case .animations:
                WOCAnimationListView(animations: asset.animations, fileExistsButUnparsed: asset.animationFileExistsButUnparsed)
            case .paths:
                WOCPathInfoView(recordCount: asset.pathRecordCount)
            case .terrain:
                WOCTerrainInfoView(mainBlockByteCount: asset.terrainMainBlockByteCount, tailRecordCount: asset.terrainTailRecordCount)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            renderer = WOCViewerRenderer(objects: asset.objects, objectCount: asset.distinctObjectCount, objectMeshes: asset.objectMeshes)
        }
    }

    @ViewBuilder
    private var viewportArea: some View {
        if let renderer {
            if asset.objects.isEmpty {
                ContentUnavailableView(
                    "No Placed Objects",
                    systemImage: "square.dashed",
                    description: Text("This level's INST section decoded to zero instances.")
                )
            } else {
                ZStack(alignment: .bottomLeading) {
                    MetalModelView(renderer: renderer)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
                    Text("Drag to orbit · Scroll to zoom")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Metal Unavailable", systemImage: "exclamationmark.triangle", description: Text("Couldn't initialize a Metal device on this Mac."))
        }
    }

    private var objectSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(asset.name)
                    .font(.title3.bold())

                Form {
                    LabeledContent("Placed Objects", value: "\(asset.objects.count)")
                    LabeledContent("Distinct Objects", value: "\(asset.distinctObjectCount)")
                    LabeledContent("Named Entries", value: "\(asset.objectNames.count)")
                    LabeledContent("Textures", value: "\(asset.textureCount)")
                    LabeledContent("AI Entities", value: "\(asset.entities.count)")
                    LabeledContent("Foliage", value: "\(asset.foliage.count)")
                    LabeledContent("Animations", value: asset.animationFileExistsButUnparsed ? "present, undecoded" : "\(asset.animations.count)")
                    LabeledContent("Path Records", value: asset.pathRecordCount.map(String.init) ?? "none")
                    LabeledContent("Terrain", value: asset.terrainMainBlockByteCount.map { "\($0) bytes" } ?? "none")
                    LabeledContent("Sections", value: asset.sectionTags.joined(separator: ", "))
                }
                .formStyle(.grouped)

                statusNote

                if !asset.objectNames.isEmpty {
                    Divider()
                    Text("Name Table (\(asset.objectNames.count))")
                        .font(.subheadline.bold())
                    ForEach(Array(asset.objectNames.prefix(60).enumerated()), id: \.offset) { _, name in
                        Text(name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if asset.objectNames.count > 60 {
                        Text("+ \(asset.objectNames.count - 60) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
        }
    }

    private var statusNote: some View {
        Text("Each point is one real, decoded placed-object position and world transform (WoC's INST section), color-coded by which distinct object it is. This is not yet real mesh geometry — WoC's per-object mesh boundaries (inside its OBJ0 section) aren't decoded yet, so there's no reliable per-object shape to draw. What's shown here is real, correctly-positioned data, just points rather than final meshes.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

/// The actual UI surface for real texture decoding: every texture found in
/// the level's `TST0` section, decoded to real RGBA pixels
/// (`WOCTextureDecoder`) and shown as an image, not just a byte count in a
/// stats panel.
private struct WOCTextureGalleryView: View {
    let textures: [WOCDecodedTexture]

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12)]

    var body: some View {
        if textures.isEmpty {
            ContentUnavailableView("No Textures", systemImage: "photo.on.rectangle.angled", description: Text("This level's TST0 section decoded to zero textures."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(textures) { texture in
                        WOCTextureCard(texture: texture)
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct WOCTextureCard: View {
    let texture: WOCDecodedTexture

    var body: some View {
        VStack(spacing: 4) {
            if let cgImage = texture.cgImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .background(Color(white: 0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "questionmark.square.dashed")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 128, height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Text("\(texture.width)×\(texture.height)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if texture.usedPalette {
                Text("indexed")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// From the sibling `.AI` file: real enemy/AI entity spawns with their
/// patrol waypoint counts (see `WOCAIParser`).
private struct WOCEntityListView: View {
    let entities: [WOCAIParser.Entity]

    var body: some View {
        if entities.isEmpty {
            ContentUnavailableView("No AI Entities", systemImage: "figure.walk", description: Text("This level has no sibling .AI file, or it decoded to zero entities."))
        } else {
            List(Array(entities.enumerated()), id: \.offset) { _, entity in
                HStack {
                    Text(entity.name)
                        .font(.body.monospaced())
                    Spacer()
                    Text("\(entity.waypoints.count) waypoint\(entity.waypoints.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// From the sibling `.GRA` file: real foliage/grass scatter placements
/// (see `WOCGrassParser`).
private struct WOCFoliageListView: View {
    let foliage: [WOCGrassParser.Placement]

    var body: some View {
        if foliage.isEmpty {
            ContentUnavailableView("No Scenery/Foliage", systemImage: "leaf", description: Text("This level has no sibling .GRA file, or it decoded to zero placements."))
        } else {
            List(Array(foliage.enumerated()), id: \.offset) { _, placement in
                HStack {
                    Text(placement.name)
                        .font(.body.monospaced())
                    Spacer()
                    Text(String(format: "(%.1f, %.1f, %.1f)", placement.position.x, placement.position.y, placement.position.z))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// From the sibling `.ANM` file: real simple-object-animation entries
/// (see `WOCAnimationParser`). Skeletal-animation files, a different and
/// still-undecoded format, are surfaced honestly rather than shown as
/// garbage entries.
private struct WOCAnimationListView: View {
    let animations: [WOCAnimationParser.Entry]
    let fileExistsButUnparsed: Bool

    var body: some View {
        if fileExistsButUnparsed {
            ContentUnavailableView(
                "Animation Format Not Yet Decoded",
                systemImage: "figure.run.circle",
                description: Text("This level has a sibling .ANM file, but it's a skeletal-animation format (like TOONARMY.ANM) that isn't decoded yet — not the simple object-animation format that is.")
            )
        } else if animations.isEmpty {
            ContentUnavailableView("No Animations", systemImage: "play.rectangle", description: Text("This level has no sibling .ANM file, or it decoded to zero entries."))
        } else {
            List(Array(animations.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.body.monospaced())
                    Text("flag \(entry.flag) · \(entry.subEntries.count) sub-entr\(entry.subEntries.count == 1 ? "y" : "ies")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// From the sibling `.PAD` file: confirmed record count and outer
/// framing, but record *semantics* are unresolved (see `WOCPadParser`) —
/// shown as a raw count, not interpreted as an actual path graph.
private struct WOCPathInfoView: View {
    let recordCount: Int?

    var body: some View {
        if let recordCount {
            VStack(spacing: 12) {
                Text("\(recordCount)")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                Text("path records")
                    .foregroundStyle(.secondary)
                Text("This level's .PAD file framing is decoded, but record semantics (likely an AI path-node graph) aren't reverse-engineered yet — this is a real, honest record count, not interpreted path data.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Path Data", systemImage: "point.topleft.down.curvedto.point.bottomright.up", description: Text("This level has no sibling .PAD file."))
        }
    }
}

/// From the sibling `.TER` file: confirmed outer framing only — the bulk
/// of real terrain/collision geometry (the "main block") is not decoded
/// yet, so this shows how much real data is there without pretending to
/// show its content (see `WOCTerrainParser`).
private struct WOCTerrainInfoView: View {
    let mainBlockByteCount: Int?
    let tailRecordCount: Int?

    var body: some View {
        if let mainBlockByteCount, let tailRecordCount {
            VStack(spacing: 12) {
                Form {
                    LabeledContent("Main Block", value: "\(mainBlockByteCount) bytes")
                    LabeledContent("Tail Records", value: "\(tailRecordCount)")
                }
                .formStyle(.grouped)
                .frame(maxWidth: 420)
                Text("This level's .TER outer framing is decoded, but the main block's internal terrain geometry isn't reverse-engineered yet — these are real byte/record counts, not interpreted terrain data.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Terrain Data", systemImage: "mountain.2", description: Text("This level has no sibling .TER file."))
        }
    }
}

private extension WOCDecodedTexture {
    /// Builds a real `CGImage` from the decoded RGBA bytes. `nil` when
    /// decoding genuinely failed (e.g. an indexed texture whose CLUT
    /// couldn't be found — `rgba` is empty in that case, not fabricated
    /// pixels) rather than ever showing a placeholder image as if it were
    /// real data.
    ///
    /// Alpha scaling: PS2 GS alpha is a 7-bit channel (0...0x80 represents
    /// 0.0...1.0 in the hardware's own blending equations, not the 8-bit
    /// 0...255 a `CGImage` expects) — real, standard, publicly documented
    /// PS2 hardware behavior, not something reverse-engineered from these
    /// files specifically. Values are doubled and clamped to convert.
    var cgImage: CGImage? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var scaled = rgba
        for i in stride(from: 3, to: scaled.count, by: 4) {
            scaled[i] = UInt8(min(255, Int(scaled[i]) * 2))
        }
        guard let provider = CGDataProvider(data: Data(scaled) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
