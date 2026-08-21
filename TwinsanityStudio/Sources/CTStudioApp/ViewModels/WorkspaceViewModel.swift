import Foundation
import SwiftUI
import simd
import CTCore
import CTModels
import CTParsers
import CTExport

/// One entry in the Textures Hub (QoL sweep) — a decoded texture plus which
/// file it came from. Own type rather than reusing `TextureAsset.id`
/// directly as `Identifiable`: `TextureAsset.id` is the on-disk record ID,
/// which (same reasoning as `ResolvedModelAsset.id`) recurs constantly
/// across hundreds of different files in a global, workspace-wide list.
public struct TextureHubEntry: Sendable, Identifiable, Codable {
    public let id = UUID()
    public var sourceLabel: String
    public var texture: TextureAsset

    public init(sourceLabel: String, texture: TextureAsset) {
        self.sourceLabel = sourceLabel
        self.texture = texture
    }
}

/// One entry in the Levels Hub — a decoded `SceneryData` record (a level's
/// static-geometry placement tree) plus the `ChunkNode` it came from, so
/// clicking a card can both resolve its placements (`resolvedLevelPlacements`)
/// and look up sibling `Instance` records in the same file for the Level
/// Viewer's markers. Deliberately *not* `Codable`/cached through
/// `ScanCache` like `ResolvedModelAsset`/`TextureHubEntry` are: `ChunkNode`
/// is a reference-type chunk tree, not a value snapshot, so this only ever
/// exists for files that are actually parsed and held in memory this
/// session — same as browsing the sidebar tree itself, `levelsHub` is empty
/// again after a cache-hit load until something re-parses the file.
public struct LevelHubEntry: Sendable, Identifiable {
    public let id = UUID()
    public var sourceLabel: String
    public var scenery: SceneryAsset
    public var node: ChunkNode

    public init(sourceLabel: String, scenery: SceneryAsset, node: ChunkNode) {
        self.sourceLabel = sourceLabel
        self.scenery = scenery
        self.node = node
    }
}

/// One line in the Engine Console (blueprint 7.5) — a real status/error
/// event this session actually produced, timestamped when it happened.
public struct EngineLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let message: String
    public let isError: Bool

    public init(timestamp: Date = Date(), message: String, isError: Bool) {
        self.timestamp = timestamp
        self.message = message
        self.isError = isError
    }
}

/// Drives the whole workspace: what's open, the search filter, the current
/// selection, and drag-drop ingestion. One instance is shared by the whole
/// app (`ContentView` owns it as a `@StateObject`).
@MainActor
public final class WorkspaceViewModel: ObservableObject {
    @Published public var rootNodes: [ChunkNode] = []
    @Published public var searchQuery: String = ""
    /// `nil` means "every kind" — set to jump straight to e.g. every decoded
    /// `Animation` in the workspace, regardless of which file it's buried in.
    @Published public var typeFilter: ChunkPayload.Kind?
    /// "Smart File Filtering" (Settings' Developer Mode toggle): when
    /// `false` (the default), `filteredRootNodes` prunes undecoded/raw
    /// leaves and any folder that only contains them — see `ChunkNode.
    /// prunedOfRawContent()`. Persisted so a developer who turns this on
    /// doesn't have to re-toggle it every launch.
    @Published public var showRawFiles = false {
        didSet { UserDefaults.standard.set(showRawFiles, forKey: Self.showRawFilesDefaultsKey) }
    }
    private static let showRawFilesDefaultsKey = "TwinsanityStudio.ShowRawFiles"
    @Published public var selectedNode: ChunkNode?
    /// "Real-Time Engine Console" (blueprint 7.5): every non-empty value
    /// this property (and `lastError` below) ever takes is also appended to
    /// `engineLog` — one `didSet` here instead of touching every one of the
    /// ~20 call sites that already set `statusMessage` throughout this file,
    /// so the console always shows exactly the same real events the status
    /// banner does, nothing invented. Note this deliberately does *not*
    /// attempt "translating raw hex crash addresses into plain-language
    /// explanations" from the original blueprint wording — that needs a
    /// crash/symbolication pipeline this app has no source for; the console
    /// is a real event log, not a fabricated one.
    @Published public var statusMessage: String = "Drop a .BH/.BD archive, .RM2/.SM2 file, or a folder to begin." {
        didSet { if !statusMessage.isEmpty { engineLog.append(EngineLogEntry(message: statusMessage, isError: false)) } }
    }
    @Published public var isLoading = false
    @Published public var isScanning = false
    /// "Visual Loading Feedback": every save path (`saveHexEdit`,
    /// `saveLevelOverrides`, the Position/Instance/Trigger/Camera inspector
    /// "Save Edited Copy…" buttons) writes a full patched copy of the
    /// source file, which can be a genuinely large level file even for a
    /// tiny edit — real work, not a formality, so it gets the same
    /// real spinner treatment as loading. See `writeDataAsync`.
    @Published public var isSaving = false
    /// "Visual Loading Feedback" (performance mandate, Part 4): real
    /// per-file progress during `scanAllArchives()` — `nil` when no scan
    /// is running. Updated in throttled batches (not on every single file)
    /// so a scan of thousands of files doesn't pay a MainActor hop per
    /// file just to report progress.
    @Published public var scanProgress: (completed: Int, total: Int)?
    /// "Responsive Main Thread... allowing... cancellations" (performance
    /// mandate, Part 4): a real, working cancel path — `cancelScan()`
    /// cancels this exact task, and `scanAllArchives`'s own loop checks
    /// `Task.isCancelled` between archives to actually stop starting new
    /// work rather than just discarding the result at the end.
    private var scanTask: Task<Void, Never>?

    public func cancelScan() {
        scanTask?.cancel()
    }
    @Published public var lastError: String? {
        didSet { if let lastError { engineLog.append(EngineLogEntry(message: lastError, isError: true)) } }
    }
    /// Rolling log backing the Engine Console drawer. Unbounded growth isn't
    /// a real concern for a desktop inspection session (thousands of
    /// entries is still a trivially small array of small structs), so this
    /// doesn't truncate.
    @Published public private(set) var engineLog: [EngineLogEntry] = []

    public func clearEngineLog() {
        engineLog.removeAll()
    }

    // MARK: - Memory Card Inspector (blueprint 7.3)

    /// Non-nil presents the Memory Card Inspector sheet (see `ContentView`).
    @Published public var memoryCardAsset: MemoryCardAsset?

    /// "Global Command/Search Bar" (⌘K) — see `ContentView`'s `.commands`.
    @Published public var isCommandPalettePresented = false

