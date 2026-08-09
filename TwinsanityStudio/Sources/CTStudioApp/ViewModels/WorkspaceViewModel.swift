import Foundation
import SwiftUI
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
    /// Non-nil presents the Model Viewer sheet (see `ContentView`).
    @Published public var modelViewerAsset: ResolvedModelAsset?
    /// Non-nil presents the Collision Viewer sheet (see `ContentView`).
    @Published public var collisionViewerMesh: CollisionMesh?
    /// Non-nil presents the Level Viewer sheet (see `ContentView`).
    @Published public var levelViewerContext: LevelViewerContext?
    /// Every RigidModel/Skeleton successfully resolved (mesh + textures, and
    /// skeleton + animations where rigged) across every scanned file —
    /// populated automatically as archives are scanned, so browsing models
    /// never requires manually parsing/resolving a specific chunk first.
    @Published public var modelsHub: [ResolvedModelAsset] = []
    @Published public var isModelsHubPresented = false
    /// "Textures Hub" (QoL sweep) — every decoded texture across every
    /// scanned file, populated alongside `modelsHub` the same way.
    @Published public var texturesHub: [TextureHubEntry] = []
    @Published public var isTexturesHubPresented = false
    /// "Visual Levels Hub" — every decoded `SceneryData` record (one per
    /// level file that actually has an assembled scenery tree) across every
    /// parsed file, populated alongside `modelsHub`/`texturesHub`. See
    /// `LevelHubEntry`'s doc comment for why this one isn't cache-backed.
    @Published public var levelsHub: [LevelHubEntry] = []
    @Published public var isLevelsHubPresented = false
    /// Every dangling reference / unreferenced record flagged by the
    /// "Scrapped Content Scanner" across every scanned file — populated
    /// alongside `modelsHub` so cut content surfaces automatically as
    /// archives are scanned, with no separate manual scan step.
    @Published public var orphanedContent: [OrphanedAsset] = []
    @Published public var isScrappedContentScannerPresented = false
    /// "Asset Diff & Version Comparison" (blueprint 4.3): non-nil presents
    /// the diff sheet.
    @Published public var isAssetDiffPresented = false

    private var archiveIndexByRootID: [UUID: ArchiveIndex] = [:]
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
            nodes = nodes.compactMap { $0.prunedOfRawContent() }
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
            let detected = WorkspaceAutoDetector.scanFolder(url)
            statusMessage = "Found \(detected.count) recognizable file(s) in \(url.lastPathComponent)."
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
            return
        }
        load(WorkspaceAutoDetector.detect(url: url))
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
    private func loadLooseLevelFilesAsync(_ files: [DetectedFile]) {
        isLoading = true
        statusMessage = "Parsing \(files.count) level file(s)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let results = await withTaskGroup(of: LooseLevelFileResult.self) { group in
                for file in files {
                    group.addTask {
                        do {
                            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                            let node = try RM2Parser.parse(data: data, fileKind: Self.fileKind(for: file), fileName: file.url.lastPathComponent)
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

    private func load(_ file: DetectedFile) {
        isLoading = true
        defer { isLoading = false }
        do {
            switch file.kind {
            case .archiveIndex:
                let index = try BDArchiveParser.readIndex(bhURL: file.url)
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
                // "Memory-Mapped Hex Engine" (blueprint 5.2): `.mappedIfSafe`
                // asks Foundation to `mmap` the file instead of reading it
                // fully into the heap up front — a real, meaningful choice
                // for a full level file (potentially many MB) whose bytes
                // are about to be walked into a `ChunkNode` tree, most of
                // which the user will never look at. Mutating this `Data`
                // later (`patchedFileBytes`'s `replaceSubrange`) still works
                // correctly — Foundation copy-on-writes a mapped buffer into
                // a private heap copy the moment it's actually mutated, so
                // the on-disk file is never touched by editing this in-memory
                // copy.
                let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
                let node = try RM2Parser.parse(data: data, fileKind: Self.fileKind(for: file), fileName: file.url.lastPathComponent)
                rawFileBytesByRootID[node.id] = data
                rootNodes.append(node)
                statusMessage = "Loaded \(file.url.lastPathComponent) — \(node.children.count) top-level chunks."
                modelsHub.append(contentsOf: Self.resolveModels(inFileRoot: node, sourceLabel: file.url.lastPathComponent))
                orphanedContent.append(contentsOf: AssetResolver.scanForOrphans(fileRoot: node, sourceLabel: file.url.lastPathComponent))
                texturesHub.append(contentsOf: Self.collectTextures(inFileRoot: node, sourceLabel: file.url.lastPathComponent))
                levelsHub.append(contentsOf: Self.collectLevels(inFileRoot: node, sourceLabel: file.url.lastPathComponent))
                addRecentFile(file.url)

            case .archiveData:
                statusMessage = "Drop the matching .BH file to browse \(file.url.lastPathComponent) (a .BD alone has no index)."

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
    /// Split into a serial I/O phase and a parallel CPU phase per archive:
    /// `BDArchiveReader` reuses one open file handle and isn't safe for
    /// concurrent reads (see its own doc comment), so every candidate
    /// entry's bytes are pulled up front on one thread — but chunk-tree
    /// parsing, geometry/texture decode, and asset resolution are pure
    /// functions over each entry's own independent `Data`, so that half
    /// fans out across every core via a `TaskGroup` instead of running one
    /// file at a time.
    public func scanAllArchives() {
        guard !isScanning else { return }
        let targets = archiveIndexByRootID.map { ($0.key, $0.value) }
        guard !targets.isEmpty else { return }

        let totalCandidates = targets.reduce(0) { partial, pair in
            partial + pair.1.entries.filter { Self.isChunkFileName($0.name) }.count
        }
        guard totalCandidates > 0 else { return }

        isScanning = true
        statusMessage = "Scanning \(totalCandidates) level file(s) across \(targets.count) archive(s)…"

        Task.detached(priority: .userInitiated) { [weak self] in
            var resultsByRoot: [UUID: [String: ChunkNode]] = [:]
            var resolvedModels: [ResolvedModelAsset] = []
            var orphans: [OrphanedAsset] = []
            var textures: [TextureHubEntry] = []
            var levels: [LevelHubEntry] = []

            for (rootID, index) in targets {
                guard let reader = try? BDArchiveReader(index: index) else { continue }
                var pendingEntries: [(name: String, data: Data, kind: TwinsFileKind)] = []
                for entry in index.entries where Self.isChunkFileName(entry.name) {
                    guard let data = try? reader.read(entry) else { continue }
                    pendingEntries.append((entry.name, data, Self.fileKind(forEntryNamed: entry.name)))
                }

                let parsed = await withTaskGroup(of: ParsedEntryResult?.self) { group in
                    for pending in pendingEntries {
                        group.addTask {
                            guard let node = try? RM2Parser.parse(data: pending.data, fileKind: pending.kind, fileName: pending.name) else { return nil }
                            let models = Self.resolveModels(inFileRoot: node, sourceLabel: pending.name)
                            let entryOrphans = AssetResolver.scanForOrphans(fileRoot: node, sourceLabel: pending.name)
                            let entryTextures = Self.collectTextures(inFileRoot: node, sourceLabel: pending.name)
                            let entryLevels = Self.collectLevels(inFileRoot: node, sourceLabel: pending.name)
                            return ParsedEntryResult(name: pending.name, node: node, models: models, orphans: entryOrphans, textures: entryTextures, levels: entryLevels)
                        }
                    }
                    var collected: [ParsedEntryResult] = []
                    collected.reserveCapacity(pendingEntries.count)
                    for await result in group where result != nil {
                        collected.append(result!)
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

            await self?.applyBulkScan(resultsByRoot, resolvedModels: resolvedModels, orphans: orphans, textures: textures, levels: levels)
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

    private func applyBulkScan(_ resultsByRoot: [UUID: [String: ChunkNode]], resolvedModels: [ResolvedModelAsset], orphans: [OrphanedAsset], textures: [TextureHubEntry], levels: [LevelHubEntry]) {
        defer { isScanning = false }
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
        statusMessage = failedCount == 0
            ? "Scan complete — parsed \(parsedCount) level file(s), found \(resolvedModels.count) model(s) and \(orphans.count) orphaned/cut record(s)."
            : "Scan complete — parsed \(parsedCount) level file(s), \(failedCount) failed to parse, found \(resolvedModels.count) model(s) and \(orphans.count) orphaned/cut record(s)."
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
            guard let node, self.isExpandableArchiveEntry(node) else { return }
            guard let rootID = self.owningArchiveRootID(of: node) else { return }
            self.expandArchiveEntry(node, rootID: rootID)
        }
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
    public func expandArchiveEntry(_ node: ChunkNode, rootID: UUID) {
        guard let index = archiveIndexByRootID[rootID] else { return }
        guard let entry = index.entries.first(where: { $0.name == node.displayName }) else { return }
        let kind = Self.fileKind(forEntryNamed: entry.name)

        isLoading = true
        defer { isLoading = false }
        do {
            let data = try BDArchiveParser.readEntryData(entry, index: index)
            let parsed = try RM2Parser.parse(data: data, fileKind: kind, fileName: entry.name)
            let replacement = ChunkNode(
                recordID: node.recordID,
                sectionType: parsed.sectionType,
                displayName: node.displayName,
                byteSize: node.byteSize,
                fileOffset: node.fileOffset,
                children: parsed.children,
                payload: parsed.payload
            )
            rootNodes = rootNodes.map { replacingDescendant(node, with: replacement, in: $0) }
            if selectedNode === node {
                selectedNode = replacement
            }
        } catch {
            lastError = "\(entry.name): \(error)"
        }
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

    /// Saves a hex-edited byte range back the same way `PositionInspectorView`
    /// saves a structured edit — patch a copy of the owning file's bytes,
    /// prompt for where to write it, leave the originally-opened file alone.
    /// `editedBytes.count` must equal `node.byteSize`; the hex editor UI
    /// enforces this by construction (it edits a fixed-size buffer, no
    /// insert/delete), matching `patchedFileBytes`'s own same-size
    /// requirement.
    public func saveHexEdit(node: ChunkNode, editedBytes: Data, to url: URL) {
        guard let patched = patchedFileBytes(replacing: node, with: editedBytes) else { return }
        do {
            try patched.write(to: url)
            statusMessage = "Saved edited copy to \(url.lastPathComponent). The original file was not modified."
        } catch {
            lastError = "Save failed: \(error)"
        }
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
    public func resolvedLevelPlacements(for scenery: SceneryAsset, node: ChunkNode) async -> [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)] {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: fileRoot)
            var results: [(worldPosition: SIMD3<Float>, asset: ResolvedModelAsset)] = []
            for placement in scenery.placements {
                guard let translation = placement.translation,
                      let rigidModel = index.rigidModels[placement.modelID],
                      let resolved = AssetResolver.resolveRigidModel(rigidModel, displayName: "Scenery Object #\(placement.modelID)", index: index)
                else { continue }
                results.append((translation, resolved))
            }
            return results
        }.value
    }

    /// "Visual Levels Hub" / "Direct .RM2 Write-Back" / "Level Editor
    /// Overhaul": the one call every entry point into the Level Viewer
    /// makes — resolves the scenery placements (see
    /// `resolvedLevelPlacements`) and gathers every Instance/Trigger/
    /// Camera/SoundEffect record from the same file for the scene-layer
    /// markers, audio panel, and events panel. Kept in one place so no
    /// entry point can drift into gathering different data for what's
    /// supposed to be the same view.
    public func openLevelViewer(for scenery: SceneryAsset, node: ChunkNode) async {
        let placements = await resolvedLevelPlacements(for: scenery, node: node)
        let instanceMarkers = instanceRecords(inSameFileAs: node)
        levelViewerContext = LevelViewerContext(
            scenery: scenery,
            placements: placements,
            instanceMarkers: instanceMarkers,
            resolvedInstanceAssets: await resolvedInstanceAssets(for: instanceMarkers, node: node),
            triggers: triggerRecords(inSameFileAs: node),
            cameras: cameraRecords(inSameFileAs: node),
            sounds: soundEffectRecords(inSameFileAs: node)
        )
    }

    /// "Comprehensive Instance Population" (Part 4B): resolves every
    /// `Instance.objectID` to real geometry where this build's decoded data
    /// allows it (`AssetResolver.resolveInstanceObject` — `GameObject` ->
    /// `GraphicsInfo` -> skinned mesh or rigid model-link parts), keyed by
    /// the `Instance` node's own identity so `LevelViewerRenderer` can look
    /// each one up directly. Missing from this dictionary is exactly the
    /// "no 3D model available" case `LevelViewerRenderer.upload` falls back
    /// to the colored placeholder marker for — this never fabricates a
    /// substitute for one that doesn't resolve.
    private func resolvedInstanceAssets(for instanceMarkers: [(node: ChunkNode, instance: PlacedInstance)], node: ChunkNode) async -> [UUID: ResolvedModelAsset] {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else { return [:] }
        return await Task.detached(priority: .userInitiated) {
            let index = AssetResolver.buildIndex(fileRoot: fileRoot)
            var results: [UUID: ResolvedModelAsset] = [:]
            for (markerNode, instance) in instanceMarkers {
                let selector = instance.unknownUInt32List2.first ?? 0
                guard let resolved = AssetResolver.resolveInstanceObject(objectID: instance.objectID, instanceSelector: selector, index: index) else { continue }
                results[markerNode.id] = resolved
            }
            return results
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
            try FileManager.default.createDirectory(at: assetFolder, withIntermediateDirectories: true)

            var exportedTextureNames: [UInt32: String] = [:]
            for material in asset.submeshMaterials {
                guard let textureID = material.textureID, let texture = material.texture, exportedTextureNames[textureID] == nil else { continue }
                let texName = "texture_\(textureID)"
                try TextureExporter.exportPNG(texture, to: assetFolder.appendingPathComponent(texName).appendingPathExtension("png"))
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
            try (mtlLines.joined(separator: "\n") + "\n").write(to: assetFolder.appendingPathComponent(mtlFileName), atomically: true, encoding: .utf8)

            let submeshMaterialIDs = asset.submeshMaterials.map(\.materialID)
            try OBJExporter.export(
                asset.mesh,
                submeshMaterialIDs: submeshMaterialIDs,
                mtlFileName: mtlFileName,
                to: assetFolder.appendingPathComponent("\(baseName).obj")
            )

            if !asset.availableAnimations.isEmpty {
                let animationsFolder = assetFolder.appendingPathComponent("animations")
                try FileManager.default.createDirectory(at: animationsFolder, withIntermediateDirectories: true)
                for animation in asset.availableAnimations {
                    let json = Self.animationJSON(animation)
                    try json.write(to: animationsFolder.appendingPathComponent("animation_\(animation.id).json"), atomically: true, encoding: .utf8)
                }
            }

            statusMessage = "Exported complete asset (\(seenMaterials.count) material(s), \(exportedTextureNames.count) texture(s), \(asset.availableAnimations.count) animation(s)) to \(assetFolder.path)."
        } catch {
            lastError = "Export failed: \(error)"
        }
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