    /// A completely separate document type from the `.BD`/`.RM2` workspace
    /// tree above — a PS2 memory card image has nothing to do with
    /// Twinsanity's own formats, so this doesn't touch `rootNodes` at all.
    public func openMemoryCard(url: URL) {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            memoryCardAsset = try MemoryCardParser.parse(data: data)
            statusMessage = "Loaded memory card \(url.lastPathComponent)."
        } catch {
            lastError = "Couldn't read \(url.lastPathComponent) as a PS2 memory card: \(error)"
        }
    }

    // MARK: - Disc Image Mounting (roadmap 1.4/Task 7 — ISO-9660 / BIN-CUE)

    /// Extension this build recognizes well enough to be worth offering an
    /// "extract and open" action for — the same real chunk/archive/sound-
    /// bank/cross-engine extensions the regular Open panel accepts.
    nonisolated static let recognizedDiscFileExtensions: Set<String> = ["RM2", "SM2", "RMX", "SMX", "BH", "BD", "MH", "MB", "CRT", "WMP"]

    /// Real `ISO9660Entry` + the `LogicalSectorSource` to extract it from,
    /// keyed by the synthetic `ChunkNode.id` mirroring it in `rootNodes` —
    /// lets `select(_:)` extract and open a disc-mounted file's real bytes
    /// on click, the same one-click affordance an archive entry already
    /// has, without `ChunkNode`/`ISO9660Entry` needing to know about each
    /// other. Only real file leaves are registered (never directories —
    /// nothing to extract for those, they're just tree structure).
    private var discEntryByNodeID: [UUID: CTModels.DiscEntryHolder] = [:]
    /// One real, not-yet-decoded clip inside a mounted WoC sound archive
    /// (`SFX.DAT`/`ATS.DAT`), keyed by the synthetic leaf `ChunkNode.id`
    /// `expandWOCSoundArchive` mints for it. Decoding all ~782 real clips
    /// up front (hundreds of MB of PCM) isn't reasonable just to populate
    /// a browsable tree -- this is the same "lazy, decode on click"
    /// pattern `discEntryByNodeID`/`expandArchiveEntry` already use for a
    /// `.BH` archive's unopened entries, just keyed to one numbered record
    /// inside an already-extracted archive file rather than a whole
    /// separate file. See `ChunkNode.isLazyLoadable` for how these leaves
    /// stay visible under "Smart File Filtering" despite having no real
    /// file extension to key off of.
    private var wocSoundClipPending: [UUID: (archiveURL: URL, entry: WOCSoundParser.Entry)] = [:]
    /// "ISO/ROM Rebuild" (roadmap 7): the source `.iso` file each mounted
    /// disc's top-level `ChunkNode.id` was actually read from — only
    /// populated for a plain `.iso` mount, never a `.bin`/`.cue` pair
    /// (`ISO9660Writer` only rebuilds a flat `.iso`; see its own doc
    /// comment for why raw-sector `.bin` framing is out of scope). Lets
    /// `replacingDiscImage` re-read the real original bytes fresh from
    /// disk rather than needing to keep a second full copy in memory
    /// alongside whatever `mountDiscImage` already mapped in.
    private var mountedDiscImageURLByRootID: [UUID: URL] = [:]

    /// "Native ISO & BIN/CUE Disc Image Mounting" (roadmap 1.4/Task 7),
    /// merged directly into the main sidebar tree — not a separate modal
    /// browser. Mounts a real `.iso`, or a `.bin`/`.cue` pair, reads its
    /// real ISO-9660 root directory, and adds it to `rootNodes` as a real
    /// top-level entry the user can browse, filter, and search exactly
    /// like any other opened archive — clicking a recognized file extracts
    /// and opens it through the same real `open(url:)` pipeline a file
    /// picked from a regular folder uses. `.mappedIfSafe` so mounting a
    /// multi-gigabyte disc image doesn't materialize the whole thing in
    /// RAM up front — only the sectors `ISO9660Reader` actually touches
    /// (the volume descriptor, directory extents, and whichever file gets
    /// opened) get paged in.
    public func mountDiscImage(url: URL) {
        do {
            let source: any LogicalSectorSource
            switch url.pathExtension.uppercased() {
            case "ISO":
                source = PlainISOSource(data: try Data(contentsOf: url, options: .mappedIfSafe))
            case "CUE":
                let cue = try CueSheetParser.parse(contents: try String(contentsOf: url, encoding: .ascii))
                let binURL = url.deletingLastPathComponent().appendingPathComponent(cue.binFileName)
                let binData = try Data(contentsOf: binURL, options: .mappedIfSafe)
                source = BinCueLogicalSource(binData: binData, framing: cue.framing)
            case "BIN":
                let cueURL = url.deletingPathExtension().appendingPathExtension("cue")
                guard FileManager.default.fileExists(atPath: cueURL.path) else {
                    lastError = "\(url.lastPathComponent) has no matching .cue file alongside it — a raw .bin's sector framing can't be determined without one."
                    return
                }
                let cue = try CueSheetParser.parse(contents: try String(contentsOf: cueURL, encoding: .ascii))
                let binData = try Data(contentsOf: url, options: .mappedIfSafe)
                source = BinCueLogicalSource(binData: binData, framing: cue.framing)
            default:
                lastError = "\(url.lastPathComponent) isn't a recognized disc image — choose a .iso, .bin, or .cue file."
                return
            }
            let root = try ISO9660Reader.readRootDirectory(from: source)
            let node = Self.buildDiscNode(from: root, isRoot: true)
            registerDiscEntries(root, node: node, source: source)
            if url.pathExtension.uppercased() == "ISO" {
                mountedDiscImageURLByRootID[node.id] = url
            }
            rootNodes.append(node)
            statusMessage = "Mounted \(url.lastPathComponent) — \(discEntryByNodeID.count) recognized file(s) available to open."
        } catch let error as CueSheetParser.ParseError {
            lastError = "Couldn't read \(url.lastPathComponent)'s cue sheet: \(error)"
        } catch is ISO9660Error {
            lastError = "\(url.lastPathComponent) doesn't look like a real ISO-9660 disc image (no valid volume descriptor found)."
        } catch {
            lastError = "Couldn't mount \(url.lastPathComponent): \(error)"
        }
    }

    /// Mirrors one `ISO9660Entry` (and, recursively, its children) into a
    /// real `ChunkNode` so the sidebar's existing `OutlineGroup`/filter/
    /// search machinery — all built around `ChunkNode` — renders it with
    /// zero special-casing. `sectionType` stays `.null` (same as an
    /// unexpanded archive-index entry): a disc entry isn't chunk-headered
    /// data itself, just a directory listing.
    private nonisolated static func buildDiscNode(from entry: ISO9660Entry, isRoot: Bool) -> ChunkNode {
        // A disc file's own name never ends in `.RM2`/`.SM2` — those live
        // packed *inside* `CRASH.BH`/`CRASH.BD`, invisible to the ISO's own
        // directory listing — so `looksLikeChunkFileName` alone never
        // matches anything here, and every disc leaf (`CRASH.BH` included)
        // silently vanished under "Smart File Filtering"'s default pruning
        // before this was wired up. `recognizedDiscFileExtensions` existed
        // for exactly this and was simply never consulted — a real bug,
        // not a design choice: mounting a disc image showed nothing at all.
        let ext = (entry.name as NSString).pathExtension.uppercased()
        let node = ChunkNode(
            recordID: 0,
            sectionType: .null,
            displayName: isRoot ? "\(entry.name.isEmpty ? "Disc" : entry.name)" : entry.name,
            byteSize: Int(entry.size),
            fileOffset: Int(entry.lba),
            isLazyLoadable: !entry.isDirectory && recognizedDiscFileExtensions.contains(ext)
        )
        node.children = entry.children
            .sorted { $0.name < $1.name }
            .map { buildDiscNode(from: $0, isRoot: false) }
        return node
    }

    /// Populates `discEntryByNodeID` for every real (non-directory) entry
    /// in this mounted disc's mirrored tree — walked separately from
    /// `buildDiscNode` since that one's `nonisolated static` (safe to call
    /// off the main actor if ever needed) while this mutates `@MainActor`
    /// state.
    private func registerDiscEntries(_ entry: ISO9660Entry, node: ChunkNode, source: any LogicalSectorSource) {
        if !entry.isDirectory {
            discEntryByNodeID[node.id] = CTModels.DiscEntryHolder(entry: entry, source: source)
        }
        let sortedChildren = entry.children.sorted { $0.name < $1.name }
        for (childEntry, childNode) in zip(sortedChildren, node.children) {
            registerDiscEntries(childEntry, node: childNode, source: source)
        }
    }

    /// "ISO/ROM Rebuild" (roadmap 7): whether `node` is a disc-mounted file
    /// this build can actually replace — real disc entry, and mounted from
    /// a plain `.iso` (not `.bin`/`.cue`; see `mountedDiscImageURLByRootID`'s
    /// doc comment).
    public func canReplaceDiscFile(_ node: ChunkNode) -> Bool {
        guard discEntryByNodeID[node.id] != nil, let root = topLevelRoot(containing: node, in: rootNodes) else { return false }
        return mountedDiscImageURLByRootID[root.id] != nil
    }

    /// Re-reads the disc's real original `.iso` bytes fresh from disk (so
    /// this never depends on whatever `mountDiscImage` may have mapped in
    /// staying resident) and hands them to `ISO9660Writer` to replace
    /// `node`'s contents with `newData`. Returns the complete new image,
    /// ready to save — the original file on disk is never modified.
    /// `nil` (with `lastError` set) if `node` isn't a replaceable disc
    /// entry (see `canReplaceDiscFile`) or the rebuild itself fails.
    public func replacingDiscImage(afterReplacing node: ChunkNode, with newData: Data) -> Data? {
        guard let holder = discEntryByNodeID[node.id], let entry = holder.entry as? ISO9660Entry else {
            lastError = "This isn't a recognized disc-mounted file."
            return nil
        }
        guard let root = topLevelRoot(containing: node, in: rootNodes), let imageURL = mountedDiscImageURLByRootID[root.id] else {
            lastError = "This file's disc image was mounted from a .bin/.cue pair — rebuilding a raw-sector image isn't supported yet, only a plain .iso."
            return nil
        }
        do {
            let originalImage = try Data(contentsOf: imageURL)
            return try ISO9660Writer.replacingFile(entry, with: newData, in: originalImage)
        } catch {
            lastError = "Couldn't rebuild \(imageURL.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// The top-level entry in `rootNodes` whose subtree actually contains
    /// `target` — unlike `findFileRoot` (which looks specifically for an
    /// RM2/SM2-shaped Graphics/Code file root and wouldn't recognize a
    /// disc-mounted node's shape at all), this is a plain ancestor lookup
    /// that works for any node in the sidebar tree.
    private func topLevelRoot(containing target: ChunkNode, in topLevelNodes: [ChunkNode]) -> ChunkNode? {
        func contains(_ node: ChunkNode) -> Bool {
            node === target || node.children.contains(where: contains)
        }
        return topLevelNodes.first(where: contains)
    }

    /// Extracts `entry`'s real bytes from `source`, writes them to a temp
    /// file, and hands off to the *existing* `open(url:)` — reusing the
    /// one real, already-tested ingestion path rather than a second
    /// parallel one for disc-mounted files.
    ///
    /// A real, reported bug: for a `.BH` (or `.BD`) entry specifically,
    /// this used to extract *only* the one file clicked. `open(url:)`'s
    /// `.BH` handling (`BDArchiveParser.readIndex`) parses the index fine
    /// from that alone — real archive entries showed up correctly — but
    /// every entry's own data lives in the sibling `.BD`, which
    /// `counterpartURL(for:)` expects to find *alongside* the `.BH` in the
    /// same directory. Since only the `.BH` was ever extracted, every
    /// attempt to actually read an entry's bytes ("Parse") failed with
    /// "CRASH.BD ... no such file" — the sibling was never there to find.
    /// Now the real sibling is located in the disc's own tree (same
    /// pairing `siblingActorEntryName`/`registerDiscEntries` already use
    /// elsewhere) and extracted into the same temp directory first.
    private func openDiscEntry(_ entry: ISO9660Entry, source: any LogicalSectorSource, node: ChunkNode) {
        guard let data = ISO9660Reader.readFile(entry, from: source) else {
            lastError = "Couldn't read \(entry.name)'s real bytes from the mounted image."
            return
        }
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempURL = tempDirectory.appendingPathComponent(entry.name)
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            try data.write(to: tempURL)
            if let (siblingEntry, siblingSource) = discArchiveSibling(of: entry, node: node) {
                let siblingData = ISO9660Reader.readFile(siblingEntry, from: siblingSource)
                if let siblingData {
                    try siblingData.write(to: tempDirectory.appendingPathComponent(siblingEntry.name))
                } else {
                    lastError = "Couldn't read \(siblingEntry.name)'s real bytes from the mounted image — \(entry.name) will only show its index, not real entry data."
                }
            }
            open(url: tempURL)
        } catch {
            lastError = "Couldn't extract \(entry.name) from the mounted image: \(error)"
        }
    }

    /// `entry`'s real `.BH`/`.BD` counterpart, if `entry` is one half of an
    /// archive pair and its sibling is also a real disc-mounted leaf in
    /// the same directory — `nil` for every other kind of disc entry
    /// (nothing else needs a paired extraction).
    private func discArchiveSibling(of entry: ISO9660Entry, node: ChunkNode) -> (entry: ISO9660Entry, source: any LogicalSectorSource)? {
        let ext = (entry.name as NSString).pathExtension
        let siblingExt: String
        switch ext {
        case "BH": siblingExt = "BD"
        case "bh": siblingExt = "bd"
        case "BD": siblingExt = "BH"
        case "bd": siblingExt = "bh"
        default: return nil
        }
        let siblingName = (entry.name as NSString).deletingPathExtension + "." + siblingExt
        guard let parentNode = parent(of: node, inAnyOf: rootNodes) else { return nil }
        guard let siblingNode = parentNode.children.first(where: { $0.displayName.caseInsensitiveCompare(siblingName) == .orderedSame }) else { return nil }
        guard let siblingHolder = discEntryByNodeID[siblingNode.id],
              let siblingEntry = siblingHolder.entry as? ISO9660Entry,
              let siblingSource = siblingHolder.source as? any LogicalSectorSource
        else { return nil }
        return (siblingEntry, siblingSource)
    }

    /// Non-nil presents the Model Viewer sheet (see `ContentView`).
    @Published public var modelViewerAsset: ResolvedModelAsset?
    /// Non-nil presents the Collision Viewer sheet (see `ContentView`).
    @Published public var collisionViewerMesh: CollisionMesh?
    /// Non-nil presents the Level Viewer sheet (see `ContentView`).
    @Published public var levelViewerContext: LevelViewerContext?
    /// A live query for "wherever the 3D camera currently is" — set by
    /// `LevelViewerWindow` while it's open, cleared on close. The
    /// reference editor's `PositionEditor`/`AIPositionEditor`/
    /// `AIPathEditor`'s own "Copy Viewer Pos" buttons read the *currently
    /// open* 3D viewer's camera at the moment of the click, not a
    /// continuously-mirrored value — this closure indirection matches
    /// that same "ask right now" semantics without `PositionInspectorView`
    /// (a plain sidebar sheet, not necessarily backed by an open Level
    /// Viewer) needing a direct reference to whichever `LevelViewerRenderer`
    /// happens to be alive. `nil` when no Level Viewer is open, or when
    /// the one that's open belongs to a different file than the position
    /// being edited — this build doesn't try to disambiguate multiple
    /// simultaneously-open viewers, matching the reference tool's own
    /// single-viewer-at-a-time design.
    public var currentViewerCameraPositionProvider: (() -> SIMD3<Float>?)?
    /// Every RigidModel/Skeleton successfully resolved (mesh + textures, and
    /// skeleton + animations where rigged) across every scanned file —
    /// populated automatically as archives are scanned, so browsing models
    /// never requires manually parsing/resolving a specific chunk first.
    @Published public var modelsHub: [ResolvedModelAsset] = []
    @Published public var isModelsHubPresented = false
    /// "Global Thumbnails": every `Instance.objectID` this session has
    /// ever successfully resolved to real geometry in *any* opened level,
    /// keyed by that `objectID` — grows every time `placeModeContent`'s
    /// Forge Palette resolves one (see `recordGlobalObjectThumbnail`), so
    /// an object seen once in level A still shows its real thumbnail (and
    /// counts as "available") when browsing the palette in level B, even
    /// though B's own file has no geometry for it. Deliberately session-
    /// only, not persisted to `ScanCache` or eagerly built by scanning
    /// every archive up front — `objectID -> GameObject -> mesh` isn't
    /// data any existing scan pass already computes (unlike `modelsHub`,
    /// which resolves `RigidModel`/`Skeleton` records directly by their
    /// own on-disk ID), and eagerly resolving every real `GameObject` in
    /// every scanned file just to pre-fill this would risk the same
    /// scan-time memory/perf cost class the codebase already hit once
    /// with over-eager `ScanCache` persistence. Grows for free instead,
    /// piggybacking on resolution work the palette was doing anyway.
    @Published public private(set) var globalObjectThumbnails: [UInt16: ResolvedModelAsset] = [:]

    /// Records a real, already-resolved object so later Forge Palette
    /// views (in a different level) can show its thumbnail too. Never
    /// overwrites an existing entry — first successful resolution is as
    /// good as any other for a thumbnail, and re-storing the same
    /// (mesh+texture-carrying) value on every re-render would be pure
    /// waste.
    public func recordGlobalObjectThumbnail(objectID: UInt16, asset: ResolvedModelAsset) {
        guard globalObjectThumbnails[objectID] == nil else { return }
        globalObjectThumbnails[objectID] = asset
    }
    /// "Textures Hub" (QoL sweep) — every decoded texture across every
    /// scanned file, populated alongside `modelsHub` the same way.
    @Published public var texturesHub: [TextureHubEntry] = []
    @Published public var isTexturesHubPresented = false
    /// "Cross-Engine Texture Variant": every real, decoded texture from a
    /// user-loaded Wrath of Cortex `.GSC` level (typically `CRATES.GSC`),
    /// offered as a candidate texture override for a Twinsanity crate's
    /// own real, working UVs — see `ResolvedModelAsset.
    /// applyingTextureOverride(_:)`'s own doc comment for why this
    /// sidesteps WoC's still-undecoded per-vertex UV data entirely
    /// (Twinsanity's own UVs do the wrapping; only the pixel data comes
    /// from WoC). Empty until the user explicitly loads a `.GSC` file —
    /// this build never guesses which WoC texture "is" a given crate
    /// type, since that correspondence isn't decoded data, just a real
    /// picker over real, honestly-labeled textures.
    @Published public var wocCrateTextureLibrary: [TextureHubEntry] = []

    /// Loads every real, decoded texture from a real Wrath of Cortex
    /// `.GSC` file (RNC-decompressed if needed, same real pipeline
    /// `WOCLevelLoader.load` already uses for the sidebar's WoC level
    /// tree) into `wocCrateTextureLibrary`. Appends to (doesn't replace)
    /// any textures already loaded from a previous file, de-duplicated by
    /// real pixel content so loading the same file twice — or two files
    /// that happen to share a texture — doesn't create visible
    /// duplicates in the picker.
    public func loadWOCCrateTextureLibrary(from url: URL) {
        do {
            let raw = try Data(contentsOf: url)
            let bytes = [UInt8](raw)
            let containerBytes = RNCDecompressor.isRNCStream(bytes) ? Data(try RNCDecompressor.decompress(bytes, verifyCRC: true)) : raw
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let gscURL = tempDir.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("GSC")
            try containerBytes.write(to: gscURL)
            let asset = try WOCLevelLoader.load(gscURL: gscURL, name: url.deletingPathExtension().lastPathComponent)

            var existingHashes = Set(wocCrateTextureLibrary.map { Data($0.texture.rgba).hashValue })
            var added = 0
            for decoded in asset.textures where !decoded.rgba.isEmpty {
                let hash = Data(decoded.rgba).hashValue
                guard !existingHashes.contains(hash) else { continue }
                existingHashes.insert(hash)
                let texture = TextureAsset(id: UInt32(decoded.id), width: decoded.width, height: decoded.height, pixelFormat: .rawRGBA, rgba: decoded.rgba)
                wocCrateTextureLibrary.append(TextureHubEntry(sourceLabel: "\(url.lastPathComponent) — texture #\(decoded.id)", texture: texture))
                added += 1
            }
            statusMessage = "Loaded \(added) new real WoC texture(s) from \(url.lastPathComponent) (\(wocCrateTextureLibrary.count) total in the library)."
        } catch {
            lastError = "Couldn't load WoC textures from \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
    /// "Visual Levels Hub" — every decoded `SceneryData` record (one per
    /// level file that actually has an assembled scenery tree) across every
    /// parsed file, populated alongside `modelsHub`/`texturesHub`. See
    /// `LevelHubEntry`'s doc comment for why this one isn't cache-backed.
    @Published public var levelsHub: [LevelHubEntry] = []
    @Published public var isLevelsHubPresented = false
    /// "Audio Bank Extractor & Player" (roadmap 2.4) — every standalone
    /// `.MH`/`.MB` sound bank opened this session (`MUSIC`, `ENGLISH`,
    /// ...). Loaded asynchronously (`loadSoundBankAsync`) since the real
    /// `.MB` payload can be well over 200MB — never blocks the main actor
    /// like every other heavy parse in this view model.
    @Published public var soundBanks: [SoundBankAsset] = []
    @Published public var isSoundBanksHubPresented = false
    @Published public var isLoadingSoundBank = false
    /// Every standalone `.ptc`/`.psm` font/particle-sprite sheet opened
    /// this session — unlike `.MH`/`.MB` sound banks, these are small,
    /// single-file, self-contained formats (real embedded Texture/Material
    /// pairs, not a separate index+data pair), so loading is synchronous.
    /// A standalone `.ptc` file is modeled as a one-entry `TwinsPSMAsset`
    /// rather than a third array — same real on-disk shape (a
    /// `TwinsPTCEntry`), just one of them.
    @Published public var ptcSheets: [TwinsPSMAsset] = []
    /// Every standalone `.psf` font container opened this session.
    @Published public var fontSheets: [TwinsPSFAsset] = []
    @Published public var isPTCSheetsHubPresented = false
    /// Every dangling reference / unreferenced record flagged by the
    /// "Scrapped Content Scanner" across every scanned file — populated
    /// alongside `modelsHub` so cut content surfaces automatically as
    /// archives are scanned, with no separate manual scan step.
    @Published public var orphanedContent: [OrphanedAsset] = []
    @Published public var isScrappedContentScannerPresented = false
    /// "Asset Diff & Version Comparison" (blueprint 4.3): non-nil presents
    /// the diff sheet.
    @Published public var isAssetDiffPresented = false
    /// "Offline Mod Package Manager (.Crate Hub)" (roadmap 3.3): presents
    /// `ModCrateInspectorView`. Unlike the other hubs, this isn't gated on
    /// any workspace scan state — it opens standalone `.crate` files
    /// directly, independent of whatever archive is currently loaded.
    @Published public var isModCrateHubPresented = false
    /// "Executable Patcher" — presents `ExecutablePatcherView`. Also
    /// independent of any open archive: it operates on the game's boot
    /// executable directly (`default.xbe`/PS2 binary), a file this
    /// workspace never otherwise loads.
    @Published public var isExecutablePatcherPresented = false
    /// "Archive Repackager" — presents `ArchiveRepackagerView`. Also
    /// independent of any open archive: it operates on a `.BH`/`.BD` pair
    /// the user picks directly, not anything already mounted here.
    @Published public var isArchiveRepackagerPresented = false
    @Published public var isImageMakerPresented = false

    /// A real, ready-to-build "Quick Launch" plan for whatever chunk is
    /// currently open in the Level Viewer — `startingChunkBaseName` boots
    /// straight into it, `archiveReplacements` (keyed by bare filename,
    /// e.g. `"beach.rm2"`) carries this session's own real pending edits,
    /// computed the same way "Save Level Overrides…" already computes them.
    /// Assembled by `LevelViewerWindow` right before presenting
    /// `GameLauncherView`, not by `WorkspaceViewModel` itself — it has no
    /// visibility into a Level Viewer's live `renderer` state.
    public struct GameLauncherContext {
        public var summary: String
        public var startingChunkBaseName: String
        public var archiveReplacements: [String: Data]

        public init(summary: String, startingChunkBaseName: String, archiveReplacements: [String: Data]) {
            self.summary = summary
            self.startingChunkBaseName = startingChunkBaseName
            self.archiveReplacements = archiveReplacements
        }
    }

    /// "Direct Boot/Launch" — presents `GameLauncherView`. `gameLauncherContext`
    /// is set (to a real, non-nil chunk-launch plan) right before presenting
    /// for a contextual "Quick Launch" from the Level Viewer, and left `nil`
    /// for the global "Play in PCSX2…" toolbar entry — same nil-means-
    /// global-scope convention `typeFilter` already uses.
    @Published public var isGameLauncherPresented = false
    @Published public var gameLauncherContext: GameLauncherContext?

    private var archiveIndexByRootID: [UUID: ArchiveIndex] = [:]
    /// "No More Placeholder Squares": the real game's shared object
    /// resource (`Startup/Default.rm2` — confirmed against the actual
    /// archive, see `AssetResolver.resolveInstanceObject`'s doc comment),
    /// loaded once and reused for every subsequent Instance resolution in
    /// this workspace rather than re-parsed per level. `nil` until the
    /// first attempt; `didAttemptLoadingSharedDefaultAssetIndex` guards
    /// against retrying that parse on every single level open when it's
    /// genuinely unavailable (a loose-file workspace with no open archive).
    private var sharedDefaultAssetIndex: GraphicsAssetIndex?
    private var didAttemptLoadingSharedDefaultAssetIndex = false
    /// Raw file bytes for standalone-opened `.RM2`/`.SM2` files, keyed by
    /// their root `ChunkNode.id` — the "Editing GUI" write path's source
    /// material for patching an edited record back in at its known offset.
    /// Deliberately scoped to standalone files only (not archive-nested
    /// entries) for now; see `WorldPlacementWriter`'s doc comment.
    private var rawFileBytesByRootID: [UUID: Data] = [:]

    // MARK: - Recent Files (QoL sweep)

    private static let recentFilesDefaultsKey = "TwinsanityStudio.RecentFileURLs"
    private static let maxRecentFiles = 10

    /// Backs the app's "Open Recent" menu (see `CTStudioApp`'s `.commands`)
    /// — persisted to `UserDefaults` as bookmark-free path strings, most
    /// recent first, deduplicated by path.
    @Published public private(set) var recentFileURLs: [URL] = []

    private func loadRecentFiles() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentFilesDefaultsKey) ?? []
        recentFileURLs = paths.map { URL(fileURLWithPath: $0) }
    }

    private func addRecentFile(_ url: URL) {
        var urls = recentFileURLs.filter { $0.path != url.path }
        urls.insert(url, at: 0)
        recentFileURLs = Array(urls.prefix(Self.maxRecentFiles))
        UserDefaults.standard.set(recentFileURLs.map(\.path), forKey: Self.recentFilesDefaultsKey)
    }

    public func clearRecentFiles() {
        recentFileURLs = []
        UserDefaults.standard.removeObject(forKey: Self.recentFilesDefaultsKey)
    }

    public init() {
        loadRecentFiles()
        if UserDefaults.standard.object(forKey: Self.showRawFilesDefaultsKey) != nil {
            showRawFiles = UserDefaults.standard.bool(forKey: Self.showRawFilesDefaultsKey)
        }
        if let rawAccent = UserDefaults.standard.string(forKey: Self.accentColorDefaultsKey), let accent = AccentColorChoice(rawValue: rawAccent) {
            accentColorChoice = accent
        }
        if let path = UserDefaults.standard.string(forKey: Self.masterDirectoryDefaultsKey) {
            masterDirectoryURL = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: Self.discImageURLDefaultsKey) {
            discImageURL = URL(fileURLWithPath: path)
        }
        if let path = UserDefaults.standard.string(forKey: Self.pcsx2AppURLDefaultsKey) {
            pcsx2AppURL = URL(fileURLWithPath: path)
        }
    }

    // MARK: - Settings (Preferences window)

    /// "Theme/Appearance": an in-app control tint, applied via `.tint(...)`
    /// at `ContentView`'s root — this is a real, working native SwiftUI
    /// mechanism, not a claim about overriding macOS's own system-wide
    /// accent color (which no sandboxed or unsandboxed app can actually do;
    /// System Settings owns that).
    public enum AccentColorChoice: String, CaseIterable, Identifiable {
        case blue, purple, pink, red, orange, yellow, green, teal, indigo
        public var id: String { rawValue }
        public var color: Color {
            switch self {
            case .blue: return .blue
            case .purple: return .purple
            case .pink: return .pink
            case .red: return .red
            case .orange: return .orange
            case .yellow: return .yellow
            case .green: return .green
            case .teal: return .teal
            case .indigo: return .indigo
            }
        }
        public var displayName: String { rawValue.capitalized }
    }

    @Published public var accentColorChoice: AccentColorChoice = .blue {
        didSet { UserDefaults.standard.set(accentColorChoice.rawValue, forKey: Self.accentColorDefaultsKey) }
    }
    private static let accentColorDefaultsKey = "TwinsanityStudio.AccentColorChoice"

    /// "Directory Config": the folder Settings' "Choose…" picker points at
    /// — surfaced in the sidebar's empty state as a real "Open Master
    /// Directory" action (`SidebarView`), not just stored inertly.
    @Published public var masterDirectoryURL: URL? {
        didSet {
            if let masterDirectoryURL {
                UserDefaults.standard.set(masterDirectoryURL.path, forKey: Self.masterDirectoryDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.masterDirectoryDefaultsKey)
            }
        }
    }
    private static let masterDirectoryDefaultsKey = "TwinsanityStudio.MasterDirectoryURL"

    /// "Direct Boot/Launch": the real, bootable disc image `GameLauncher`
    /// patches and boots — a plain `.iso` only (see `ISO9660Writer`'s own
    /// doc comment on why `.bin`/`.cue` isn't supported for write-back).
    @Published public var discImageURL: URL? {
        didSet {
            if let discImageURL {
                UserDefaults.standard.set(discImageURL.path, forKey: Self.discImageURLDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.discImageURLDefaultsKey)
            }
        }
    }
    private static let discImageURLDefaultsKey = "TwinsanityStudio.DiscImageURL"

    /// The real PCSX2 app (or its bundled binary) `GameLauncher.launching`
    /// runs the built image with.
    @Published public var pcsx2AppURL: URL? {
        didSet {
            if let pcsx2AppURL {
                UserDefaults.standard.set(pcsx2AppURL.path, forKey: Self.pcsx2AppURLDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pcsx2AppURLDefaultsKey)
            }
        }
    }
    private static let pcsx2AppURLDefaultsKey = "TwinsanityStudio.PCSX2AppURL"

    /// "Multi-Region & Cross-Game Auto-Patcher" (roadmap 1.4): the real
    /// `SYSTEM.CNF` info detected the last time a folder was opened — `nil`
    /// until a folder open finds one, and never guessed from a filename or
    /// left over from a previous open on a different folder. See
    /// `detectRegion(inFolder:)`.
    @Published public private(set) var detectedRegion: SystemCNFInfo?

    /// Looks for a real `SYSTEM.CNF` at `folder`'s root (case-insensitively
    /// — real disc images vary in casing) and parses it if present.
    /// Deliberately not recursive: `SYSTEM.CNF` is only ever meaningful at
    /// an actual disc/ISO root, so searching subfolders would risk
    /// matching an unrelated file and reporting a wrong region with false
    /// confidence. `static`/non-isolated (unlike the rest of this
    /// `@MainActor` class) so `open(url:)` can run it inside a
    /// `Task.detached` alongside `WorkspaceAutoDetector.scanFolder` — same
    /// reasoning as that function's own doc comment about not blocking the
    /// main actor on folder-sized disk I/O.
    private nonisolated static func detectRegionSync(inFolder folder: URL) -> SystemCNFInfo? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        guard let cnfURL = entries.first(where: { $0.lastPathComponent.uppercased() == "SYSTEM.CNF" }) else { return nil }
        guard let contents = try? String(contentsOf: cnfURL, encoding: .ascii) else { return nil }
        return SystemCNFParser.parse(contents: contents)
    }

    /// The tree the sidebar actually renders: `rootNodes` narrowed by the
    /// type filter (see `ChunkNode.filtered(byKind:)`) and then by the
    /// search text (see `ChunkNode.filtered(matching:)`), each pass keeping
    /// ancestors of any match so the result stays a navigable tree.
    public var filteredRootNodes: [ChunkNode] {
        var nodes = rootNodes
        // "Smart File Filtering": applied first, as the baseline view —
        // undecoded/raw content (and folders that only contain it) is
        // hidden by default regardless of the type/search filters below,
        // not just when one happens to be active. Settings' Developer Mode
        // toggle (`showRawFiles`) brings it back.
        if !showRawFiles {
            nodes = nodes.compactMap { $0.prunedOfRawContent(discEntryRegistry: self.discEntryByNodeID) }
        }
        if let typeFilter {
            nodes = nodes.compactMap { $0.filtered(byKind: typeFilter) }
        }
        if !searchQuery.isEmpty {
            nodes = nodes.compactMap { $0.filtered(matching: searchQuery) }
        }
        return nodes
    }

    /// Whether any loaded archive still has `.RM2`/`.SM2`/etc. entries that
    /// haven't been parsed yet — drives the sidebar's "Scan Archive" prompt,
    /// since the type filter can only find assets inside files that have
    /// actually been decoded.
    public var hasUnscannedArchives: Bool {
        archiveIndexByRootID.keys.contains { rootID in
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { return false }
            return root.children.contains { isExpandableArchiveEntry($0) }
        }
    }

    // MARK: - Ingestion

    public func open(urls: [URL]) {
        for url in urls { open(url: url) }
    }

    public func open(url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            // The folder walk itself (`WorkspaceAutoDetector.scanFolder`'s
            // recursive `FileManager.enumerator` plus a `resourceValues`
            // call per entry, and `detectRegionSync`'s own directory
            // listing) is real, scale-with-folder-size disk I/O — the same
            // "instantly crashed"-looking freeze this function's own
            // pre-existing comment below already fixed for the *parsing*
            // half (loose level files). The scan half was still running
            // inline on the main actor; moved off it here for the same
            // reason, mirroring `loadLooseLevelFilesAsync`'s
            // `Task.detached` shape.
            isScanning = true
            statusMessage = "Scanning \(url.lastPathComponent)…"
            Task.detached(priority: .userInitiated) { [weak self] in
                let region = Self.detectRegionSync(inFolder: url)
                let detected = WorkspaceAutoDetector.scanFolder(url)
                await self?.applyFolderScanResults(url: url, region: region, detected: detected)
            }
            return
        }
        // "Modular TT Engine Cross-Compatibility" (roadmap 5.3): a file
        // extension a *different* registered `EngineDriver` recognizes
        // (today, just Wrath of Cortex's `.CRT`/`.WMP`) isn't "unknown" —
        // it's real, just not something the main sidebar tree/scan can
        // ingest directly (it's not chunk-headered, has no archive index,
        // nothing to build a `ChunkNode` tree from). Saying so explicitly,
        // with where to actually load it, beats `load(_:)`'s silent
        // `.unknown`/`.folder` no-op for a file this build genuinely does
        // understand.
        let detected = WorkspaceAutoDetector.detect(url: url)
        if detected.kind == .unknown, let driver = EngineDriverRegistry.driver(forExtension: url.pathExtension),
           case .standaloneOnly(let loadHint) = driver.ingestionCapability {
            statusMessage = "\(url.lastPathComponent) is a real \(driver.displayName) file, but this build doesn't load it into the main workspace tree — \(loadHint)"
            return
        }
        load(detected)
    }

    /// Applies the results of the off-main-actor folder scan `open(url:)`'s
    /// directory branch starts — the on-main-actor "finish up" half, same
    /// split `applyLooseLevelFileResults` uses for the loose-file parse
    /// results below.
    private func applyFolderScanResults(url: URL, region: SystemCNFInfo?, detected: [DetectedFile]) {
        isScanning = false
        detectedRegion = region
        statusMessage = "Found \(detected.count) recognizable file(s) in \(url.lastPathComponent)."
        if let detectedRegion, detectedRegion.region != .unknown {
            statusMessage += " Detected region: \(detectedRegion.region.displayName)\(detectedRegion.serial.map { " (\($0))" } ?? "")."
        }
        // "Fatal Crash on File Selection": `.archiveIndex`/`.archiveData`
        // are cheap (a header + entry-name list, not a full parse) and
        // stay on `load(_:)`'s existing synchronous path, matching
        // single-file open. `.levelResource`/`.sceneryResource` loose
        // files are each a *full* parse — potentially many of them for
        // a folder pick (an extracted mod folder, a whole disc root),
        // and running that in a plain `for` loop on the main actor
        // blocked the UI for however long all of them took combined,
        // with zero opportunity for AppKit to service events in
        // between. On this machine that's easily long enough to look
        // and feel exactly like "the app instantly crashed" even
        // though every individual parse was already safely wrapped in
        // `load(_:)`'s own `do`/`catch` — the freeze was real, not a
        // Swift-level crash, but indistinguishable from one to a user
        // watching a spinning beachball. Routed through the same
        // off-main-actor `TaskGroup` shape `scanAllArchives()` already
        // uses for exactly this reason.
        let looseLevelFiles = detected.filter { $0.kind == .levelResource || $0.kind == .sceneryResource }
        let remaining = detected.filter { $0.kind != .levelResource && $0.kind != .sceneryResource }
        for file in remaining { load(file) }
        if !looseLevelFiles.isEmpty { loadLooseLevelFilesAsync(looseLevelFiles) }
    }

    /// One parsed loose `.RM2`/`.SM2` file's full result — everything
    /// `load(_:)`'s `.levelResource`/`.sceneryResource` case already
    /// computes for a single such file, bundled so a `TaskGroup` child task
    /// can hand it back in one `Sendable` value. `nil` `node`/`data` means
    /// this file failed to parse (see `error`) — still reported, never
    /// silently dropped.
    private struct LooseLevelFileResult: Sendable {
        let file: DetectedFile
        let node: ChunkNode?
        let data: Data?
        let models: [ResolvedModelAsset]
        let orphans: [OrphanedAsset]
        let textures: [TextureHubEntry]
        let levels: [LevelHubEntry]
        let error: String?
    }

    /// Parses every loose level/scenery file found by a folder scan off the
    /// main actor, fanned out across cores (same shape as
    /// `scanAllArchives`'s `TaskGroup`), then applies every result — parsed
    /// or failed — back on the main actor in one batch. A single
    /// malformed/truncated/unrelated file (a real risk when the user picks
    /// a broad folder rather than a curated one) fails on its own and
    /// reports through `lastError` alongside whatever else did load;
    /// it never aborts the rest of the batch.
    /// Single-file counterpart to `loadLooseLevelFilesAsync` — same real
    /// off-main-actor read+parse, same `LooseLevelFileResult`/
    /// `applyLooseLevelFileResults` application, just for the one file a
    /// direct `open(url:)` (not a folder scan) hands `load(_:)`. Before
    /// this, a directly-opened `.RM2`/`.SM2` was the one `.levelResource`/
    /// `.sceneryResource` path never routed through the async fix — see
    /// `load(_:)`'s own doc comment at its call site.
    /// "MonkeyBall (MB) File-Kind Detection" — there's no reliable magic
    /// byte distinguishing a Super Monkey Ball Adventure `.RM2`/`.SM2` from
    /// a retail Crash Twinsanity one (both are the same underlying "nu2"
    /// engine container format); this is the closest real equivalent to
    /// automatic detection this project's reference material supports: an
    /// explicit "open as Monkey Ball" entry point, same posture
    /// `ExecutablePatcherView`'s manual `GameExecutableRevision` picker
    /// already takes for a build variant with no reliable auto-probe. Once
    /// routed through `.rm2MB`/`.sm2MB`, every previously-unreachable
    /// `SectionType.*MB` case (`RM2Parser.tier0Kind`/`tier1ChildType`) is
    /// real and taggable in the tree, not dead code.
    public func openAsMonkeyBall(url: URL) {
        let ext = url.pathExtension.uppercased()
        let fileKind: TwinsFileKind
        switch ext {
        case "RM2": fileKind = .rm2MB
        case "SM2": fileKind = .sm2MB
        default:
            lastError = "\(url.lastPathComponent): Monkey Ball opening only applies to .RM2/.SM2 files."
            return
        }
        isLoading = true
        statusMessage = "Loading \(url.lastPathComponent) as Monkey Ball…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let node = try Self.mainTreeDriver(forExtension: url.pathExtension).parseChunkFile(data: data, fileKind: fileKind, fileName: url.lastPathComponent)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rawFileBytesByRootID[node.id] = data
                    self.rootNodes.append(node)
                    self.isLoading = false
                    self.statusMessage = "Loaded \(url.lastPathComponent) as Monkey Ball."
                    self.addRecentFile(url)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                    self?.lastError = "\(url.lastPathComponent): \(error)"
                }
            }
        }
    }

    private func loadSingleLevelFileAsync(_ file: DetectedFile) {
        isLoading = true
        statusMessage = "Loading \(file.url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: LooseLevelFileResult
            do {
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                let node = try Self.mainTreeDriver(forExtension: file.url.pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(for: file), fileName: file.url.lastPathComponent)
                let label = file.url.lastPathComponent
                result = LooseLevelFileResult(
                    file: file, node: node, data: data,
                    models: Self.resolveModels(inFileRoot: node, sourceLabel: label),
                    orphans: AssetResolver.scanForOrphans(fileRoot: node, sourceLabel: label),
                    textures: Self.collectTextures(inFileRoot: node, sourceLabel: label),
                    levels: Self.collectLevels(inFileRoot: node, sourceLabel: label),
                    error: nil
                )
            } catch {
                result = LooseLevelFileResult(file: file, node: nil, data: nil, models: [], orphans: [], textures: [], levels: [], error: "\(error)")
            }
            await self?.applyLooseLevelFileResults([result])
        }
    }

    private func loadLooseLevelFilesAsync(_ files: [DetectedFile]) {
        isLoading = true
        statusMessage = "Parsing \(files.count) level file(s)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = await withTaskGroup(of: LooseLevelFileResult.self) { group in
                for file in files {
                    group.addTask {
                        do {
                            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                            let node = try Self.mainTreeDriver(forExtension: file.url.pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(for: file), fileName: file.url.lastPathComponent)
                            let label = file.url.lastPathComponent
                            return LooseLevelFileResult(
                                file: file, node: node, data: data,
                                models: Self.resolveModels(inFileRoot: node, sourceLabel: label),
                                orphans: AssetResolver.scanForOrphans(fileRoot: node, sourceLabel: label),
                                textures: Self.collectTextures(inFileRoot: node, sourceLabel: label),
                                levels: Self.collectLevels(inFileRoot: node, sourceLabel: label),
                                error: nil
                            )
                        } catch {
                            return LooseLevelFileResult(file: file, node: nil, data: nil, models: [], orphans: [], textures: [], levels: [], error: "\(error)")
                        }
                    }
                }
                var collected: [LooseLevelFileResult] = []
                collected.reserveCapacity(files.count)
                for await result in group { collected.append(result) }
                return collected
            }
            await self?.applyLooseLevelFileResults(results)
        }
    }

    private func applyLooseLevelFileResults(_ results: [LooseLevelFileResult]) {
        defer { isLoading = false }
        var loadedCount = 0
        var failedNames: [String] = []
        for result in results {
            guard let node = result.node, let data = result.data else {
                failedNames.append(result.file.url.lastPathComponent)
                lastError = "\(result.file.url.lastPathComponent): \(result.error ?? "unknown error")"
                continue
            }
            rawFileBytesByRootID[node.id] = data
            rootNodes.append(node)
            modelsHub.append(contentsOf: result.models)
            orphanedContent.append(contentsOf: result.orphans)
            texturesHub.append(contentsOf: result.textures)
            levelsHub.append(contentsOf: result.levels)
            addRecentFile(result.file.url)
            loadedCount += 1
        }
        statusMessage = failedNames.isEmpty
            ? "Parsed \(loadedCount) level file(s)."
            : "Parsed \(loadedCount) level file(s), \(failedNames.count) failed (see errors above)."
    }

    /// "Audio Bank Extractor & Player" (roadmap 2.4): resolves `mhURL`'s
    /// sibling `.MB` file (same directory, same base name, case-
    /// insensitive extension — real discs use `.MH`/`.MB` uppercase),
    /// reads and decodes the whole bank off the main actor, then applies
    /// the result. `mbData` is read with `.mappedIfSafe` for the same
    /// reason `.levelResource`/`.sceneryResource` already do — `MUSIC.MB`
    /// alone is over 200MB on the real disc.
    private func loadSoundBankAsync(mhURL: URL) {
        let directory = mhURL.deletingLastPathComponent()
        let baseName = mhURL.deletingPathExtension().lastPathComponent
        guard let mbURL = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .first(where: { $0.deletingPathExtension().lastPathComponent == baseName && $0.pathExtension.caseInsensitiveCompare("MB") == .orderedSame })
        else {
            lastError = "\(mhURL.lastPathComponent): no matching .MB file found in the same folder."
            return
        }

        isLoadingSoundBank = true
        statusMessage = "Parsing sound bank \(baseName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<SoundBankAsset, Error>
            do {
                let mhData = try Data(contentsOf: mhURL)
                let mbData = try Data(contentsOf: mbURL, options: .mappedIfSafe)
                let bank = try SoundBankParser.parse(mhData: mhData, mbData: mbData, sourceLabel: baseName)
                result = .success(bank)
            } catch {
                result = .failure(error)
            }
            await self?.applySoundBankResult(result, baseName: baseName)
        }
    }

    private func applySoundBankResult(_ result: Result<SoundBankAsset, Error>, baseName: String) {
        isLoadingSoundBank = false
        switch result {
        case .success(let bank):
            soundBanks.append(bank)
            statusMessage = "Loaded sound bank \(baseName) — \(bank.entries.count) entries, \(bank.decodedCount) decoded."
        case .failure(let error):
            lastError = "\(baseName): \(error)"
        }
    }

    private func load(_ file: DetectedFile) {
        // "Visual Loading Feedback": a single directly-opened .RM2/.SM2 can
        // be a full level's worth of chunk data, same as one entry out of
        // a folder scan — that path was already fixed to parse off the
        // main actor (see `loadLooseLevelFilesAsync`'s own doc comment for
        // exactly why blocking here reads as "the app crashed," not just
        // "looks busy"). Single-file open never went through that fix
        // since it calls `load(_:)` directly instead of the folder path,
        // so route these two kinds through the same real async machinery
        // here too, before the synchronous branch below even starts.
        if file.kind == .levelResource || file.kind == .sceneryResource {
            loadSingleLevelFileAsync(file)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            switch file.kind {
            case .archiveIndex:
                let index = try Self.mainTreeDriver(forExtension: file.url.pathExtension).parseArchiveIndex(bhURL: file.url)
                let node = ChunkNode(
                    recordID: 0, sectionType: .null,
                    displayName: "\(file.url.lastPathComponent)  (\(index.entries.count) files)",
                    byteSize: 0, fileOffset: 0
                )
                for entry in index.entries {
                    node.children.append(ChunkNode(
                        recordID: 0, sectionType: .null, displayName: entry.name,
                        byteSize: Int(entry.size), fileOffset: Int(entry.offset)
                    ))
                }
                archiveIndexByRootID[node.id] = index
                rootNodes.append(node)

                if let cached = ScanCache.load(for: index.bdURL) {
                    modelsHub.append(contentsOf: cached.modelsHub)
                    orphanedContent.append(contentsOf: cached.orphanedContent)
                    texturesHub.append(contentsOf: cached.texturesHub)
                    statusMessage = "Loaded \(file.url.lastPathComponent) from cache — \(cached.modelsHub.count) model(s), \(cached.texturesHub.count) texture(s) available instantly. Individual files still parse on selection; Scan Archive refreshes the cache."
                } else {
                    statusMessage = "Loaded \(file.url.lastPathComponent) — \(index.entries.count) entries. Scanning for models…"
                    // Auto-scan immediately — manual "Scan Archive" clicks
                    // shouldn't be a prerequisite for browsing/filtering to work.
                    scanAllArchives()
                }
                addRecentFile(file.url)

            case .levelResource, .sceneryResource:
                // Unreachable — handled by the early `loadSingleLevelFileAsync`
                // return above, kept as an explicit case (not `default:`)
                // so a future new `DetectedFile.Kind` case fails to compile
                // here until it's deliberately handled one way or the other.
                break

            case .archiveData:
                statusMessage = "Drop the matching .BH file to browse \(file.url.lastPathComponent) (a .BD alone has no index)."

            case .soundBank:
                // Real `.MB` payloads run well over 200MB (`MUSIC.MB`) —
                // `load(_:)` itself stays synchronous/non-blocking by just
                // scheduling the actual read+decode, matching this view
                // model's standing rule against blocking the main actor on
                // a heavy parse.
                loadSoundBankAsync(mhURL: file.url)

            case .ptcSheet:
                let baseName = file.url.deletingPathExtension().lastPathComponent
                let data = try Data(contentsOf: file.url)
                switch file.url.pathExtension.uppercased() {
                case "PTC":
                    let entry = try TwinsPTCParser.parsePTCFile(data)
                    ptcSheets.append(TwinsPSMAsset(sourceLabel: baseName, entries: [entry]))
                    statusMessage = "Loaded \(file.url.lastPathComponent) — 1 entry."
                case "PSM":
                    let sheet = try TwinsPTCParser.parsePSM(data, sourceLabel: baseName)
                    ptcSheets.append(sheet)
                    statusMessage = "Loaded \(file.url.lastPathComponent) — \(sheet.entries.count) entries."
                case "PSF":
                    let font = try TwinsPTCParser.parsePSF(data, sourceLabel: baseName)
                    fontSheets.append(font)
                    statusMessage = "Loaded \(file.url.lastPathComponent) — \(font.fontPages.count) font page(s), \(font.vectors.count) vector(s)."
                default:
                    break
                }

            case .folder, .unknown:
                break
            }
        } catch {
            lastError = "\(file.url.lastPathComponent): \(error)"
        }
    }

    private nonisolated static func fileKind(for file: DetectedFile) -> TwinsFileKind {
        switch (file.kind, file.platform) {
        case (.levelResource, .xbox): return .rmx
        case (.levelResource, _): return .rm2
        case (.sceneryResource, .xbox): return .smx
        case (.sceneryResource, _): return .sm2
        default: return .rm2
        }
    }

    /// "Modular Driver Dispatch" (roadmap 5.3): the one real place chunk-
    /// file/archive parsing dispatches through `EngineDriver` instead of
    /// calling `RM2Parser`/`BDArchiveParser` directly — every call site
    /// below routes through this, so a real second `.mainWorkspaceTree`
    /// driver (should one ever exist) only needs its own `EngineDriver`
    /// conformance, not changes at every parse call site. Falls back to
    /// `TwinsanityEngineDriver` directly only as a defensive default —
    /// every extension this is ever called with (RM2/SM2/RMX/SMX/BH) is
    /// already hardcoded into that driver's own `recognizedExtensions`,
    /// so the fallback is unreachable in practice, not a silent behavior
    /// change from before this refactor.
    private nonisolated static func mainTreeDriver(forExtension ext: String) -> any EngineDriver {
        EngineDriverRegistry.driver(forExtension: ext) ?? TwinsanityEngineDriver()
    }

    // MARK: - Drilling into archived RM2/SM2 files

    /// Whether `node` is an unexpanded archive entry whose name looks like a
    /// chunk file (`.RM2`/`.SM2`/`.RMX`/`.SMX`).
    public func isExpandableArchiveEntry(_ node: ChunkNode) -> Bool {
        guard node.children.isEmpty, node.payload == nil else { return false }
        return Self.isChunkFileName(node.displayName)
    }

    /// `nonisolated`: pure string logic with no dependency on view-model
    /// state, called from `scanAllArchives`'s background parsing loop —
    /// without this it inherits `@MainActor` isolation from the enclosing
    /// type and can't be called off the main thread without a warning.
    private nonisolated static func isChunkFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.uppercased()
        return ["RM2", "SM2", "RMX", "SMX"].contains(ext)
    }

    private nonisolated static func fileKind(forEntryNamed name: String) -> TwinsFileKind {
        switch (name as NSString).pathExtension.uppercased() {
        case "RMX": return .rmx
        case "SMX": return .smx
        case "SM2": return .sm2
        default: return .rm2
        }
    }

    /// Parses every unparsed `.RM2`/`.SM2`/etc. entry across every loaded
    /// archive in the background, so the type filter (and search) can find
    /// assets no matter which file they're packed into — without this, a
    /// filter can only ever see inside files you've individually opened.
    /// Runs off the main actor since a full archive (hundreds of files) can
    /// take tens of seconds; the UI stays responsive and `isScanning` drives
    /// a progress indicator instead of freezing during the scan.
    ///
    /// Bounded, sliding-window concurrency: at most `maxConcurrent` entries'
    /// raw bytes + parse products are ever resident at once, refilled one at
    /// a time as each finishes — not "read every candidate entry's bytes for
    /// the whole archive into RAM up front, then parse," which is real
    /// memory-spike risk on a large archive (hundreds of multi-MB level
    /// files all held in memory simultaneously before a single one starts
    /// parsing). `BDArchiveReader` reuses one open file handle and isn't
    /// safe for concurrent reads from a single instance (see its own doc
    /// comment) — worked around here by giving each concurrent task its own
    /// reader (an independent `FileHandle` over the same read-only `.BD`
    /// file) rather than serializing all reads through one shared instance.
    public func scanAllArchives() {
        guard !isScanning else { return }
        let targets = archiveIndexByRootID.map { ($0.key, $0.value) }
        guard !targets.isEmpty else { return }

        let totalCandidates = targets.reduce(0) { partial, pair in
            partial + pair.1.entries.filter { Self.isChunkFileName($0.name) }.count
        }
        guard totalCandidates > 0 else { return }

        isScanning = true
        scanProgress = (0, totalCandidates)
        statusMessage = "Scanning \(totalCandidates) level file(s) across \(targets.count) archive(s)…"

        // Extra concurrency past the core count doesn't speed up CPU-bound
        // parsing, it just means more entries' raw bytes + parse products
        // resident in memory at once — capped here, floor 2 so a
        // single-core-visible sandbox still parallelizes I/O against CPU
        // work, ceiling 8 so a many-core machine doesn't hold dozens of
        // large level files in memory simultaneously for no benefit.
        let maxConcurrent = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            var resultsByRoot: [UUID: [String: ChunkNode]] = [:]
            var resolvedModels: [ResolvedModelAsset] = []
            var orphans: [OrphanedAsset] = []
            var textures: [TextureHubEntry] = []
            var levels: [LevelHubEntry] = []
            var completedCount = 0

            for (rootID, index) in targets {
                guard !Task.isCancelled else { break }
                let chunkEntries = index.entries.filter { Self.isChunkFileName($0.name) }

                let parsed = await withTaskGroup(of: ParsedEntryResult?.self) { group -> [ParsedEntryResult] in
                    var collected: [ParsedEntryResult] = []
                    collected.reserveCapacity(chunkEntries.count)
                    var iterator = chunkEntries.makeIterator()

                    // Sliding window: never more than `maxConcurrent` tasks
                    // in flight — each holding just its own entry's raw
                    // bytes, not the whole archive's.
                    func addNext() {
                        guard let entry = iterator.next() else { return }
                        group.addTask {
                            // Own reader per task (see this function's own
                            // doc comment on BDArchiveReader thread-safety)
                            // — opened fresh per entry rather than reused,
                            // since tasks in this group run concurrently
                            // and complete in any order.
                            guard let reader = try? BDArchiveReader(index: index),
                                  let data = try? reader.read(entry)
                            else { return nil }
                            let kind = Self.fileKind(forEntryNamed: entry.name)
                            guard let node = try? Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: kind, fileName: entry.name) else { return nil }
                            let models = Self.resolveModels(inFileRoot: node, sourceLabel: entry.name)
                            let entryOrphans = AssetResolver.scanForOrphans(fileRoot: node, sourceLabel: entry.name)
                            let entryTextures = Self.collectTextures(inFileRoot: node, sourceLabel: entry.name)
                            let entryLevels = Self.collectLevels(inFileRoot: node, sourceLabel: entry.name)
                            return ParsedEntryResult(name: entry.name, node: node, models: models, orphans: entryOrphans, textures: entryTextures, levels: entryLevels)
                        }
                    }

                    for _ in 0..<maxConcurrent { addNext() }
                    while let result = await group.next() {
                        completedCount += 1
                        // Throttled: a MainActor hop per file would add
                        // real overhead for a scan of thousands of files —
                        // every 5th completion (plus always the very last
                        // one) keeps the progress text moving visibly
                        // without paying that cost per file.
                        if completedCount.isMultiple(of: 5) || completedCount == totalCandidates {
                            let progress = (completedCount, totalCandidates)
                            await MainActor.run { [weak self] in self?.scanProgress = progress }
                        }
                        if let result { collected.append(result) }
                        addNext()
                    }
                    return collected
                }

                var parsedByName: [String: ChunkNode] = [:]
                var modelsForThisArchive: [ResolvedModelAsset] = []
                var orphansForThisArchive: [OrphanedAsset] = []
                var texturesForThisArchive: [TextureHubEntry] = []
                var levelsForThisArchive: [LevelHubEntry] = []
                for result in parsed {
                    parsedByName[result.name] = result.node
                    modelsForThisArchive.append(contentsOf: result.models)
                    orphansForThisArchive.append(contentsOf: result.orphans)
                    texturesForThisArchive.append(contentsOf: result.textures)
                    levelsForThisArchive.append(contentsOf: result.levels)
                }
                resultsByRoot[rootID] = parsedByName
                resolvedModels.append(contentsOf: modelsForThisArchive)
                orphans.append(contentsOf: orphansForThisArchive)
                textures.append(contentsOf: texturesForThisArchive)
                levels.append(contentsOf: levelsForThisArchive)
                // Cached per archive, right after its own scan finishes,
                // rather than waiting for every archive in this batch —
                // pure file I/O over already-`Sendable` value types, safe
                // to do straight from this background task.
                ScanCache.save(ScanCachePayload(modelsHub: modelsForThisArchive, orphanedContent: orphansForThisArchive, texturesHub: texturesForThisArchive), for: index.bdURL)
            }

            let wasCancelled = Task.isCancelled
            await self?.applyBulkScan(resultsByRoot, resolvedModels: resolvedModels, orphans: orphans, textures: textures, levels: levels, wasCancelled: wasCancelled)
        }
    }

    /// One archive entry's parsed chunk tree plus everything derived from
    /// it — grouped so a single `TaskGroup` child task can hand its whole
    /// result back in one `Sendable` value.
    private struct ParsedEntryResult: Sendable {
        let name: String
        let node: ChunkNode
        let models: [ResolvedModelAsset]
        let orphans: [OrphanedAsset]
        let textures: [TextureHubEntry]
        let levels: [LevelHubEntry]
    }

    private func applyBulkScan(_ resultsByRoot: [UUID: [String: ChunkNode]], resolvedModels: [ResolvedModelAsset], orphans: [OrphanedAsset], textures: [TextureHubEntry], levels: [LevelHubEntry], wasCancelled: Bool = false) {
        defer { isScanning = false; scanProgress = nil }
        var parsedCount = 0
        var failedCount = 0
        for (rootID, parsedByName) in resultsByRoot {
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { continue }
            root.children = root.children.map { child -> ChunkNode in
                guard isExpandableArchiveEntry(child) else { return child }
                guard let parsed = parsedByName[child.displayName] else {
                    failedCount += 1
                    return child
                }
                parsedCount += 1
                return ChunkNode(
                    recordID: child.recordID,
                    sectionType: parsed.sectionType,
                    displayName: child.displayName,
                    byteSize: child.byteSize,
                    fileOffset: child.fileOffset,
                    children: parsed.children,
                    payload: parsed.payload
                )
            }
        }
        rootNodes = rootNodes
        modelsHub.append(contentsOf: resolvedModels)
        orphanedContent.append(contentsOf: orphans)
        texturesHub.append(contentsOf: textures)
        levelsHub.append(contentsOf: levels)
        let prefix = wasCancelled ? "Scan cancelled" : "Scan complete"
        statusMessage = failedCount == 0
            ? "\(prefix) — parsed \(parsedCount) level file(s), found \(resolvedModels.count) model(s) and \(orphans.count) orphaned/cut record(s)."
            : "\(prefix) — parsed \(parsedCount) level file(s), \(failedCount) failed to parse, found \(resolvedModels.count) model(s) and \(orphans.count) orphaned/cut record(s)."
    }

    /// Resolves every `RigidModel` and every rigged `GraphicsInfo` skeleton
    /// in one already-parsed file into `ResolvedModelAsset`s for the Models
    /// Hub. `nonisolated`: pure computation over value types and a
    /// `ChunkNode` tree that hasn't been published anywhere yet, so it's
    /// safe to run off the main actor (called from `scanAllArchives`'s
    /// background loop).
    private nonisolated static func resolveModels(inFileRoot fileRoot: ChunkNode, sourceLabel: String) -> [ResolvedModelAsset] {
        let index = AssetResolver.buildIndex(fileRoot: fileRoot)
        var results: [ResolvedModelAsset] = []
        for rigidModel in index.rigidModels.values {
            if let resolved = AssetResolver.resolveRigidModel(rigidModel, displayName: "\(sourceLabel) — Object #\(rigidModel.id)", index: index) {
                results.append(resolved)
            }
        }
        for skeleton in index.skeletons.values {
            if let resolved = AssetResolver.resolveSkeleton(skeleton, displayName: "\(sourceLabel) — Character #\(skeleton.id)", index: index) {
                results.append(resolved)
            }
        }
        return results
    }

    /// "Textures Hub" (QoL sweep) — every decoded texture in one already-
    /// parsed file, mirroring `resolveModels`' pattern exactly (same
    /// `nonisolated`/background-scan-safe shape, same per-file population
    /// point in both `load(_:)` and `scanAllArchives`).
    private nonisolated static func collectTextures(inFileRoot fileRoot: ChunkNode, sourceLabel: String) -> [TextureHubEntry] {
        AssetResolver.buildIndex(fileRoot: fileRoot).textures.values.map {
            TextureHubEntry(sourceLabel: sourceLabel, texture: $0)
        }
    }

    /// "Visual Levels Hub": every decoded `SceneryData` record with a
    /// non-empty placement tree in one already-parsed file — same shape as
    /// `collectTextures`, but a direct tree walk rather than an
    /// `AssetResolver.buildIndex` lookup, since `SceneryData` lives under a
    /// file's `Code`/level-data sections that index doesn't cover (it's
    /// scoped to `Graphics`/skeleton/animation lookups only). Skips scenery
    /// records with zero placements — an empty/degenerate tree isn't a
    /// level worth a gallery card.
    private nonisolated static func collectLevels(inFileRoot fileRoot: ChunkNode, sourceLabel: String) -> [LevelHubEntry] {
        var results: [LevelHubEntry] = []
        func walk(_ node: ChunkNode) {
            if case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                results.append(LevelHubEntry(sourceLabel: sourceLabel, scenery: scenery, node: node))
            }
            for child in node.children { walk(child) }
        }
        walk(fileRoot)
        return results
    }

    /// Every `Instance` record (placed entity — crate, enemy, platform, …)
    /// in the same file `levelNode` came from, paired with its `ChunkNode`
    /// so an edited transform can be patched straight back to this exact
    /// record's byte offset. Used by the Level Viewer to draw placeholder
    /// markers for objects this build has no verified mesh mapping for (see
    /// `LevelViewerContext.instanceMarkers`'s doc comment) — a live tree
    /// walk, not cached, since it's only ever called once per "Open Level
    /// Viewer" click.
    public func instanceRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, instance: PlacedInstance)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .instance(let placed) = payload { return placed }
            return nil
        }.map { (node: $0.node, instance: $0.value) }
    }

    /// "Level Editor Overhaul": every `Trigger` record in the same file —
    /// same shape as `instanceRecords`, feeding the "Trigger Volumes & Death
    /// Planes" scene layer and the Level Events panel.
    public func triggerRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, trigger: TriggerVolume)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .trigger(let trigger) = payload { return trigger }
            return nil
        }.map { (node: $0.node, trigger: $0.value) }
    }

    /// Every `Camera` record in the same file — feeds the "Camera Splines"
    /// scene layer.
    public func cameraRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, camera: PlacedCamera)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .camera(let camera) = payload { return camera }
            return nil
        }.map { (node: $0.node, camera: $0.value) }
    }

    /// "Collision / Ground Floor": every real `ColData` collision mesh in
    /// the same file — the level's actual walkable ground, decoded as real
    /// triangle geometry (see `CollisionMesh`'s own doc comment), but
    /// never previously rendered anywhere in the Level Viewer. `ColData`
    /// only lives in `.RM2` actor files (confirmed against the reference
    /// tool: `SMViewer.cs` has no `ColData` handling at all), so calling
    /// this for a scenery-only `.sm2` node returns an empty list — same
    /// "always call on both node and siblingNode, use whichever file
    /// actually has it" pattern `openLevelViewer` already uses for
    /// instances/triggers/cameras.
    public func collisionMeshRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, mesh: CollisionMesh)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .collision(let mesh) = payload { return mesh }
            return nil
        }.map { (node: $0.node, mesh: $0.value) }
    }

    /// Every decoded `SoundEffect` record in the same file — feeds the
    /// Level Audio panel. Deliberately presented as exactly that ("sound
    /// effects in this file"), not "BGM"/"ambient bank": `SoundEffectAsset`
    /// carries no category field distinguishing those, and this format
    /// doesn't record which chunk a level's music/ambience actually comes
    /// from, so claiming that distinction would be inventing data this
    /// build doesn't have.
    public func soundEffectRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, sound: SoundEffectAsset)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .soundEffect(let sound) = payload { return sound }
            return nil
        }.map { (node: $0.node, sound: $0.value) }
    }

    /// "Chunk-Based Architecture" (Part 2): every real `ChunkLink` entry
    /// (flattened out of every `ChunkLinks` record — a `.SM2` chunk has at
    /// most one, but this stays list-shaped like its siblings above) in the
    /// same file as `levelNode`. `ChunkLinks` sits at the same tier-0 level
    /// as `SceneryData`/`Graphics` (see `RM2Parser.tier0Kind`), so it's
    /// already reachable via the same `findFileRoot`-rooted walk
    /// `recordsInSameFile` does for Instance/Trigger/Camera/SoundEffect —
    /// no separate tree-walk entry point needed.
    public func chunkLinkRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, link: ChunkLink)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .chunkLinks(let asset) = payload { return asset }
            return nil
        }.flatMap { entry in entry.value.links.map { (node: entry.node, link: $0) } }
    }

    /// "AI Pathfinding/Navmesh Editor" (roadmap 5.1): every real
    /// `AIPosition` waypoint in the same file — feeds the Level Viewer's
    /// "AI Waypoints" scene layer.
    public func aiPositionRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, marker: AIPositionMarker)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .aiPosition(let marker) = payload { return marker }
            return nil
        }.map { (node: $0.node, marker: $0.value) }
    }

    /// Every real `AIPath` record in the same file — no spatial position of
    /// its own (see `AIPathRecord`'s doc comment), so this feeds a factual
    /// list panel only, not a scene layer.
    public func aiPathRecords(inSameFileAs levelNode: ChunkNode) -> [(node: ChunkNode, path: AIPathRecord)] {
        recordsInSameFile(as: levelNode) { payload in
            if case .aiPath(let path) = payload { return path }
            return nil
        }.map { (node: $0.node, path: $0.value) }
    }

    /// Shared tree walk behind `instanceRecords`/`triggerRecords`/
    /// `cameraRecords`/`soundEffectRecords`: every node in the same file as
    /// `levelNode` whose payload `extract` recognizes, paired with that
    /// node. A live walk, not cached — each of these is only ever called
    /// once per "Open Level Viewer" click.
    private func recordsInSameFile<T>(as levelNode: ChunkNode, extract: (ChunkPayload?) -> T?) -> [(node: ChunkNode, value: T)] {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return [] }
        var results: [(node: ChunkNode, value: T)] = []
        func walk(_ node: ChunkNode) {
            if let value = extract(node.payload) {
                results.append((node, value))
            }
            for child in node.children { walk(child) }
        }
        walk(fileRoot)
        return results
    }

    /// Sets the selection and, if the node is an unparsed archive entry,
    /// parses it in the same step. Selecting a `.RM2`/`.SM2` entry is the
    /// obvious, discoverable action — requiring a separate small "Parse"
    /// button click first (nothing else in the sidebar works that way) reads
    /// as "this file won't open" rather than "click this other thing first."
    ///
    /// The actual parse-and-mutate work is dispatched to the next run loop
    /// tick rather than done inline: `select` is called from `List`'s
    /// selection `Binding.set`, which SwiftUI invokes *during* its own view
    /// update pass — mutating `@Published` state synchronously in there logs
    /// "Publishing changes from within view updates is not allowed" and
    /// produces genuinely undefined rendering (rows not updating, disclosure
    /// state going stale), not just a console warning to ignore.
    public func select(_ node: ChunkNode?) {
        // `selectedNode = node` is a `@Published` mutation, and `select` is
        // called from `List`'s selection `Binding.set`, which SwiftUI
        // invokes *during* its own view update pass — mutating `@Published`
        // state synchronously in there logs "Publishing changes from
        // within view updates is not allowed" and produces genuinely
        // undefined behavior (not just a console warning), matching
        // exactly what was observed clicking around the sidebar. The whole
        // body — not just the archive-expansion half that was already
        // deferred — has to move to the next run loop tick.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedNode = node
            guard let node else { return }

            // One real, unopened clip inside an already-extracted WoC
            // sound archive (see `expandWOCSoundArchive`) — decode just
            // this one clip and swap its payload in, rather than the
            // whole-file "extract and open" path below (there's no
            // separate file to extract; the archive was already pulled
            // once when its own node was clicked).
            if let pending = self.wocSoundClipPending[node.id] {
                self.wocSoundClipPending.removeValue(forKey: node.id)
                Task { [weak self] in
                    await self?.decodeWOCSoundClip(node, archiveURL: pending.archiveURL, entry: pending.entry)
                }
                return
            }

            // A disc-mounted file leaf (see `mountDiscImage`) — extract and
            // open it the same one-click way an archive entry expands,
            // rather than requiring a second explicit action. Checked
            // before the archive-expand path since a disc leaf can
            // structurally satisfy `isExpandableArchiveEntry` too (empty
            // children, nil payload, a recognized extension) without
            // actually being one.
            if let holder = self.discEntryByNodeID[node.id],
               let entry = holder.entry as? ISO9660Entry,
               let source = holder.source as? any LogicalSectorSource {
                // WoC's own real, decoded formats (see `WOCLevelLoader`/
                // `WOCSoundParser`) — routed to their own expansion instead
                // of `openDiscEntry`'s generic "extract, then run through
                // the Twinsanity-only `open(url:)` pipeline" path, which
                // doesn't understand any WoC extension and would just fail
                // silently. `.GSC` gets the full per-level tree (objects,
                // textures, AI, foliage, animations, paths, terrain);
                // `SFX.DAT`/`ATS.DAT` get their real per-clip table.
                let ext = (entry.name as NSString).pathExtension.uppercased()
                if ext == "GSC" {
                    Task { [weak self] in await self?.expandWOCLevelEntry(node, entry: entry, source: source) }
                    return
                }
                let upperName = entry.name.uppercased()
                if upperName == "SFX.DAT" || upperName == "ATS.DAT" {
                    Task { [weak self] in await self?.expandWOCSoundArchive(node, entry: entry, source: source) }
                    return
                }
                self.openDiscEntry(entry, source: source, node: node)
                return
            }

            guard self.isExpandableArchiveEntry(node) else { return }
            guard let rootID = self.owningArchiveRootID(of: node) else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.expandArchiveEntry(node, rootID: rootID)
                // "Frictionless Chunk Loading": a chunk file selected straight
                // from the sidebar goes to the same place clicking its Chunk
                // Hub card does — no separate hub lookup required. Only fires
                // right after *this* expand (the node this file's root just
                // became), not on every later re-select of an already-parsed
                // file, so re-clicking a node inside an open chunk to inspect
                // one record doesn't keep yanking focus back into the 3D
                // viewer window.
                guard let expanded = self.selectedNode, expanded !== node,
                      let sceneryNode = Self.firstSceneryNode(in: expanded),
                      case .scenery(let asset) = sceneryNode.payload
                else { return }
                await self.openLevelViewer(for: asset, node: sceneryNode)
            }
        }
    }

    /// First descendant (including `root` itself) carrying real, non-empty
    /// `SceneryData` placements — same match `collectLevels` uses for the
    /// Chunk Hub, just short-circuiting on the first hit instead of
    /// collecting every one, since `select`'s one-click path only needs to
    /// know whether *a* level exists in the file that was just parsed.
    private nonisolated static func firstSceneryNode(in root: ChunkNode) -> ChunkNode? {
        if case .scenery(let scenery) = root.payload, !scenery.placements.isEmpty { return root }
        for child in root.children {
            if let found = firstSceneryNode(in: child) { return found }
        }
        return nil
    }

    private func owningArchiveRootID(of node: ChunkNode) -> UUID? {
        for rootID in archiveIndexByRootID.keys {
            guard let root = rootNodes.first(where: { $0.id == rootID }) else { continue }
            if contains(root, node) { return rootID }
        }
        return nil
    }

    private func contains(_ subtree: ChunkNode, _ target: ChunkNode) -> Bool {
        if subtree === target { return true }
        return subtree.children.contains { contains($0, target) }
    }

    /// Extracts an archived entry's bytes from its `.BD` and parses it as a
    /// chunk tree, so levels packed inside a master archive are browsable
    /// without a separate manual extract step.
    ///
    /// This *replaces* `node` in the tree with a brand-new `ChunkNode`
    /// (fresh `UUID`) rather than mutating `node.children`/`.payload` in
    /// place. `ChunkNode` isn't `ObservableObject` — `List`/`OutlineGroup`
    /// diff the tree using each node's `Identifiable.id`, and mutating an
    /// already-diffed reference-type instance's contents in place is not
    /// guaranteed to be picked back up (SwiftUI has no way to know a
    /// property on a plain class changed). Giving the replacement a new
    /// identity makes the change unambiguous to SwiftUI's diffing instead of
    /// relying on it noticing an in-place mutation.
    /// "Visual Loading Feedback": the read+parse used to run fully
    /// synchronously on the main actor — `isLoading` flipped true then
    /// false again within one blocked run-loop turn, so SwiftUI never
    /// actually got a chance to paint the spinner it gates on that flag.
    /// The heavy work now runs in a detached task (same shape as
    /// `openChunkLink`/`loadSingleLevelFileAsync`), with only the tree
    /// mutation itself back on the main actor — a real suspension point in
    /// between, so the spinner genuinely shows for however long parsing an
    /// archived file actually takes.
    public func expandArchiveEntry(_ node: ChunkNode, rootID: UUID) async {
        guard let index = archiveIndexByRootID[rootID] else { return }
        guard let entry = index.entries.first(where: { $0.name == node.displayName }) else { return }
        let kind = Self.fileKind(forEntryNamed: entry.name)

        isLoading = true
        defer { isLoading = false }

        let outcome: Result<(ChunkNode, Data), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let data = try BDArchiveParser.readEntryData(entry, index: index)
                let parsed = try Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: kind, fileName: entry.name)
                return .success((parsed, data))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let (parsed, data)):
            let replacement = ChunkNode(
                recordID: node.recordID,
                sectionType: parsed.sectionType,
                displayName: node.displayName,
                byteSize: node.byteSize,
                fileOffset: node.fileOffset,
                children: parsed.children,
                payload: parsed.payload
            )
            // Real, reported gap: expanding an archive entry (whether from
            // a directly-opened `.BH` or one extracted from a mounted disc
            // image — both converge here) used to only ever update the
            // browsable tree, never register this file's own raw bytes.
            // `canSaveEdits`/`patchedFileBytes` (and everything built on
            // them — "Save Chunk Overrides…", Quick Launch's pending-edit
            // bake-in) all gate on `rawFileBytesByRootID`, so every level
            // reached by *browsing* an archive — the normal way anyone
            // opens a level from a mounted ISO — silently couldn't be
            // saved at all, with no error until the save button itself
            // turned out disabled. `replacement` is exactly the file root
            // `findFileRoot` will later identify for any record inside it
            // (`sectionType == .null` with a `.graphics`/`.code`-family
            // child — the same shape a standalone `Data(contentsOf:)` open
            // already produces), so this is the same real invariant
            // `load(_:)`'s own `rawFileBytesByRootID[node.id] = data` line
            // establishes for a directly-opened file, not a special case.
            rawFileBytesByRootID[replacement.id] = data
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node {
                selectedNode = replacement
            }
        case .failure(let error):
            lastError = "\(entry.name): \(error)"
        }
    }

    /// The WoC counterpart to `expandArchiveEntry`: a mounted disc's real
    /// `.GSC` level file, clicked for the first time. Extracts its real
    /// bytes, plus any real sibling `.AI`/`.GRA`/`.ANM`/`.PAD`/`.TER` bytes
    /// found in the same disc directory (looked up by walking `node`'s
    /// parent's other children — WoC has no separate archive index the
    /// way `.BH` does, so there's no index to look siblings up in), and
    /// hands them to `WOCDiscTreeBuilder`, which runs them through the
    /// same `WOCLevelLoader` pipeline `WOCWorkspace` uses for a real
    /// mounted folder. Replaces `node` in place, same identity-swap
    /// pattern as `expandArchiveEntry`.
    private func expandWOCLevelEntry(_ node: ChunkNode, entry: ISO9660Entry, source: any LogicalSectorSource) async {
        isLoading = true
        defer { isLoading = false }

        guard let gscData = ISO9660Reader.readFile(entry, from: source) else {
            lastError = "Couldn't read \(entry.name)'s real bytes from the mounted image."
            return
        }
        let levelName = (entry.name as NSString).deletingPathExtension

        var siblingData: [String: Data] = [:]
        if let parentNode = parent(of: node, inAnyOf: rootNodes) {
            for sibling in parentNode.children where sibling !== node {
                let ext = (sibling.displayName as NSString).pathExtension.uppercased()
                guard Self.wocSiblingExtensions.contains(ext) else { continue }
                guard (sibling.displayName as NSString).deletingPathExtension.caseInsensitiveCompare(levelName) == .orderedSame else { continue }
                guard let siblingHolder = discEntryByNodeID[sibling.id],
                      let siblingEntry = siblingHolder.entry as? ISO9660Entry,
                      let siblingSource = siblingHolder.source as? any LogicalSectorSource,
                      let data = ISO9660Reader.readFile(siblingEntry, from: siblingSource) else { continue }
                siblingData[ext] = data
            }
        }

        let outcome: Result<(node: ChunkNode, asset: WOCLevelAsset), Error> = await Task.detached(priority: .userInitiated) {
            do {
                let built = try WOCDiscTreeBuilder.buildLevelNode(
                    recordID: node.recordID, displayName: node.displayName, byteSize: node.byteSize, fileOffset: node.fileOffset,
                    gscData: gscData, siblingData: siblingData, levelName: levelName
                )
                return .success(built)
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let built):
            rootNodes = rootNodes.map { replacingDescendant(node, with: built.node, in: $0) }
            wocLevelAssetsByRootID[built.node.id] = built.asset
            if selectedNode === node { selectedNode = built.node }
        case .failure(let error):
            lastError = "\(entry.name): \(error)"
        }
    }

    /// The WoC counterpart to `archiveIndexByRootID`/`discEntryByNodeID`:
    /// keyed by the `ChunkNode.id` `WOCDiscTreeBuilder.buildLevelNode`
    /// returns for a given `.GSC`'s expanded tree, so `resolveComposite(for:)`
    /// can find the real `WOCLevelAsset` (and its `objectMeshes`/
    /// `materialTextureIDs` reference chain) a texture deep in that tree
    /// came from — the tree itself carries none of that, see
    /// `WOCCompositeResolver`'s own doc comment.
    private var wocLevelAssetsByRootID: [UUID: WOCLevelAsset] = [:]

    /// Depth-first search for the nearest ancestor of `target` whose `id`
    /// is a key in `wocLevelAssetsByRootID` — the WoC-tree counterpart to
    /// `findFileRoot`, which only recognizes the RM2/SM2 `Graphics`/`Code`
    /// shape and so never matches anything inside a WoC-sourced subtree.
    private func findWOCLevelAsset(containing target: ChunkNode, in nodes: [ChunkNode]) -> WOCLevelAsset? {
        for node in nodes {
            if let asset = wocLevelAssetsByRootID[node.id], contains(node, target) {
                return asset
            }
            if let found = findWOCLevelAsset(containing: target, in: node.children) {
                return found
            }
        }
        return nil
    }

    /// Extension list for WoC's per-level sibling loose files this build
    /// currently understands — see `WOCLevelAsset`'s doc comment. `.GSC`
    /// itself isn't in this list; it's the file being expanded, not a
    /// sibling of itself.
    private static let wocSiblingExtensions: Set<String> = ["AI", "GRA", "ANM", "PAD", "TER"]

    /// A mounted `SFX.DAT`/`ATS.DAT`, clicked for the first time: extracts
    /// the whole real archive to a temp file once (same one-time-extract
    /// cost `openDiscEntry` already pays for any disc file), reads its
    /// real offset table (cheap — header + table only, no per-clip decode
    /// yet), and builds one real leaf per clip. Each leaf's own PCM decode
    /// is deferred to `decodeWOCSoundClip`, triggered by actually clicking
    /// that specific clip (see `wocSoundClipPending`) — decoding all ~782
    /// real clips up front would mean holding the better part of a
    /// gigabyte of PCM resident just to populate a browsable list.
    private func expandWOCSoundArchive(_ node: ChunkNode, entry: ISO9660Entry, source: any LogicalSectorSource) async {
        isLoading = true
        defer { isLoading = false }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(entry.name)
        let outcome: Result<(URL, [WOCSoundParser.Entry]), Error> = await Task.detached(priority: .userInitiated) {
            guard let data = ISO9660Reader.readFile(entry, from: source) else {
                return .failure(CocoaError(.fileReadUnknown))
            }
            do {
                try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: tempURL)
                let entries = try WOCSoundParser.parseTable(fileURL: tempURL)
                return .success((tempURL, entries))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let (archiveURL, soundEntries)):
            var children: [ChunkNode] = []
            children.reserveCapacity(soundEntries.count)
            for soundEntry in soundEntries {
                let clipNode = ChunkNode(
                    recordID: UInt32(soundEntry.index), sectionType: .null,
                    displayName: "Clip #\(soundEntry.index)", byteSize: Int(soundEntry.size), fileOffset: Int(soundEntry.offset),
                    isLazyLoadable: true
                )
                wocSoundClipPending[clipNode.id] = (archiveURL, soundEntry)
                children.append(clipNode)
            }
            let replacement = ChunkNode(recordID: node.recordID, sectionType: node.sectionType, displayName: node.displayName, byteSize: node.byteSize, fileOffset: node.fileOffset, children: children)
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node { selectedNode = replacement }
        case .failure(let error):
            lastError = "\(entry.name): \(error)"
        }
    }

    /// One real WoC sound clip, decoded on click (see `wocSoundClipPending`'s
    /// doc comment). Reuses `SoundEffectAsset` — the decoded PCM genuinely
    /// fits that type's contract — so the existing `SoundEffectInspectorView`
    /// (waveform, play/stop, WAV export) renders it with no new UI needed.
    /// `sourceAudioByteRange` stays `nil`: this build has no verified WoC
    /// sound *write* path, so "Replace with Audio…" correctly stays
    /// unavailable rather than offering an edit this can't actually save.
    private func decodeWOCSoundClip(_ node: ChunkNode, archiveURL: URL, entry: WOCSoundParser.Entry) async {
        isLoading = true
        defer { isLoading = false }

        let outcome: Result<WOCSoundParser.DecodedClip, Error> = await Task.detached(priority: .userInitiated) {
            do { return .success(try WOCSoundParser.decode(entry, fileURL: archiveURL)) }
            catch { return .failure(error) }
        }.value

        switch outcome {
        case .success(let clip):
            let asset = SoundEffectAsset(id: UInt32(entry.index), sampleRateHz: UInt16(clamping: clip.sampleRate), pcmSamples: clip.samples)
            let replacement = ChunkNode(recordID: node.recordID, sectionType: node.sectionType, displayName: node.displayName, byteSize: node.byteSize, fileOffset: node.fileOffset, payload: .soundEffect(asset))
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node { selectedNode = replacement }
        case .failure(let error):
            lastError = "Clip #\(entry.index): \(error)"
        }
    }

    /// `target`'s immediate parent, searched across every root tree —
    /// `ChunkNode` has no back-pointer, so this is a plain depth-first
    /// walk. Used by `expandWOCLevelEntry` to find a `.GSC`'s real sibling
    /// files (same disc folder, same base name) without WoC having any
    /// archive-index concept to look them up in the way `.BH` entries do.
    private func parent(of target: ChunkNode, inAnyOf roots: [ChunkNode]) -> ChunkNode? {
        for root in roots {
            if let found = parent(of: target, in: root) { return found }
        }
        return nil
    }

    private func parent(of target: ChunkNode, in root: ChunkNode) -> ChunkNode? {
        for child in root.children {
            if child === target { return root }
            if let found = parent(of: target, in: child) { return found }
        }
        return nil
    }

    /// Returns a tree equal to `root` except that `target` (found anywhere
    /// in it, by identity) is swapped for `replacement`. `root` itself is
    /// returned unchanged (same identity) when `target` isn't inside it —
    /// only nodes on the path to `target` get their `children` array
    /// reassigned, so unrelated branches of a large tree (e.g. the other 696
    /// archive entries) aren't touched.
    private func replacingDescendant(_ target: ChunkNode, with replacement: ChunkNode, in root: ChunkNode) -> ChunkNode {
        if root === target { return replacement }
        guard !root.children.isEmpty else { return root }
        var changed = false
        let newChildren = root.children.map { child -> ChunkNode in
            let updated = replacingDescendant(target, with: replacement, in: child)
            if updated !== child { changed = true }
            return updated
        }
        if changed { root.children = newChildren }
        return root
    }

    // MARK: - Editing (proof of concept — see WorldPlacementWriter's doc comment)

    /// Whether `node`'s enclosing file is one this build can currently save
    /// edits back to: a standalone-opened `.RM2`/`.SM2`, not one still
    /// packed inside a `.BD` archive (`rawFileBytesByRootID` is only
    /// populated for the former — see `load(_:)`).
    public func canSaveEdits(for node: ChunkNode) -> Bool {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return false }
        return rawFileBytesByRootID[fileRoot.id] != nil
    }

    /// The original file name `node`'s enclosing standalone-opened
    /// `.RM2`/`.SM2` was loaded from (`ChunkNode.displayName` on the file
    /// root — see `RM2Parser.parse`, which sets it directly from the
    /// caller's `fileName`). Used as the default in-crate file name for
    /// "Export as Mod Crate…", since that's the only name this build
    /// actually knows for the file.
    public func originalFileName(for node: ChunkNode) -> String? {
        findFileRoot(containing: node, in: rootNodes)?.displayName
    }

    /// Public wrapper over `findFileRoot` — "Add Scenery From Other
    /// Level…" needs the destination `.sm2`'s own file root (not just any
    /// node inside it) to pass to `placingSceneryFromAnotherLevel`.
    public func fileRoot(containing node: ChunkNode) -> ChunkNode? {
        findFileRoot(containing: node, in: rootNodes)
    }

    /// "Memory-Mapped Hex Engine" (blueprint 5.2): the exact on-disk bytes
    /// backing `node`, for the raw hex viewer/editor. Same standalone-file
    /// scope as `canSaveEdits`/`patchedFileBytes` — an archive-packed
    /// entry's bytes aren't held anywhere after `expandArchiveEntry`
    /// discards them post-parse, only a standalone-opened file's full bytes
    /// are kept around (`rawFileBytesByRootID`).
    public func rawBytes(for node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id],
              node.fileOffset >= 0, node.byteSize >= 0,
              node.fileOffset + node.byteSize <= bytes.count
        else { return nil }
        return bytes.subdata(in: node.fileOffset..<(node.fileOffset + node.byteSize))
    }

    /// Non-nil presents the Hex Viewer sheet (see `ContentView`).
    @Published public var hexViewerNode: ChunkNode?

    /// "AgentLab Visual Node Graph" (Part 3, roadmap 4.2): non-nil presents
    /// the AgentLab graph sheet (see `ContentView`) for a `CustomAgent`
    /// section container node — see `AgentLabGraphView`'s doc comment for
    /// why its nodes hold raw bytes rather than decoded behavior data.
    @Published public var agentLabNode: ChunkNode?

    /// Saves a hex-edited byte range back the same way `PositionInspectorView`
    /// saves a structured edit — patch a copy of the owning file's bytes,
    /// prompt for where to write it, leave the originally-opened file alone.
    /// `editedBytes.count` must equal `node.byteSize`; the hex editor UI
    /// enforces this by construction (it edits a fixed-size buffer, no
    /// insert/delete), matching `patchedFileBytes`'s own same-size
    /// requirement.
    public func saveHexEdit(node: ChunkNode, editedBytes: Data, to url: URL) async {
        guard let patched = patchedFileBytes(replacing: node, with: editedBytes) else { return }
        do {
            try await writeDataAsync(patched, to: url)
            statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
        } catch {
            lastError = "Save failed: \(error)"
        }
    }

    /// "Visual Loading Feedback": every save path writes a full patched
    /// copy of the source file — genuinely large for a full level file
    /// even when the edit itself is tiny. Runs the actual `Data.write` off
    /// the main actor, bracketed by `isSaving`, so the toolbar spinner
    /// (same real-feedback pattern as loading) has an actual suspension
    /// point to paint across instead of a main-actor call that returns
    /// before SwiftUI gets a chance to render anything.
    public func writeDataAsync(_ data: Data, to url: URL) async throws {
        isSaving = true
        defer { isSaving = false }
        try await Task.detached(priority: .userInitiated) {
            try data.write(to: url)
        }.value
    }

    /// Patches `encoded` into a *copy* of the owning file's original bytes
    /// at `node`'s known offset — pure and side-effect-free; the caller
    /// (a view) is responsible for prompting where to save the result and
    /// actually writing it, matching this codebase's established split
    /// (compare `ExportPanel` + `exportTexturePNG`). Only valid when
    /// `encoded.count == node.byteSize`: this proof of concept covers a
    /// fixed-size record (`Position`, always 16 bytes), so nothing else in
    /// the file needs its offsets adjusted.
    public func patchedFileBytes(replacing node: ChunkNode, with encoded: Data) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              var bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard encoded.count == node.byteSize else {
            lastError = "Internal error: encoded record is \(encoded.count) bytes, expected \(node.byteSize) — refusing to save a size-changing edit."
            return nil
        }
        guard node.fileOffset >= 0, node.fileOffset + encoded.count <= bytes.count else {
            lastError = "Internal error: this record's offset is outside its file's bounds."
            return nil
        }
        bytes.replaceSubrange(node.fileOffset..<(node.fileOffset + encoded.count), with: encoded)
        return bytes
    }

    /// "AgentLab Phase B"'s structural counterpart to `patchedFileBytes(
    /// replacing:with:)`: `encoded` need not be `node.byteSize` bytes —
    /// unlike every other patch function in this file, this one can grow or
    /// shrink `node`'s own on-disk record (adding/removing a `ScriptState`,
    /// `ScriptStateBody`, or `ScriptCommand` changes the record's total
    /// size). Built on the same `ChunkSectionInserter.
    /// applyingRecordChanges` remove-then-insert-same-`id` path "Save Chunk
    /// Overrides" already uses to append brand-new records, applied here to
    /// replace an *existing* one in place instead — the record's own `id`
    /// is preserved (nothing else in the file references it by index/
    /// position, only by this `id`), so every other reference to it stays
    /// valid.
    public func patchedFileBytes(replacingWholeRecord node: ChunkNode, with encoded: Data) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let targetSection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.applyingRecordChanges(
            intoSections: [(section: targetSection, insert: [(id: node.recordID, encoded: encoded)], removeIDs: [node.recordID])],
            fileRoot: fileRoot,
            originalFileBytes: bytes
        ) else {
            lastError = "Internal error: couldn't safely apply the record change to the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Same idea as `patchedFileBytes(replacing:with:)`, but for a record
    /// where only a *leading* fixed-layout portion is being overwritten —
    /// `Instance`'s 28-byte transform prefix (`WorldPlacementWriter.
    /// writeInstanceTransform`), ahead of its variable-length ID/unknown
    /// lists. Safe for the same reason: the prefix's on-disk size never
    /// changes, so nothing after it — inside this record or later in the
    /// file — needs its offset adjusted. Requires `encoded.count <=
    /// node.byteSize`, not `==`: unlike the fixed-size `Position` case,
    /// `node.byteSize` here is the *whole* variable-length record.
    public func patchedFileBytes(replacingPrefixOf node: ChunkNode, with encoded: Data) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              var bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard encoded.count <= node.byteSize else {
            lastError = "Internal error: encoded prefix is \(encoded.count) bytes, longer than the record's own \(node.byteSize) bytes — refusing to save."
            return nil
        }
        guard node.fileOffset >= 0, node.fileOffset + encoded.count <= bytes.count else {
            lastError = "Internal error: this record's offset is outside its file's bounds."
            return nil
        }
        bytes.replaceSubrange(node.fileOffset..<(node.fileOffset + encoded.count), with: encoded)
        return bytes
    }

    /// The "Save Level Overrides" pipeline: applies every `(node, encoded
    /// prefix)` edit into *one* copy of their shared owning file's bytes,
    /// so moving several objects in the Level Viewer and saving once
    /// produces one consistent file, not one save per object. All edits
    /// must belong to the same standalone-opened file — a level's `Instance`
    /// records always do, since they're read from the same `.RM2`/`.SM2`
    /// the level's `SceneryData` came from — but this still checks rather
    /// than assuming it, since patching the wrong file silently would be
    /// far worse than refusing.
    public func patchedFileBytes(applyingPrefixPatches edits: [(node: ChunkNode, encoded: Data)]) -> Data? {
        guard let first = edits.first,
              let fileRoot = findFileRoot(containing: first.node, in: rootNodes),
              var bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this level's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        for (node, encoded) in edits {
            guard findFileRoot(containing: node, in: rootNodes)?.id == fileRoot.id else {
                lastError = "Internal error: level edits spanned more than one file — refusing to save a partial result."
                return nil
            }
            guard encoded.count <= node.byteSize, node.fileOffset >= 0, node.fileOffset + encoded.count <= bytes.count else {
                lastError = "Internal error: an edited record's offset/size didn't check out — refusing to save."
                return nil
            }
            bytes.replaceSubrange(node.fileOffset..<(node.fileOffset + encoded.count), with: encoded)
        }
        return bytes
    }

    /// "Spline & Camera Path Persistence" (roadmap 6.3): patches one or
    /// more fixed-size edits in at *arbitrary* absolute byte offsets
    /// within a file, rather than at an edited node's own
    /// `node.fileOffset` — needed because a Camera Path/Spline control
    /// point isn't a record of its own; it's a `Vector4` nested somewhere
    /// inside its owning Camera record's variable-length body. `node` is
    /// still required per edit (not just a raw offset) so this can verify
    /// the target offset actually falls inside that record's own real
    /// byte range before writing — a stale/wrong offset silently patching
    /// bytes in an unrelated part of the file is exactly the failure mode
    /// worth refusing outright rather than risking.
    public func patchedFileBytes(applyingAbsoluteByteRangePatches edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)]) -> Data? {
        guard let first = edits.first,
              let fileRoot = findFileRoot(containing: first.node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this level's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        return applyingAbsoluteByteRangePatches(edits, into: bytes, fileRootID: fileRoot.id)
    }

    /// Shared validate-and-overwrite loop behind
    /// `patchedFileBytes(applyingAbsoluteByteRangePatches:)` and the
    /// combined Level Viewer save path — factored out so the combined path
    /// can fold these patches into the *same* already-in-progress buffer
    /// as the ordinary transform-prefix edits, instead of each patch
    /// function re-reading fresh bytes from `rawFileBytesByRootID` and one
    /// silently discarding the other's edits.
    private func applyingAbsoluteByteRangePatches(_ edits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)], into bytes: Data, fileRootID: UUID) -> Data? {
        var bytes = bytes
        for (node, absoluteOffset, encoded) in edits {
            guard findFileRoot(containing: node, in: rootNodes)?.id == fileRootID else {
                lastError = "Internal error: edits spanned more than one file — refusing to save a partial result."
                return nil
            }
            guard absoluteOffset >= node.fileOffset, absoluteOffset + encoded.count <= node.fileOffset + node.byteSize else {
                lastError = "Internal error: an edited control point's offset fell outside its own record — refusing to save."
                return nil
            }
            guard absoluteOffset >= 0, absoluteOffset + encoded.count <= bytes.count else {
                lastError = "Internal error: an edited control point's offset was outside its file's bounds."
                return nil
            }
            bytes.replaceSubrange(absoluteOffset..<(absoluteOffset + encoded.count), with: encoded)
        }
        return bytes
    }

    /// "Sound Import" — the write-back half of Sound Playback: replaces a
    /// per-level `SoundEffect` record's real ADPCM audio bytes with
    /// `encodedADPCM`, patched into the *enclosing section's* trailing
    /// extra-data blob at this sound's own known byte range (see
    /// `SoundEffectAsset.sourceAudioByteRange`'s doc comment for why
    /// that's not within the record's own span — the record itself is
    /// just a 22-byte header). `nil` (with `lastError` set) when `node`
    /// has no `sourceAudioByteRange` (a standalone sound-bank entry, not a
    /// per-level record — no chunk section to patch into), when the
    /// enclosing section can't be found, or when `encodedADPCM` is longer
    /// than the original slot: like every other write path in this app,
    /// this never changes a file's total size, so a replacement that
    /// needs *more* room than the original sound had isn't supported —
    /// shortening is fine, the unused tail is zero-padded, which
    /// `ADPCMDecoder.toPCMMono` already stops decoding at cleanly once it
    /// reaches the real end-of-stream line the encoder always writes.
    public func replaceSoundEffectAudio(node: ChunkNode, encodedADPCM: Data) -> Data? {
        guard case .soundEffect(let asset) = node.payload, let range = asset.sourceAudioByteRange else {
            lastError = "This sound has no known on-disk location to write back to — only per-level SoundEffect records support replacement, not standalone sound-bank entries."
            return nil
        }
        guard encodedADPCM.count <= range.length else {
            lastError = "This replacement audio encodes to \(encodedADPCM.count) byte(s), but the original only has room for \(range.length) — try a shorter clip."
            return nil
        }
        guard let sectionNode = findParent(of: node, in: rootNodes) else {
            lastError = "Couldn't find this sound's enclosing section in the current tree."
            return nil
        }
        var padded = encodedADPCM
        if padded.count < range.length {
            padded.append(Data(repeating: 0, count: range.length - padded.count))
        }
        return patchedFileBytes(applyingAbsoluteByteRangePatches: [(node: sectionNode, absoluteOffset: range.offset, encoded: padded)])
    }

    /// The immediate parent of `target` in the tree — nodes don't carry a
    /// parent pointer (see `findFileRoot`'s own doc comment for why:
    /// replaced, not mutated, elsewhere in this view model), so this is a
    /// plain search.
    private func findParent(of target: ChunkNode, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if node.children.contains(where: { $0 === target }) { return node }
            if let found = findParent(of: target, in: node.children) { return found }
        }
        return nil
    }

    /// The `.objectInstance` (or, for a Demo file, `.objectInstanceDemo`)
    /// Tier 2 collection in the same file as `levelNode` — "The Forge
    /// Palette"'s (Part 4C/4D) new-Instance insertion target. Distinct from
    /// `instanceRecords(inSameFileAs:)`, which returns the already-decoded
    /// leaf records themselves; this returns the *collection node* those
    /// leaves live under, since that's what `ChunkSectionInserter` needs to
    /// append a new one.
    private func objectInstanceCollectionNode(inSameFileAs levelNode: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        let targetTypes: Set<SectionType> = [.objectInstance, .objectInstanceDemo]
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if targetTypes.contains(node.sectionType) { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.aiPosition` Tier 2 collection in the same file as `levelNode`
    /// — "AI Pathfinding & Navmesh Editor" (roadmap 5.1)'s new-waypoint
    /// insertion target, same role `objectInstanceCollectionNode` plays for
    /// Instance placements. `nil` when the level's own file has no AI
    /// waypoints at all yet — this build only appends to an existing
    /// collection, matching `ChunkSectionInserter`'s own scope (it grows a
    /// section, it doesn't fabricate a brand-new one from nothing).
    private func aiPositionCollectionNode(inSameFileAs levelNode: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if node.sectionType == .aiPosition, !node.children.isEmpty { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.position` Tier 2 collection in the same file as `node` —
    /// `PositionInspectorView`'s Add/Duplicate/Delete insertion/removal
    /// target, same role/limitation as `aiPositionCollectionNode`: `nil`
    /// when this file has no `Position` collection at all yet (only grows
    /// an existing one, doesn't fabricate a brand-new section).
    public func positionCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return nil }
        func walk(_ n: ChunkNode) -> ChunkNode? {
            if n.sectionType == .position, !n.children.isEmpty { return n }
            for child in n.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// "PositionEditor" parity — one new record ID higher than every
    /// existing record already in `collection`, matching the same
    /// `(existing.max() ?? 0) + 1` scheme `LevelViewerRenderer`'s
    /// `nextSyntheticInstanceID`/`nextSyntheticTriggerID`/
    /// `nextSyntheticCameraID` seed themselves from — recomputed fresh
    /// from the live tree each call rather than a stored counter, since
    /// `PositionInspectorView` adds/duplicates one record per user action
    /// with no multi-add staging session to keep a counter warm across.
    private func nextAvailableRecordID(in collection: ChunkNode) -> UInt32 {
        (collection.children.map(\.recordID).max() ?? 0) + 1
    }

    /// Appends one brand-new `Position` record (id one past every existing
    /// one in this file's `.position` collection) — real structural
    /// insertion via `ChunkSectionInserter`, same generic path the Forge
    /// Palette trusts for Instance/Trigger/Camera placement. `nil` (with
    /// `lastError` set) when this file has no existing `Position`
    /// collection to grow.
    public func patchedFileBytes(insertingPosition point: SIMD4<Float>, inSameFileAs node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = positionCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add a Position here — this file has no existing Position collection this build recognizes."
            return nil
        }
        let newID = nextAvailableRecordID(in: collection)
        let encoded = WorldPlacementWriter.writePosition(PositionMarker(id: newID, point: point))
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new Position into the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Removes one existing `Position` record — the deletion counterpart
    /// to `patchedFileBytes(insertingPosition:inSameFileAs:)`. `nil` (with
    /// `lastError` set) when `node` isn't actually a `Position` record, or
    /// its containing collection can't be found.
    public func patchedFileBytes(removingPosition node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this Position from the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// The `.object`/`.objectDemo` collection in the same file as `node`
    /// — `GameObjectEditorSheet`'s "New Blank Object"/"Duplicate"/"Delete"
    /// insertion/removal target, same role/limitation as
    /// `positionCollectionNode`: `nil` when this file has no `GameObject`
    /// collection at all yet.
    public func gameObjectCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return nil }
        let targetTypes: Set<SectionType> = [.object, .objectDemo]
        func walk(_ n: ChunkNode) -> ChunkNode? {
            if targetTypes.contains(n.sectionType), !n.children.isEmpty { return n }
            for child in n.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// "ObjectEditor" parity — the reference's own `createObjectToolStripMenuItem_Click`/
    /// `duplicateObjectToolStripMenuItem_Click` ID scheme exactly:
    /// `max(8192, every existing ID in this collection) + 1`. The 8192
    /// floor keeps new custom objects out of the range real game content
    /// actually uses, same as the reference tool does.
    private func nextGameObjectID(in collection: ChunkNode) -> UInt32 {
        max(8192, collection.children.map(\.recordID).max() ?? 0) + 1
    }

    /// Inserts `object` (with a fresh ID one past every existing
    /// `GameObject` in this file, or `object.id` itself if the caller
    /// already assigned one — `duplicatingGameObject` needs that so it can
    /// show the caller which ID landed before saving) into this file's
    /// `.object`/`.objectDemo` collection. `nil` (with `lastError` set)
    /// when this file has no existing collection to grow.
    public func patchedFileBytes(insertingGameObject object: GameObjectInfo, inSameFileAs node: ChunkNode) -> (data: Data, insertedID: UInt32)? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = gameObjectCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add a GameObject here — this file has no existing GameObject collection this build recognizes."
            return nil
        }
        let newID = nextGameObjectID(in: collection)
        let withNewID = GameObjectInfo(
            id: newID, name: object.name, ogiIDs: object.ogiIDs, unkBitfield: object.unkBitfield,
            ui32: object.ui32, animIDs: object.animIDs, scriptIDs: object.scriptIDs,
            objectIDs: object.objectIDs, soundIDs: object.soundIDs,
            instanceProperties: object.instanceProperties, linkedIDs: object.linkedIDs,
            scriptCommands: object.scriptCommands
        )
        let encoded = GameObjectWriter.encode(withNewID)
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new GameObject into the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return (result, newID)
    }

    /// Removes one existing `GameObject` record — the deletion
    /// counterpart to `patchedFileBytes(insertingGameObject:inSameFileAs:)`.
    public func patchedFileBytes(removingGameObject node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this GameObject from the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// "IDEditor" parity — ports the reference editor's own `IDEditor.
    /// button1_Click` exactly: reassigns `node`'s ID *in place*, by
    /// patching only the 4-byte `id` field of its own entry in the
    /// containing section's index table
    /// (`Magic(4)+RecordCount(4)+ContentSize(4)` header, then
    /// `{offset(4), size(4), id(4)}` per entry, in on-disk order — see
    /// `ChunkSectionInserter`'s own doc comment for this exact layout).
    /// Nothing else moves: the record's own bytes, its position in the
    /// section, and every other entry are untouched — the same minimal
    /// diff the reference's own `RecordIDs.Remove`/`Add` produces (it
    /// swaps a dictionary key, never touches the physical `Records` list
    /// order). Deliberately narrow, matching the reference tool's own
    /// real behavior rather than a "fixed" version of it: nothing else in
    /// the file that references the old ID by value (an `Instance.
    /// objectID`, a `Trigger.instanceIDs` entry, a script slot, ...) gets
    /// updated — the reference editor's own `IDEditor` doesn't chase
    /// those down either. `nil` (with `lastError` set) when `newID`
    /// already exists in the same section (the reference's own "New ID
    /// already exists" refusal) or `node` has no containing section.
    public func patchedFileBytes(reassigningIDOf node: ChunkNode, to newID: UInt32) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let section = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        guard newID != node.recordID else { return bytes } // matches the reference: "if ID == DataID, Close()" — a same-value rename is a no-op, not an error.
        guard !section.children.contains(where: { $0.recordID == newID }) else {
            lastError = "A record with ID \(newID) already exists in this section — the reference editor refuses this too (\"New ID already exists\")."
            return nil
        }
        guard let entryIndex = section.children.firstIndex(where: { $0 === node }) else {
            lastError = "Internal error: this record isn't actually a child of its own containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        let idFieldOffset = section.fileOffset + 12 + entryIndex * 12 + 8
        guard idFieldOffset >= 0, idFieldOffset + 4 <= bytes.count else {
            lastError = "Internal error: this record's index-table entry falls outside its file's bounds."
            return nil
        }
        var writer = BinaryWriter()
        writer.writeUInt32(newID)
        var patched = bytes
        patched.replaceSubrange((bytes.startIndex + idFieldOffset)..<(bytes.startIndex + idFieldOffset + 4), with: writer.data)
        return patched
    }

    /// The `.aiPath` Tier 2 collection in the same file as `node` —
    /// `AIPathInspectorView`'s Add/Duplicate/Delete insertion/removal
    /// target, same role/limitation as `positionCollectionNode`.
    public func aiPathCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return nil }
        func walk(_ n: ChunkNode) -> ChunkNode? {
            if n.sectionType == .aiPath, !n.children.isEmpty { return n }
            for child in n.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// Public wrapper over `aiPositionCollectionNode` —
    /// `AIPositionInspectorView`'s Add/Duplicate/Delete target. The
    /// private helper stays as-is (still used internally by the Forge
    /// Palette's combined save path); this just exposes the same lookup
    /// to a plain inspector sheet that isn't part of that combined flow.
    public func aiWaypointCollectionNode(inSameFileAs node: ChunkNode) -> ChunkNode? {
        aiPositionCollectionNode(inSameFileAs: node)
    }

    /// Inserts one brand-new `AIPosition` waypoint (id one past every
    /// existing one in this file's `.aiPosition` collection) via
    /// `ChunkSectionInserter` — same insertion path the Forge Palette's
    /// own "Add Waypoint" trusts, exposed here for `AIPositionInspectorView`
    /// to call directly (immediate insert-and-save, not staged).
    public func patchedFileBytes(insertingAIPosition position: SIMD4<Float>, rawNodeType: UInt16, inSameFileAs node: ChunkNode) -> (data: Data, insertedID: UInt32)? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = aiWaypointCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add an AI waypoint here — this file has no existing AIPosition collection this build recognizes."
            return nil
        }
        let newID = (collection.children.map(\.recordID).max() ?? 0) + 1
        let encoded = WorldPlacementWriter.writeAIPosition(position: position, rawNodeType: rawNodeType)
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new AI waypoint into the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return (result, newID)
    }

    public func patchedFileBytes(removingAIPosition node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this AI waypoint from the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Same insertion/removal shape as the AIPosition pair above, for
    /// `AIPathInspectorView`'s `.aiPath` collection.
    public func patchedFileBytes(insertingAIPath args: [UInt16], inSameFileAs node: ChunkNode) -> (data: Data, insertedID: UInt32)? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = aiPathCollectionNode(inSameFileAs: node) else {
            lastError = "Can't add an AI path here — this file has no existing AIPath collection this build recognizes."
            return nil
        }
        let newID = (collection.children.map(\.recordID).max() ?? 0) + 1
        let encoded = WorldPlacementWriter.writeAIPath(args)
        guard let result = ChunkSectionInserter.insertingRecord(id: newID, encoded: encoded, into: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely insert the new AI path into the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return (result, newID)
    }

    public func patchedFileBytes(removingAIPath node: ChunkNode) -> Data? {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes),
              let bytes = rawFileBytesByRootID[fileRoot.id]
        else {
            lastError = "Can't save edits here — this record's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        guard let collection = parent(of: node, inAnyOf: rootNodes) else {
            lastError = "Internal error: couldn't find this record's containing section — refusing to save a possibly-corrupt result."
            return nil
        }
        guard let result = ChunkSectionInserter.removingRecord(id: node.recordID, from: collection, fileRoot: fileRoot, originalFileBytes: bytes) else {
            lastError = "Internal error: couldn't safely remove this AI path from the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    // MARK: - "Place Scenery From Another Level"

    /// Every already-open standalone `.sm2`/`.smx` file root this session
    /// that has at least one real, decoded `SceneryData` placement.
    /// `sceneryLevelSources` is the real candidate list "Add Scenery From
    /// Other Level…"'s picker uses — this stays a separate, narrower
    /// property because `placingSceneryFromAnotherLevel`'s *destination*
    /// side still needs "already open, byte-tracked" specifically (see
    /// `canSaveEdits`'s own doc comment on why every edit feature in this
    /// build requires that).
    public var otherLevelSceneryFileRoots: [ChunkNode] {
        rootNodes.filter { root in
            root.displayName.lowercased().hasSuffix(".sm2") || root.displayName.lowercased().hasSuffix(".smx")
        }.filter { root in
            sceneryNode(in: root) != nil
        }
    }

    /// The real `SceneryData` node inside `fileRoot`, if any.
    public func sceneryNode(in fileRoot: ChunkNode) -> ChunkNode? {
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if case .scenery = node.payload { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.rm2`/`.rmx` file root already open this session whose base
    /// filename matches `sm2Root`'s own — real scenery geometry
    /// (`RigidModel`/`Material`/`Texture`/`Model`) lives in a level's
    /// paired `.rm2`, not its `.sm2` (confirmed against real disc data —
    /// see `CrossFileModelCopierTests`' own doc comment), the same real
    /// pairing `loadSoundBankAsync` already applies to `.MH`/`.MB`. `nil`
    /// if that sibling isn't *also* already open — this doesn't reach
    /// into the archive to open it automatically.
    public func pairedGraphicsFileRoot(for sm2Root: ChunkNode) -> ChunkNode? {
        let baseName = (sm2Root.displayName as NSString).deletingPathExtension.lowercased()
        return rootNodes.first { root in
            let rootBase = (root.displayName as NSString).deletingPathExtension.lowercased()
            let ext = (root.displayName as NSString).pathExtension.lowercased()
            return rootBase == baseName && (ext == "rm2" || ext == "rmx")
        }
    }

    /// One entry in "Add Scenery From Other Level…"'s level picker — either
    /// an already-open standalone `.sm2`/`.smx` (`openFileRoot`, resolved
    /// through the existing byte-tracked path), or a real `.sm2`/`.smx`
    /// entry sitting in a *mounted* archive that's never been opened at all
    /// (`archiveRootID`/`sceneryEntryName`/`graphicsEntryName`) — read
    /// straight off the archive on demand in `loadingSceneryLevelSource`,
    /// same as `siblingActorFileRoot`/`loadChunkLinkActors` already read
    /// sibling files without requiring them pre-opened. This is the real
    /// fix for "the button is always greyed out": most levels a user wants
    /// to borrow scenery from were never individually opened as loose
    /// files — they're just sitting in the mounted `.BD`, which this now
    /// browses directly instead of requiring that manual step first.
    public struct SceneryLevelSource: Identifiable, Hashable {
        public var id: String
        public var displayName: String
        public var openFileRoot: ChunkNode?
        public var archiveRootID: UUID?
        public var sceneryEntryName: String?
        public var graphicsEntryName: String?

        public static func == (lhs: SceneryLevelSource, rhs: SceneryLevelSource) -> Bool { lhs.id == rhs.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Every real source level "Add Scenery From Other Level…" can borrow
    /// from: already-open standalone files first, then every other
    /// `.sm2`/`.smx` archive entry (across every mounted archive) that has
    /// a real sibling `.rm2`/`.rmx` in the same archive — the geometry a
    /// scenery placement actually needs lives there (see
    /// `pairedGraphicsFileRoot`'s own doc comment). Excludes the
    /// destination level itself so it doesn't offer to borrow scenery from
    /// the very file being edited.
    public func sceneryLevelSources(excluding destinationSceneryFileRoot: ChunkNode?) -> [SceneryLevelSource] {
        var seenNames = Set<String>()
        var results: [SceneryLevelSource] = []
        if let excludedName = destinationSceneryFileRoot?.displayName.lowercased() {
            seenNames.insert(excludedName)
        }

        for root in otherLevelSceneryFileRoots {
            let key = root.displayName.lowercased()
            guard seenNames.insert(key).inserted else { continue }
            results.append(SceneryLevelSource(id: key, displayName: root.displayName, openFileRoot: root))
        }

        for (rootID, index) in archiveIndexByRootID {
            for entry in index.entries {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard ext == "sm2" || ext == "smx" else { continue }
                let key = entry.name.lowercased()
                guard !seenNames.contains(key) else { continue }
                guard let graphicsName = Self.siblingActorEntryName(forSceneryEntryName: entry.name, in: index.entries),
                      index.entries.contains(where: { $0.name.caseInsensitiveCompare(graphicsName) == .orderedSame })
                else { continue }
                seenNames.insert(key)
                results.append(SceneryLevelSource(
                    id: key, displayName: (entry.name as NSString).lastPathComponent,
                    archiveRootID: rootID, sceneryEntryName: entry.name, graphicsEntryName: graphicsName
                ))
            }
        }
        return results.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// A `.sm2`/`.smx` file root's own real, parsed graphics root and raw
    /// bytes — its paired `.rm2`/`.rmx` if already open and byte-tracked,
    /// falling back to reading it straight off the same mounted archive
    /// `sceneryFileRoot` itself came from. Shared by both sides of "Add
    /// Scenery From Other Level…": the *source* level (via
    /// `loadingSceneryLevelSource`) and the *destination* level currently
    /// open in the Level Viewer (`placingSceneryFromAnotherLevel`'s own
    /// caller resolves this before invoking it) — the destination side
    /// used to only check `rawFileBytesByRootID` directly, which silently
    /// failed whenever the current level was reached by browsing a mounted
    /// archive rather than manually opening a loose file pair, a real bug.
    private func resolvingGraphicsRoot(for sceneryFileRoot: ChunkNode) async -> (graphicsRoot: ChunkNode, graphicsBytes: Data)? {
        if let graphicsRoot = pairedGraphicsFileRoot(for: sceneryFileRoot), let graphicsBytes = rawFileBytesByRootID[graphicsRoot.id] {
            return (graphicsRoot, graphicsBytes)
        }
        guard let rootID = owningArchiveRootID(of: sceneryFileRoot), let index = archiveIndexByRootID[rootID],
              let graphicsName = Self.siblingActorEntryName(forSceneryEntryName: sceneryFileRoot.displayName, in: index.entries),
              let graphicsEntry = index.entries.first(where: { $0.name.caseInsensitiveCompare(graphicsName) == .orderedSame })
        else {
            lastError = "\(sceneryFileRoot.displayName)'s paired .rm2/.rmx isn't available — it's not open, and isn't sitting in the same mounted archive."
            return nil
        }
        return await Task.detached(priority: .userInitiated) { () -> (ChunkNode, Data)? in
            guard let data = try? BDArchiveParser.readEntryData(graphicsEntry, index: index),
                  let parsed = try? Self.mainTreeDriver(forExtension: (graphicsEntry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: Self.fileKind(forEntryNamed: graphicsEntry.name), fileName: graphicsEntry.name)
            else { return nil }
            return (parsed, data)
        }.value
    }

    /// Resolves one `SceneryLevelSource` into its real, parsed scenery root
    /// plus its real, parsed graphics root and raw bytes — reading straight
    /// off a mounted archive when the source isn't already an open file.
    /// Deliberately doesn't touch `rootNodes`/`rawFileBytesByRootID`: same
    /// read-only posture `siblingActorFileRoot`'s own doc comment already
    /// establishes for a stitched neighbor's data, this is browsing another
    /// level's geometry to copy *from*, not opening it for editing.
    public func loadingSceneryLevelSource(_ source: SceneryLevelSource) async -> (sceneryRoot: ChunkNode, graphicsRoot: ChunkNode, graphicsBytes: Data)? {
        if let openRoot = source.openFileRoot {
            guard let (graphicsRoot, graphicsBytes) = await resolvingGraphicsRoot(for: openRoot) else { return nil }
            return (openRoot, graphicsRoot, graphicsBytes)
        }

        guard let rootID = source.archiveRootID, let index = archiveIndexByRootID[rootID],
              let sceneryName = source.sceneryEntryName, let graphicsName = source.graphicsEntryName,
              let sceneryEntry = index.entries.first(where: { $0.name == sceneryName }),
              let graphicsEntry = index.entries.first(where: { $0.name.caseInsensitiveCompare(graphicsName) == .orderedSame })
        else {
            lastError = "\(source.displayName) isn't in a mounted archive anymore."
            return nil
        }
        return await Task.detached(priority: .userInitiated) { () -> (ChunkNode, ChunkNode, Data)? in
            guard let sceneryData = try? BDArchiveParser.readEntryData(sceneryEntry, index: index),
                  let sceneryRoot = try? Self.mainTreeDriver(forExtension: (sceneryEntry.name as NSString).pathExtension).parseChunkFile(data: sceneryData, fileKind: Self.fileKind(forEntryNamed: sceneryEntry.name), fileName: sceneryEntry.name),
                  let graphicsData = try? BDArchiveParser.readEntryData(graphicsEntry, index: index),
                  let graphicsRoot = try? Self.mainTreeDriver(forExtension: (graphicsEntry.name as NSString).pathExtension).parseChunkFile(data: graphicsData, fileKind: Self.fileKind(forEntryNamed: graphicsEntry.name), fileName: graphicsEntry.name)
            else { return nil }
            return (sceneryRoot, graphicsRoot, graphicsData)
        }.value
    }

    /// One real, distinct model this level places, resolved into a real
    /// `ResolvedModelAsset` so the picker can render an actual thumbnail —
    /// the same `AssetResolver.resolveModelID` call `resolvedLevelPlacements`
    /// already uses for the live viewport, not a re-derived resolution path.
    public struct SceneryCatalogEntry: Identifiable {
        public var id: String { "\(modelID)-\(isSpecial)" }
        public var modelID: UInt32
        public var isSpecial: Bool
        public var count: Int
        public var asset: ResolvedModelAsset
    }

    /// Every distinct real model placed in `sceneryRoot`, resolved against
    /// `graphicsRoot`'s own Graphics data — the click-to-place catalog for
    /// one picked source level.
    public func resolvedSceneryCatalog(sceneryRoot: ChunkNode, graphicsRoot: ChunkNode) async -> [SceneryCatalogEntry] {
        guard let sceneryNode = sceneryNode(in: sceneryRoot), case .scenery(let asset)? = sceneryNode.payload else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: graphicsRoot)
            var byKey: [String: SceneryCatalogEntry] = [:]
            for placement in asset.placements {
                let key = "\(placement.modelID)-\(placement.isSpecial)"
                if byKey[key] != nil {
                    byKey[key]?.count += 1
                } else if let resolved = AssetResolver.resolveModelID(placement.modelID, displayName: "Model #\(placement.modelID)", index: index) {
                    byKey[key] = SceneryCatalogEntry(modelID: placement.modelID, isSpecial: placement.isSpecial, count: 1, asset: resolved)
                }
            }
            return byKey.values.sorted { $0.modelID < $1.modelID }
        }.value
    }

    /// "Add Scenery From Other Level…" — the full cross-file operation:
    /// copies `modelID`/`isSpecial`'s real `RigidModel` chain from
    /// `sourceGraphicsRoot` (the source level's `.rm2`) into the
    /// *destination* level's own paired `.rm2`, then inserts one new,
    /// real, non-special `SceneryModelPlacement` (at `position`,
    /// referencing the freshly-copied `RigidModel`) into the destination
    /// level's `.sm2` `SceneryData` tree — two files, two separate saves,
    /// since the geometry and the placement genuinely live in different
    /// files. Real insertion, same non-aggregated-bbox reasoning
    /// `SceneryModelPlacement.matrixFileOffset`'s doc comment and
    /// `SceneryDataWriter`'s own doc comment establish: always joins the
    /// tree's *root* group directly (no group-level bounding box exists to
    /// maintain, so nesting depth is a spatial-culling optimization this
    /// doesn't need to replicate for a modded placement to render
    /// correctly).
    public struct CrossLevelSceneryPlacementResult {
        public var graphicsFileRoot: ChunkNode
        public var graphicsBytes: Data
        public var sceneryFileRoot: ChunkNode
        public var sceneryBytes: Data
    }

    /// Places another copy of a model *this level's own file already
    /// resolves* — the same-file counterpart to `placingSceneryFromAnotherLevel`,
    /// with no cross-file geometry copy at all: `modelID`/`isSpecial` are
    /// reused exactly as-is, since the placement they came from already
    /// proves that reference resolves here. One file, one save. Real
    /// insertion into the tree's root group, same reasoning as the
    /// cross-level version's own doc comment.
    public func duplicatingSceneryPlacement(modelID: UInt32, isSpecial: Bool, position: SIMD4<Float>, sceneryFileRoot: ChunkNode) -> Data? {
        guard let sceneryNode = sceneryNode(in: sceneryFileRoot),
              case .scenery(let sceneryAsset)? = sceneryNode.payload,
              var root = sceneryAsset.root
        else {
            lastError = "This level has no real SceneryData tree this build recognizes."
            return nil
        }
        let newPlacement = SceneryModelPlacement(
            modelID: modelID, isSpecial: isSpecial,
            boundingBoxMin: position - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: position + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), position]
        )
        let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
        root.model.placements.insert(newPlacement, at: insertIndex)
        root.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = root
        let encoded = SceneryDataWriter.encode(mutatedScenery)
        return patchedFileBytes(replacingWholeRecord: sceneryNode, with: encoded)
    }

    /// The public entry point for resolving the *destination* level's
    /// graphics root/bytes before calling `placingSceneryFromAnotherLevel`
    /// — the same archive-reaching fallback `loadingSceneryLevelSource`
    /// uses for the source side, now shared by the destination side too.
    public func loadingDestinationGraphics(for sceneryFileRoot: ChunkNode) async -> (graphicsRoot: ChunkNode, graphicsBytes: Data)? {
        await resolvingGraphicsRoot(for: sceneryFileRoot)
    }

    public func placingSceneryFromAnotherLevel(
        modelID: UInt32, isSpecial: Bool, position: SIMD4<Float>,
        sourceGraphicsRoot: ChunkNode, sourceGraphicsBytes: Data,
        destinationSceneryFileRoot: ChunkNode,
        destinationGraphicsRoot: ChunkNode, destinationGraphicsBytes: Data
    ) -> CrossLevelSceneryPlacementResult? {
        guard let sceneryNode = sceneryNode(in: destinationSceneryFileRoot),
              case .scenery(let sceneryAsset)? = sceneryNode.payload,
              var root = sceneryAsset.root
        else {
            lastError = "The destination level has no real SceneryData tree this build recognizes."
            return nil
        }

        let copyResult: CrossFileModelCopier.CopyResult
        do {
            copyResult = try CrossFileModelCopier.copyingRigidModelChain(
                modelID: modelID, isSpecial: isSpecial,
                sourceFileRoot: sourceGraphicsRoot, sourceBytes: sourceGraphicsBytes,
                destinationFileRoot: destinationGraphicsRoot, destinationBytes: destinationGraphicsBytes
            )
        } catch {
            lastError = "Couldn't copy the source model's geometry: \(error.localizedDescription)"
            return nil
        }

        let newPlacement = SceneryModelPlacement(
            modelID: copyResult.rigidModelID, isSpecial: false,
            boundingBoxMin: position - SIMD4<Float>(1, 1, 1, 0), boundingBoxMax: position + SIMD4<Float>(1, 1, 1, 0),
            modelMatrix: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), position]
        )
        let insertIndex = root.model.placements.firstIndex(where: { $0.isSpecial }) ?? root.model.placements.count
        root.model.placements.insert(newPlacement, at: insertIndex)
        root.model.header = 0x1613
        var mutatedScenery = sceneryAsset
        mutatedScenery.root = root
        let encodedScenery = SceneryDataWriter.encode(mutatedScenery)

        guard let sceneryBytes = patchedFileBytes(replacingWholeRecord: sceneryNode, with: encodedScenery) else {
            return nil // lastError already set
        }

        return CrossLevelSceneryPlacementResult(
            graphicsFileRoot: destinationGraphicsRoot, graphicsBytes: copyResult.destinationBytes,
            sceneryFileRoot: destinationSceneryFileRoot, sceneryBytes: sceneryBytes
        )
    }

    /// The `.trigger` Tier 2 collection in the same file as `levelNode` —
    /// "Add Trigger"'s insertion/removal target, same role
    /// `aiPositionCollectionNode` plays for waypoints. Same "must already
    /// have at least one real Trigger" limitation: a chunk with zero
    /// existing triggers has no `.trigger` node in the tree to target,
    /// matching the AI-waypoint case's own documented behavior rather than
    /// inventing new whole-section creation.
    private func triggerCollectionNode(inSameFileAs levelNode: ChunkNode) -> ChunkNode? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if node.sectionType == .trigger, !node.children.isEmpty { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(fileRoot)
    }

    /// The `.camera`/`.cameraDemo` Tier 2 collection in the same file as
    /// `levelNode` — "Add Camera"'s insertion/removal target. Returns which
    /// of the two section kinds was actually found alongside the node,
    /// since `WorldPlacementWriter.writeNewCamera(isDemo:)` needs to match
    /// it (`.cameraDemo` omits `UnkShort`/`UnkByte`, per `Camera.cs`'s own
    /// `ParentType == SectionType.CameraDemo` check).
    private func cameraCollectionNode(inSameFileAs levelNode: ChunkNode) -> (node: ChunkNode, isDemo: Bool)? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else { return nil }
        let targetTypes: Set<SectionType> = [.camera, .cameraDemo]
        func walk(_ node: ChunkNode) -> ChunkNode? {
            if targetTypes.contains(node.sectionType), !node.children.isEmpty { return node }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        guard let found = walk(fileRoot) else { return nil }
        return (found, found.sectionType == .cameraDemo)
    }

    /// "Backend Requirement: safely inject this new record" (Part 4D) +
    /// "AI Pathfinding & Navmesh Editor" (roadmap 5.1) — the combined save
    /// path "Save Chunk Overrides…" uses. `transformEdits` (a mix of
    /// Instance transform patches and AI waypoint patches — both are just
    /// fixed-size `(node, encoded)` prefix patches, so they compose freely
    /// in one list) are applied first since they never change any record's
    /// size; then every new Instance is appended into the Instance
    /// collection, then every new AI waypoint into the AIPosition
    /// collection — each insertion building on the previous step's
    /// already-patched bytes, so one "Save" produces one file reflecting
    /// every edit and every placement together, not a save-per-change
    /// sequence. Deliberately has no matching "remove a waypoint" path:
    /// shrinking a section's record count safely is real, separate work
    /// `ChunkSectionInserter` doesn't do today (only growth), so waypoint
    /// deletion stays session-only rather than risk a rushed, unverified
    /// shrink operation.
    public func patchedFileBytes(
        applyingPrefixPatches transformEdits: [(node: ChunkNode, encoded: Data)],
        applyingAbsoluteByteRangePatches controlPointEdits: [(node: ChunkNode, absoluteOffset: Int, encoded: Data)] = [],
        insertingNewInstances newInstances: [(id: UInt32, encoded: Data)],
        insertingNewAIPositions newAIPositions: [(id: UInt32, encoded: Data)],
        insertingNewTriggers newTriggers: [(id: UInt32, encoded: Data)] = [],
        insertingNewCameras newCameras: [(id: UInt32, encoded: Data)] = [],
        removingInstanceIDs: [UInt32] = [],
        removingTriggerIDs: [UInt32] = [],
        removingCameraIDs: [UInt32] = [],
        removingAIPositionIDs: [UInt32] = [],
        levelNode: ChunkNode
    ) -> Data? {
        guard let fileRoot = findFileRoot(containing: levelNode, in: rootNodes) else {
            lastError = "Can't save edits here — this chunk's file isn't a standalone-opened .RM2/.SM2 (archive-packed files aren't supported yet)."
            return nil
        }
        let afterTransformEdits: Data?
        if transformEdits.isEmpty {
            afterTransformEdits = rawFileBytesByRootID[fileRoot.id]
        } else {
            afterTransformEdits = patchedFileBytes(applyingPrefixPatches: transformEdits)
        }
        guard var currentBytes = afterTransformEdits else { return nil }

        // Control-point patches are, like `transformEdits`, pure fixed-size
        // overwrites — folded into the *same* pre-insertion buffer for the
        // same reason `ChunkSectionInserter`'s own doc comment gives for
        // never chaining two single-target insert passes: `insertingRecords`
        // below rebuilds sections using the *original* tree's node offsets
        // against whatever buffer it's handed, so any patch must land
        // before that rebuild runs, not after (an insertion changes total
        // file length and shifts everything downstream of it; an overwrite
        // never does, so overwrites are always safe to apply first).
        if !controlPointEdits.isEmpty {
            guard let afterControlPointEdits = applyingAbsoluteByteRangePatches(controlPointEdits, into: currentBytes, fileRootID: fileRoot.id) else { return nil }
            currentBytes = afterControlPointEdits
        }

        let hasInsertions = !newInstances.isEmpty || !newAIPositions.isEmpty || !newTriggers.isEmpty || !newCameras.isEmpty
        let hasRemovals = !removingInstanceIDs.isEmpty || !removingTriggerIDs.isEmpty || !removingCameraIDs.isEmpty || !removingAIPositionIDs.isEmpty
        guard hasInsertions || hasRemovals else { return currentBytes }

        // Every insertion *and* removal goes through the *one* multi-target
        // rebuild (`applyingRecordChanges(intoSections:...)`), never
        // sequential single-target calls — `.objectInstance`/`.trigger`/
        // `.camera`/`.aiPosition` are all siblings under the same
        // `.instance` container in real files, so calling separate passes
        // would rebuild each later pass's ancestor chain from the
        // *original* tree's offsets against a buffer an earlier pass had
        // already resized, silently corrupting the result. See that
        // function's own doc comment.
        var targets: [(section: ChunkNode, insert: [(id: UInt32, encoded: Data)], removeIDs: [UInt32])] = []
        if !newInstances.isEmpty || !removingInstanceIDs.isEmpty {
            guard let collectionNode = objectInstanceCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't place or remove objects here — this chunk's file has no Instance collection this build recognizes."
                return nil
            }
            targets.append((collectionNode, newInstances, removingInstanceIDs))
        }
        if !newAIPositions.isEmpty || !removingAIPositionIDs.isEmpty {
            guard let collectionNode = aiPositionCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove AI waypoints here — this chunk's file has no existing AIPosition collection."
                return nil
            }
            targets.append((collectionNode, newAIPositions, removingAIPositionIDs))
        }
        if !newTriggers.isEmpty || !removingTriggerIDs.isEmpty {
            guard let collectionNode = triggerCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove triggers here — this chunk's file has no existing Trigger collection to add into."
                return nil
            }
            targets.append((collectionNode, newTriggers, removingTriggerIDs))
        }
        if !newCameras.isEmpty || !removingCameraIDs.isEmpty {
            guard let collection = cameraCollectionNode(inSameFileAs: levelNode) else {
                lastError = "Can't add or remove cameras here — this chunk's file has no existing Camera collection to add into."
                return nil
            }
            targets.append((collection.node, newCameras, removingCameraIDs))
        }

        guard let result = ChunkSectionInserter.applyingRecordChanges(intoSections: targets, fileRoot: fileRoot, originalFileBytes: currentBytes) else {
            lastError = "Internal error: couldn't safely apply the record change(s) to the file structure — refusing to save a possibly-corrupt result."
            return nil
        }
        return result
    }

    /// Whether the destination `.camera` collection for `levelNode` is the
    /// Demo layout (`WorldPlacementWriter.writeNewCamera(isDemo:)` needs to
    /// match it) — `nil` when there's no existing Camera collection to add
    /// into yet, same limitation `cameraCollectionNode` itself documents.
    public func cameraCollectionIsDemo(inSameFileAs levelNode: ChunkNode) -> Bool? {
        cameraCollectionNode(inSameFileAs: levelNode)?.isDemo
    }

    /// Packages an edited file's patched bytes (see `patchedFileBytes`) into
    /// a real, installable `CrateModLoader` `.crate` — the "Crate Mod
    /// Loader & Multi-Game Packager" export path (blueprint 3.3), built on
    /// top of the one record type this build can actually write edits back
    /// to (see `PositionInspectorView`'s doc comment).
    public func exportAsCrate(patchedBytes: Data, originalFileName: String, metadata: CrateMetadata, to crateURL: URL) {
        do {
            try CrateExporter.export(files: [(relativePath: originalFileName, data: patchedBytes)], metadata: metadata, to: crateURL)
            statusMessage = "Exported mod crate to \(crateURL.lastPathComponent)."
        } catch {
            lastError = "Crate export failed: \(error)"
        }
    }

    // MARK: - Linked asset resolution / Model Viewer

    /// Resolves `node` (a `RigidModel` or a `GraphicsInfo` skeleton) into a
    /// fully textured `ResolvedModelAsset` and opens the Model Viewer on it.
    /// This is the fix for "the model and its textures show up as separate,
    /// unrelated files": it cross-references the node's enclosing file's
    /// Graphics/Code sections (mesh, material, texture, skeleton records)
    /// instead of treating them as independent chunks.
    public func openModelViewer(for node: ChunkNode) {
        guard let resolved = resolveComposite(for: node) else {
            lastError = "Couldn't resolve this into a complete model — either this record isn't part of a model/texture/animation chain, or nothing in this file currently references it (check the Scrapped Content Scanner)."
            return
        }
        modelViewerAsset = resolved
    }

    /// The "View Parent / Composite" feature: resolves `node` — a texture,
    /// raw mesh, material, or animation, not just the `RigidModel`/
    /// `GraphicsInfo` link record itself — into the complete object it's
    /// part of. Record IDs in this format are large hash-like values (not
    /// small per-file indices), which means they're effectively global: a
    /// texture stored in one `.RM2` is routinely referenced by a
    /// `RigidModel`/`Material` living in a *different* file (a shared
    /// texture/material bank referenced from many level files is a common
    /// layout for this engine). Restricting the search to "the file this
    /// node happens to live in" — which is all the original implementation
    /// did — means most cross-file references never resolve. This tries
    /// that fast, common-case file first, then falls back to every other
    /// already-parsed file in the workspace, stopping at the first match.
    /// See `AssetResolver.resolveComposite` for the per-payload-kind lookup.
    public func resolveComposite(for node: ChunkNode) -> ResolvedModelAsset? {
        // WoC-sourced textures (e.g. `CRATES.GSC`) never live under a
        // Graphics/Code section `findFileRoot` recognizes -- check the WoC
        // reference chain first, see `WOCCompositeResolver`'s doc comment.
        if case .texture(let texture) = node.payload,
           let wocAsset = findWOCLevelAsset(containing: node, in: rootNodes),
           let resolved = WOCCompositeResolver.resolveComposite(forTextureIndex: Int(texture.id), in: wocAsset, displayNamePrefix: "\(wocAsset.name) — ") {
            return resolved
        }
        if let ownFileRoot = findFileRoot(containing: node, in: rootNodes),
           let resolved = AssetResolver.resolveComposite(for: node, fileRoot: ownFileRoot, displayNamePrefix: "\(ownFileRoot.displayName) — ") {
            return resolved
        }
        for fileRoot in allFileRoots(in: rootNodes) {
            if let resolved = AssetResolver.resolveComposite(for: node, fileRoot: fileRoot, displayNamePrefix: "\(fileRoot.displayName) — ") {
                return resolved
            }
        }
        return nil
    }

    /// The Textures Hub's counterpart to `resolveComposite(for:)` — the Hub
    /// only ever has a `TextureHubEntry` in hand (a `Codable`, `ScanCache`-
    /// persisted value type), never the originating `ChunkNode`, so it
    /// can't call the node-based overload. `TextureHubEntry.texture.id` is
    /// always populated from the same `recordID` the node would carry (see
    /// `TextureParser`/`TextureXParser`'s own `TextureAsset(id: recordID,
    /// ...)` construction), so this is the same real lookup, just entered
    /// from a bare ID. Searches every already-parsed file root in the
    /// workspace, same reasoning as `resolveComposite(for:)`'s own
    /// cross-file fallback: texture IDs are effectively global, so the
    /// referencing material/model is routinely in a different file than
    /// the texture itself. `nil` means nothing currently loaded references
    /// this texture — not necessarily that nothing ever does; a file that
    /// hasn't been parsed this session can't be searched.
    public func resolveComposite(forTextureID textureID: UInt32) -> ResolvedModelAsset? {
        for fileRoot in allFileRoots(in: rootNodes) {
            if let resolved = AssetResolver.resolveComposite(forTextureID: textureID, fileRoot: fileRoot, displayNamePrefix: "\(fileRoot.displayName) — ") {
                return resolved
            }
        }
        return nil
    }

    /// "Scenery/Level Assembly": resolves every placement in `scenery`
    /// (found via `node`, the `SceneryData` chunk itself) into an actual
    /// textured mesh, keyed by the model ID the placement references.
    /// Placements whose `modelID` doesn't match any `RigidModel` in this
    /// file's Graphics section (skinned/`Skin`-based scenery, or a model
    /// this build's resolver can't reach) are silently skipped rather than
    /// failing the whole level — a level with some unresolved pieces is
    /// still far more useful than no level view at all.
    /// A level's scenery tree can carry hundreds/thousands of placements,
    /// each needing a full `RigidModel` -> mesh -> material -> texture
    /// resolution — real CPU work that used to run synchronously on the
    /// main actor when the user clicked "Open Level Viewer," freezing the
    /// UI for however long that took. `fileRoot`/`scenery` are both
    /// `Sendable` (`ChunkNode` is `@unchecked Sendable`, `SceneryAsset` is
    /// a plain `Sendable` struct), so the actual resolution loop can run
    /// entirely off the main actor; only the initial `findFileRoot` lookup
    /// (touching `rootNodes`) needs to happen here first.
    public func resolvedLevelPlacements(for scenery: SceneryAsset, node: ChunkNode) async -> [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)] {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: fileRoot)
            var results: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)] = []
            for placement in scenery.placements {
                guard let transform = placement.worldTransform,
                      let resolved = AssetResolver.resolveModelID(placement.modelID, displayName: "Scenery Object #\(placement.modelID)", index: index)
                else { continue }
                results.append((transform.position, transform.rotation, transform.scale, resolved))
            }
            return results
        }.value
    }

    /// "Visual Levels Hub" / "Direct .RM2 Write-Back" / "Level Editor
    /// Overhaul": the one call every entry point into the Level Viewer
    /// makes — resolves the scenery placements (see
    /// `resolvedLevelPlacements`) and gathers every Instance/Trigger/
    /// Camera/SoundEffect record from the same file *and* its sibling
    /// actor file (see `siblingActorFileRoot`) for the scene-layer markers,
    /// audio panel, and events panel. Kept in one place so no entry point
    /// can drift into gathering different data for what's supposed to be
    /// the same view.
    ///
    /// Real Twinsanity levels are conventionally split across two sibling
    /// archive entries with the same base name: `.sm2` carries scenery/
    /// terrain geometry, `.rm2` carries every Instance/Trigger/Camera/
    /// AIPosition/AIPath/Script for that same level — confirmed against
    /// the real archive (`Levels/Earth/Hub/hubb.sm2` has 462 scenery
    /// placements and *zero* instances/triggers/cameras/AI records;
    /// `hubb.rm2` has 114/7/11/22/21 of those respectively and zero
    /// scenery). `openLevelViewer` is always entered from the scenery side
    /// (see this file's three call sites), so gathering "from the same
    /// file as `node`" alone silently produced a Level Viewer that could
    /// never show a single actor, trigger, camera, or AI waypoint for any
    /// real level — the geometry rendered, everything gameplay-relevant
    /// didn't. This was a real, reproducible bug, not a design choice.
    public func openLevelViewer(for scenery: SceneryAsset, node: ChunkNode) async {
        let placements = await resolvedLevelPlacements(for: scenery, node: node)
        let siblingNode = await siblingActorFileRoot(for: node)

        var instanceMarkers = instanceRecords(inSameFileAs: node)
        var triggers = triggerRecords(inSameFileAs: node)
        var cameras = cameraRecords(inSameFileAs: node)
        var sounds = soundEffectRecords(inSameFileAs: node)
        var aiPositions = aiPositionRecords(inSameFileAs: node)
        var aiPaths = aiPathRecords(inSameFileAs: node)
        var collisionMeshes = collisionMeshRecords(inSameFileAs: node)
        if let siblingNode {
            instanceMarkers += instanceRecords(inSameFileAs: siblingNode)
            triggers += triggerRecords(inSameFileAs: siblingNode)
            cameras += cameraRecords(inSameFileAs: siblingNode)
            sounds += soundEffectRecords(inSameFileAs: siblingNode)
            aiPositions += aiPositionRecords(inSameFileAs: siblingNode)
            aiPaths += aiPathRecords(inSameFileAs: siblingNode)
            collisionMeshes += collisionMeshRecords(inSameFileAs: siblingNode)
        }

        let (resolvedAssets, assetIndex) = await resolvedInstanceAssets(for: instanceMarkers, node: node, siblingNode: siblingNode)
        let defaultAssetIndex = await loadSharedDefaultAssetIndexIfNeeded() ?? GraphicsAssetIndex()
        levelViewerContext = LevelViewerContext(
            scenery: scenery,
            sceneryNode: node,
            placements: placements,
            instanceMarkers: instanceMarkers,
            resolvedInstanceAssets: resolvedAssets,
            assetIndex: assetIndex,
            defaultAssetIndex: defaultAssetIndex,
            triggers: triggers,
            cameras: cameras,
            sounds: sounds,
            chunkLinks: chunkLinkRecords(inSameFileAs: node),
            aiPositions: aiPositions,
            aiPaths: aiPaths,
            collisionMeshes: collisionMeshes
        )
    }

    /// Finds `sceneryNode`'s sibling actor file — the real archive entry
    /// with the same base name and a `.RM2`/`.RMX` extension where this
    /// engine actually stores a level's Instance/Trigger/Camera/AIPosition/
    /// AIPath data (see `openLevelViewer`'s doc comment). Parses it on
    /// demand (reusing `expandArchiveEntry`, the same path a sidebar click
    /// already uses) if it isn't already expanded, so this works whether or
    /// not "Parse All" was run first. Returns `nil` — not an error, just
    /// nothing to add — when `sceneryNode` isn't backed by an archive entry
    /// at all (a standalone-opened loose `.sm2`) or the archive genuinely
    /// has no matching `.rm2`/`.rmx` entry.
    private func siblingActorFileRoot(for sceneryNode: ChunkNode) async -> ChunkNode? {
        // `sceneryNode` is the deeply-nested record that actually carries
        // the `.scenery` payload — its own `displayName` is that record's
        // name, not the file's. The file's real entry name (what needs to
        // be swapped `.sm2`->`.rm2`) lives on the *file-root* ancestor.
        guard let ownFileRoot = findFileRoot(containing: sceneryNode, in: rootNodes),
              let rootID = owningArchiveRootID(of: ownFileRoot),
              let index = archiveIndexByRootID[rootID],
              let siblingName = Self.siblingActorEntryName(forSceneryEntryName: ownFileRoot.displayName, in: index.entries)
        else { return nil }

        if let existing = allFileRoots(in: rootNodes).first(where: { $0.displayName.caseInsensitiveCompare(siblingName) == .orderedSame }) {
            // Already a real parsed tree (non-empty children or a decoded
            // payload) rather than the still-unexpanded placeholder every
            // archive entry starts as.
            if existing.payload != nil || !existing.children.isEmpty { return existing }
            await expandArchiveEntry(existing, rootID: rootID)
            return allFileRoots(in: rootNodes).first { $0.displayName.caseInsensitiveCompare(siblingName) == .orderedSame }
        }
        return nil
    }

    /// The real archive entry name for `sceneryEntryName`'s sibling actor
    /// file — same base name, `.sm2`→`.rm2`/`.smx`→`.rmx` — looked up
    /// against the archive's own real entry list rather than string-built,
    /// "Chunk Stitching Rendering Bug": the missing half of chunk stitching
    /// -- confirmed by direct investigation that `loadChunkLinkPlacements`
    /// only ever gathers a stitched neighbor's *scenery* (`SceneryAsset`)
    /// placements, never its `Instance`/`Trigger`/`Camera`/`AIPosition`
    /// records. Those don't live in the `.sm2` this function resolves
    /// `link.path` to at all -- exactly like the *primary* chunk (see
    /// `openLevelViewer`'s own doc comment), they live in that file's
    /// sibling `.rm2`/`.rmx` actor file, found the same way
    /// `siblingActorFileRoot` finds one for an already-open primary chunk.
    ///
    /// Deliberately read-only: every returned record's `node` comes from a
    /// **standalone-parsed** tree that's never inserted into `rootNodes`
    /// (unlike the primary chunk's own actor file, which genuinely is
    /// tracked there) -- `LevelViewerRenderer.stitchChunkActors` passes
    /// `sourceNode: nil` for these, so a stitched neighbor's markers are
    /// visible but not selectable/editable/save-able. Building real
    /// multi-file write-back (editing a *different* file than the one
    /// "Save Chunk Overrides…" targets) is a separate, larger feature this
    /// doesn't attempt.
    public func loadChunkLinkActors(for link: ChunkLink) async -> (
        fileName: String,
        instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)],
        resolvedInstanceAssets: [UUID: ResolvedModelAsset],
        triggers: [(node: ChunkNode, trigger: TriggerVolume)],
        cameras: [(node: ChunkNode, camera: PlacedCamera)],
        aiPositions: [(node: ChunkNode, marker: AIPositionMarker)]
    )? {
        let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
        let targetSceneryName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { entry in
                entry.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetSceneryName) == .orderedSame
            }.map { (archiveIndex, $0) }
        }).first else { return nil }

        guard let siblingName = Self.siblingActorEntryName(forSceneryEntryName: match.1.name, in: match.0.entries),
              let actorEntry = match.0.entries.first(where: { $0.name.caseInsensitiveCompare(siblingName) == .orderedSame })
        else { return nil }

        let index = match.0
        let defaultIndex = await loadSharedDefaultAssetIndexIfNeeded()

        return await Task.detached(priority: .userInitiated) { () -> (String, [(node: ChunkNode, instance: PlacedInstance)], [UUID: ResolvedModelAsset], [(node: ChunkNode, trigger: TriggerVolume)], [(node: ChunkNode, camera: PlacedCamera)], [(node: ChunkNode, marker: AIPositionMarker)])? in
            guard let data = try? BDArchiveParser.readEntryData(actorEntry, index: index),
                  let actorRoot = try? Self.mainTreeDriver(forExtension: (actorEntry.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .rm2, fileName: actorEntry.name)
            else { return nil }

            var instances: [(node: ChunkNode, instance: PlacedInstance)] = []
            var triggers: [(node: ChunkNode, trigger: TriggerVolume)] = []
            var cameras: [(node: ChunkNode, camera: PlacedCamera)] = []
            var aiPositions: [(node: ChunkNode, marker: AIPositionMarker)] = []
            func walk(_ node: ChunkNode) {
                switch node.payload {
                case .instance(let instance): instances.append((node, instance))
                case .trigger(let trigger): triggers.append((node, trigger))
                case .camera(let camera): cameras.append((node, camera))
                case .aiPosition(let marker): aiPositions.append((node, marker))
                default: break
                }
                for child in node.children { walk(child) }
            }
            walk(actorRoot)

            let assetIndex = AssetResolver.buildIndex(fileRoot: actorRoot)
            var resolvedAssets: [UUID: ResolvedModelAsset] = [:]
            for (markerNode, instance) in instances {
                let selector = instance.unknownUInt32List2.first ?? 0
                guard let resolved = AssetResolver.resolveInstanceObject(objectID: instance.objectID, instanceSelector: selector, index: assetIndex, defaultIndex: defaultIndex) else { continue }
                resolvedAssets[markerNode.id] = resolved
            }

            return (actorEntry.name, instances, resolvedAssets, triggers, cameras, aiPositions)
        }.value
    }

    /// so this only ever returns a name that genuinely exists.
    private nonisolated static func siblingActorEntryName(forSceneryEntryName sceneryEntryName: String, in entries: [ArchiveEntry]) -> String? {
        let sceneryExt = (sceneryEntryName as NSString).pathExtension
        let targetExt: String
        switch sceneryExt.lowercased() {
        case "sm2": targetExt = "rm2"
        case "smx": targetExt = "rmx"
        default: return nil
        }
        let sceneryBase = (sceneryEntryName as NSString).deletingPathExtension
        return entries.first { entry in
            let entryExt = (entry.name as NSString).pathExtension
            guard entryExt.caseInsensitiveCompare(targetExt) == .orderedSame else { return false }
            let entryBase = (entry.name as NSString).deletingPathExtension
            return entryBase.caseInsensitiveCompare(sceneryBase) == .orderedSame
        }?.name
    }

    /// "Comprehensive Instance Population" (Part 4B): resolves every
    /// `Instance.objectID` to real geometry where this build's decoded data
    /// allows it (`AssetResolver.resolveInstanceObject` — `GameObject` ->
    /// `GraphicsInfo` -> skinned mesh or rigid model-link parts), keyed by
    /// the `Instance` node's own identity so `LevelViewerRenderer` can look
    /// each one up directly. Missing from this dictionary is exactly the
    /// "no 3D model available" case `LevelViewerRenderer.upload` falls back
    /// to the colored placeholder marker for — this never fabricates a
    /// substitute for one that doesn't resolve. Also returns the
    /// `GraphicsAssetIndex` itself (built once, here) so "The Forge
    /// Palette" (Part 4C) can resolve a *newly placed* object's geometry
    /// through the exact same index without rebuilding it.
    ///
    /// The index is built from `siblingNode`'s file root when one exists,
    /// falling back to `node`'s own file root otherwise — real, verified
    /// data (see `openLevelViewer`'s own doc comment: `hubb.sm2` has zero
    /// `Instance`/`GameObject` records of its own, `hubb.rm2` has 32) shows
    /// `GameObject` records structurally live in the *actor* file, not the
    /// scenery file `node` always is (`openLevelViewer` is "always entered
    /// from the scenery side"). Building this index from `node` alone was a
    /// real, previously-silent bug: every level's own `GameObject`s were
    /// invisible to this resolver, so both the Forge Palette and already-
    /// placed Instance markers could only ever resolve through the shared
    /// `Default.rm2` fallback, never this level's own actor data.
    private func resolvedInstanceAssets(for instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)], node: ChunkNode, siblingNode: ChunkNode?) async -> (assets: [UUID: ResolvedModelAsset], index: GraphicsAssetIndex) {
        guard let fileRoot = findFileRoot(containing: siblingNode ?? node, in: rootNodes) else { return ([:], GraphicsAssetIndex()) }
        let defaultIndex = await loadSharedDefaultAssetIndexIfNeeded()
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: fileRoot)
            var results: [UUID: ResolvedModelAsset] = [:]
            for (markerNode, instance) in instanceMarkers {
                let selector = instance.unknownUInt32List2.first ?? 0
                guard let resolved = AssetResolver.resolveInstanceObject(objectID: instance.objectID, instanceSelector: selector, index: index, defaultIndex: defaultIndex) else { continue }
                results[markerNode.id] = resolved
            }
            return (results, index)
        }.value
    }

    /// "No More Placeholder Squares": lazily loads and caches
    /// `Startup/Default.rm2` — the real shared-object resource every open
    /// `.BH` archive carries, confirmed against the actual disc (see
    /// `AssetResolver.resolveInstanceObject`'s doc comment) — from
    /// whichever currently-open archive actually has it. `nil` (cached as
    /// such, not retried every call) when no open archive carries it, e.g.
    /// a workspace with only loose `.RM2` files open and no `.BH`.
    private func loadSharedDefaultAssetIndexIfNeeded() async -> GraphicsAssetIndex? {
        if didAttemptLoadingSharedDefaultAssetIndex { return sharedDefaultAssetIndex }
        didAttemptLoadingSharedDefaultAssetIndex = true

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { $0.name.caseInsensitiveCompare("Startup/Default.rm2") == .orderedSame }.map { (archiveIndex, $0) }
        }).first else { return nil }

        let built = await Task.detached(priority: .userInitiated) { () -> GraphicsAssetIndex? in
            guard let data = try? BDArchiveParser.readEntryData(match.1, index: match.0),
                  let fileRoot = try? Self.mainTreeDriver(forExtension: (match.1.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .rm2, fileName: match.1.name)
            else { return nil }
            return AssetResolver.buildIndex(fileRoot: fileRoot)
        }.value
        sharedDefaultAssetIndex = built
        return built
    }

    /// "Chunk-Based Architecture" (Part 2) — "seamlessly load and stitch
    /// adjoining chunk in the 3D viewport": resolves a real `ChunkLink.path`
    /// (confirmed against the mounted disc: real values look like
    /// `levels\earth\cavern\tunnel01` — lowercase, backslash-separated, no
    /// extension, naming another `.SM2` file in the same archive) to an
    /// actual entry in any currently-open archive, parses it, and resolves
    /// its own `SceneryData` placements exactly like
    /// `resolvedLevelPlacements` does for the primary chunk. `nil` when the
    /// path doesn't resolve to any open archive's contents (the neighbor
    /// chunk hasn't been scanned/opened yet) or the neighbor has no
    /// resolvable scenery of its own.
    ///
    /// Only the neighbor's *placement translations* get offset by
    /// `chunkMatrix`'s own translation row (row 3) before being handed
    /// back — the same "position is trustworthy, full matrix orientation
    /// isn't independently confirmed" simplification already documented on
    /// `LevelViewerRenderer`'s own placement-matrix doc comment, now
    /// applied to the chunk-to-chunk alignment transform too.
    /// "Load Chunk" from the Chunk Links inspector — resolves `link.path`
    /// against the archives already open in this workspace (same lookup
    /// `loadChunkLinkPlacements` uses for the Level Viewer's 3D stitching),
    /// parses the target file through the normal ingestion path, and adds
    /// it as a real, first-class entry in `rootNodes` — so it shows up in
    /// the sidebar tree exactly like any file the user opened directly,
    /// not just as geometry merged into a 3D view. Returns `false` (and
    /// sets `lastError`) when the target isn't in a currently open archive,
    /// matching the existing "open the level or archive it belongs to
    /// first" guidance already given elsewhere in this codebase for the
    /// same lookup.
    @discardableResult
    public func openChunkLink(_ link: ChunkLink) async -> Bool {
        let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
        let targetName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { entry in
                entry.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetName) == .orderedSame
            }.map { (archiveIndex, $0) }
        }).first else {
            lastError = "Couldn't find \(targetName) in any currently open archive — open the level or archive it belongs to first."
            return false
        }

        // Already open from an earlier "Load Chunk" click, or from being
        // separately expanded in the archive tree — select it instead of
        // adding a duplicate root.
        if let existing = rootNodes.first(where: { $0.displayName.caseInsensitiveCompare(match.1.name) == .orderedSame }) {
            select(existing)
            return true
        }

        let entry = match.1
        let index = match.0
        guard let node = await Task.detached(priority: .userInitiated, operation: { () -> ChunkNode? in
            guard let data = try? BDArchiveParser.readEntryData(entry, index: index) else { return nil }
            return try? Self.mainTreeDriver(forExtension: (entry.name as NSString).pathExtension)
                .parseChunkFile(data: data, fileKind: .sm2, fileName: entry.name)
        }).value else {
            lastError = "Failed to parse \(entry.name)."
            return false
        }

        rootNodes.append(node)
        select(node)
        return true
    }

    public func loadChunkLinkPlacements(for link: ChunkLink) async -> (fileName: String, placements: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)])? {
        let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
        let targetName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"

        guard let match = archiveIndexByRootID.values.compactMap({ archiveIndex -> (ArchiveIndex, ArchiveEntry)? in
            archiveIndex.entries.first { entry in
                entry.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetName) == .orderedSame
            }.map { (archiveIndex, $0) }
        }).first else { return nil }

        return await Task.detached(priority: .userInitiated) { () -> (String, [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)])? in
            guard let data = try? BDArchiveParser.readEntryData(match.1, index: match.0),
                  let fileRoot = try? Self.mainTreeDriver(forExtension: (match.1.name as NSString).pathExtension).parseChunkFile(data: data, fileKind: .sm2, fileName: match.1.name)
            else { return nil }

            var scenery: SceneryAsset?
            func walk(_ node: ChunkNode) {
                if scenery == nil, case .scenery(let found) = node.payload, !found.placements.isEmpty { scenery = found }
                for child in node.children { walk(child) }
            }
            walk(fileRoot)
            guard let scenery else { return (match.1.name, []) }

            let index = AssetResolver.buildIndex(fileRoot: fileRoot)
            var results: [(worldPosition: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>, asset: ResolvedModelAsset)] = []
            var droppedCount = 0
            for placement in scenery.placements {
                guard let transform = placement.worldTransform,
                      let resolved = AssetResolver.resolveModelID(placement.modelID, displayName: "Scenery Object #\(placement.modelID)", index: index)
                else { droppedCount += 1; continue }
                results.append((transform.position, transform.rotation, transform.scale, resolved))
            }
            // "Chunk Stitching Rendering Bug": these two `continue`s used to
            // drop a stitched neighbor's scenery/terrain placements with no
            // trace at all — indistinguishable from "stitching worked but
            // there was nothing there." Surfacing the real count here (and
            // in `ModelViewerRenderer.stitchChunk`'s own build-failure count)
            // is what actually lets a real drop be diagnosed instead of
            // guessed at.
            if droppedCount > 0 {
                AppLog.rendering.debug("Chunk stitch \(match.1.name) — \(droppedCount) of \(scenery.placements.count) scenery placements failed to resolve (missing transform or unresolvable modelID), dropped before rendering")
            }
            return (match.1.name, results)
        }.value
    }

    /// "Deep Hierarchy & Linked Asset Resolution": the parent composite
    /// object `node` belongs to, plus every component that composite is
    /// built from — one call standing in for what used to be scattered
    /// across the Model Viewer's separate sections.
    public func relationalChain(for node: ChunkNode) -> RelationalChain? {
        resolveComposite(for: node).map(RelationalChain.init(asset:))
    }

    /// Jumps the sidebar selection to the chunk backing `component` — the
    /// "click a linked component to go inspect it directly" affordance in
    /// the relational chain panel. Searches every parsed file (component
    /// IDs are the same global, hash-like values discussed on
    /// `resolveComposite`, so the record isn't guaranteed to be in the same
    /// file as the composite that references it); silently does nothing
    /// findable if the underlying chunk isn't in the currently loaded
    /// workspace at all — e.g. a texture record from an archive entry that
    /// hasn't been scanned/expanded yet.
    public func selectComponent(_ component: LinkedComponent) {
        guard let found = findNode(matching: component, in: rootNodes) else {
            lastError = "\(component.displayName) isn't loaded in the current workspace yet — try Scan Archive."
            return
        }
        select(found)
    }

    private func findNode(matching component: LinkedComponent, in nodes: [ChunkNode]) -> ChunkNode? {
        for node in nodes {
            if matches(node.payload, component) { return node }
            if !isExpandableArchiveEntry(node), let found = findNode(matching: component, in: node.children) {
                return found
            }
        }
        return nil
    }

    private func matches(_ payload: ChunkPayload?, _ component: LinkedComponent) -> Bool {
        switch (payload, component.kind) {
        case (.mesh(let mesh), .mesh): return mesh.id == component.recordID
        case (.material(let material), .material): return material.id == component.recordID
        case (.texture(let texture), .texture): return texture.id == component.recordID
        case (.skeleton(let skeleton), .skeleton): return skeleton.id == component.recordID
        case (.animation(let animation), .animation): return animation.id == component.recordID
        default: return false
        }
    }

    /// Depth-first search for the nearest ancestor of `target` that looks
    /// like a parsed file root (a `.null`-typed node with a `Graphics` or
    /// `Code` section child) — i.e. the specific `.RM2`/`.SM2` a RigidModel
    /// or GraphicsInfo record came from, so its sibling Texture/Material
    /// sections can be found. Plain tree search rather than parent pointers:
    /// nodes get replaced (not mutated) elsewhere in this view model (see
    /// `expandArchiveEntry`), which would leave stale parent references.
    private func findFileRoot(containing target: ChunkNode, in nodes: [ChunkNode], currentRoot: ChunkNode? = nil) -> ChunkNode? {
        let fileRootSectionTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD, .code, .codeX, .codeDemo]
        for node in nodes {
            let looksLikeFileRoot = node.sectionType == .null && node.children.contains { fileRootSectionTypes.contains($0.sectionType) }
            let nextRoot = looksLikeFileRoot ? node : currentRoot
            if node === target { return nextRoot }
            if let found = findFileRoot(containing: target, in: node.children, currentRoot: nextRoot) {
                return found
            }
        }
        return nil
    }

    /// Every already-parsed file root reachable from `nodes` — the
    /// workspace-wide counterpart to `findFileRoot`, used to fall back to a
    /// cross-file search. Doesn't descend into an unexpanded archive entry
    /// (`isExpandableArchiveEntry`): those have no decoded payload yet, so
    /// there's nothing in them to match against regardless.
    private func allFileRoots(in nodes: [ChunkNode]) -> [ChunkNode] {
        let fileRootSectionTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD, .code, .codeX, .codeDemo]
        var roots: [ChunkNode] = []
        for node in nodes {
            if node.sectionType == .null && node.children.contains(where: { fileRootSectionTypes.contains($0.sectionType) }) {
                roots.append(node)
            }
            if !isExpandableArchiveEntry(node) {
                roots.append(contentsOf: allFileRoots(in: node.children))
            }
        }
        return roots
    }

    /// One-click bundled export: the mesh (OBJ), an `.mtl` linking each
    /// resolved submesh material to its exported texture, every uniquely
    /// referenced texture (PNG), and every candidate animation's decoded
    /// curve data (JSON) — all in one folder, so opening the result in
    /// another tool (Blender, etc.) shows a properly textured model instead
    /// of a pile of unrelated files.
    public func exportCompleteAsset(_ asset: ResolvedModelAsset, to directory: URL) {
        let baseName = Self.sanitizedFileName(asset.displayName)
        let assetFolder = directory.appendingPathComponent(baseName)
        do {
            let built = try Self.completeAssetFiles(for: asset, baseName: baseName)
            try FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)
            for file in built.files {
                let destination = assetFolder.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination)
            }
            statusMessage = "Exported complete asset (\(built.materialCount) material(s), \(built.textureCount) texture(s), \(built.animationCount) animation(s)) to \(assetFolder.path)."
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    /// "Cross-Object Dependency Packaging" (blueprint 3.2) — "Export with
    /// Dependencies": the same mesh/textures/materials/animations
    /// `exportCompleteAsset` writes as loose files gets bundled instead
    /// into one portable `.crate`, reusing `CrateExporter.export`'s
    /// existing multi-file `layer0/` packaging (already built for blueprint
    /// 3.3, just never called with more than one file). Built from the same
    /// `resolveComposite` linked-asset graph as the folder export — nothing
    /// here invents a new notion of "dependency," it's the real mesh ->
    /// material -> texture / mesh -> animation links this codebase already
    /// resolves and trusts elsewhere.
    public func exportCompleteAssetAsCrate(_ asset: ResolvedModelAsset, metadata: CrateMetadata, to crateURL: URL) {
        let baseName = Self.sanitizedFileName(asset.displayName)
        do {
            let built = try Self.completeAssetFiles(for: asset, baseName: baseName)
            let files = built.files.map { (relativePath: "\(baseName)/\($0.relativePath)", data: $0.data) }
            try CrateExporter.export(files: files, metadata: metadata, to: crateURL)
            statusMessage = "Exported mod crate with \(built.materialCount) material(s), \(built.textureCount) texture(s), \(built.animationCount) animation(s) to \(crateURL.lastPathComponent)."
        } catch {
            lastError = "Crate export failed: \(error)"
        }
    }

    private struct CompleteAssetFiles {
        var files: [(relativePath: String, data: Data)]
        var materialCount: Int
        var textureCount: Int
        var animationCount: Int
    }

    /// Builds every file `exportCompleteAsset`/`exportCompleteAssetAsCrate`
    /// need, purely in memory — paths are relative to the asset's own
    /// folder (e.g. `"\(baseName).obj"`, `"animations/animation_1.json"`),
    /// so callers decide whether that folder lands loose on disk or inside
    /// a zipped crate's `layer0/`.
    private nonisolated static func completeAssetFiles(for asset: ResolvedModelAsset, baseName: String) throws -> CompleteAssetFiles {
        var files: [(relativePath: String, data: Data)] = []

        var exportedTextureNames: [UInt32: String] = [:]
        for material in asset.submeshMaterials {
            guard let textureID = material.textureID, let texture = material.texture, exportedTextureNames[textureID] == nil else { continue }
            let texName = "texture_\(textureID)"
            let pngData = try TextureExporter.pngData(texture)
            files.append((relativePath: "\(texName).png", data: pngData))
            exportedTextureNames[textureID] = texName
        }

        let mtlFileName = "\(baseName).mtl"
        var seenMaterials: Set<UInt32> = []
        var mtlLines = ["# Generated by TwinsanityStudio"]
        for material in asset.submeshMaterials {
            guard let materialID = material.materialID, !seenMaterials.contains(materialID) else { continue }
            seenMaterials.insert(materialID)
            mtlLines.append("")
            mtlLines.append("newmtl material_\(materialID)")
            mtlLines.append("Kd 1.000 1.000 1.000")
            if let textureID = material.textureID, let texName = exportedTextureNames[textureID] {
                mtlLines.append("map_Kd \(texName).png")
            }
        }
        guard let mtlData = (mtlLines.joined(separator: "\n") + "\n").data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        files.append((relativePath: mtlFileName, data: mtlData))

        let submeshMaterialIDs = asset.submeshMaterials.map(\.materialID)
        let objContents = try OBJExporter.contents(asset.mesh, submeshMaterialIDs: submeshMaterialIDs, mtlFileName: mtlFileName)
        guard let objData = objContents.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        files.append((relativePath: "\(baseName).obj", data: objData))

        for animation in asset.availableAnimations {
            let json = Self.animationJSON(animation)
            guard let jsonData = json.data(using: .utf8) else { continue }
            files.append((relativePath: "animations/animation_\(animation.id).json", data: jsonData))
        }

        return CompleteAssetFiles(files: files, materialCount: seenMaterials.count, textureCount: exportedTextureNames.count, animationCount: asset.availableAnimations.count)
    }

    private nonisolated static func animationJSON(_ animation: AnimationAsset) -> String {
        func trackDict(_ track: AnimationTrack) -> [String: Any] {
            [
                "jointCount": track.jointSettings.count,
                "staticTransformCount": track.staticTransforms.count,
                "totalFrames": track.totalFrames,
                "componentsPerFrame": track.componentsPerFrame,
                "frames": track.frames.map { $0.values.map { Int($0) } }
            ]
        }
        let dict: [String: Any] = [
            "id": animation.id,
            "body": trackDict(animation.body),
            "facial": trackDict(animation.facial)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private nonisolated static func sanitizedFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let withoutExtension = (base as NSString).deletingPathExtension
        let cleaned = withoutExtension.isEmpty ? base : withoutExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(cleaned.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return sanitized.isEmpty ? "asset" : sanitized
    }

    // MARK: - Export

    public func exportTexturePNG(_ asset: TextureAsset, suggestedName: String, to directory: URL) {
        do {
            try TextureExporter.exportAllLevels(asset, baseName: suggestedName, to: directory)
            statusMessage = "Exported \(suggestedName).png (+\(asset.mips.count) mip level(s))."
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    public func exportMeshOBJ(_ mesh: MeshAsset, suggestedName: String, to directory: URL) {
        do {
            let url = directory.appendingPathComponent(suggestedName).appendingPathExtension("obj")
            try OBJExporter.export(mesh, to: url)
            statusMessage = "Exported \(suggestedName).obj."
        } catch {
            lastError = "Export failed: \(error)"
        }
    }

    // MARK: - Batch export (blueprint 3.1)

    /// Non-nil while a batch export (see `exportBatch`) is running — drives
    /// the Models Hub's progress indicator.
    @Published public var batchExportProgress: (completed: Int, total: Int)?

    /// "One-Click Batch Export": runs the same per-asset `exportCompleteAsset`
    /// logic the single-asset "Export Complete Asset…"/"Export as Group…"
    /// actions already use, queued across a multi-selection instead of
    /// called once — each asset gets its own subfolder under `directory`
    /// (see `exportCompleteAsset`), so there's no collision between them.
    /// `Task.yield()` between assets keeps `batchExportProgress` (and the
    /// rest of the UI) updating across what can be tens of assets' worth of
    /// PNG/OBJ/JSON writes, without a full off-main-actor rewrite of
    /// `exportCompleteAsset` itself.
    public func exportBatch(_ assets: [ResolvedModelAsset], to directory: URL) async {
        guard !assets.isEmpty else { return }
        batchExportProgress = (0, assets.count)
        for (index, asset) in assets.enumerated() {
            exportCompleteAsset(asset, to: directory)
            batchExportProgress = (index + 1, assets.count)
            await Task.yield()
        }
        statusMessage = "Batch export complete — \(assets.count) asset(s) exported to \(directory.path)."
        batchExportProgress = nil
    }
}
