import Foundation
import CTCore
import CTModels
import CTParsers
import CTExport

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
    @Published public var selectedNode: ChunkNode?
    @Published public var statusMessage: String = "Drop a .BH/.BD archive, .RM2/.SM2 file, or a folder to begin."
    @Published public var isLoading = false
    @Published public var isScanning = false
    @Published public var lastError: String?
    /// Non-nil presents the Model Viewer sheet (see `ContentView`).
    @Published public var modelViewerAsset: ResolvedModelAsset?

    private var archiveIndexByRootID: [UUID: ArchiveIndex] = [:]

    public init() {}

    /// The tree the sidebar actually renders: `rootNodes` narrowed by the
    /// type filter (see `ChunkNode.filtered(byKind:)`) and then by the
    /// search text (see `ChunkNode.filtered(matching:)`), each pass keeping
    /// ancestors of any match so the result stays a navigable tree.
    public var filteredRootNodes: [ChunkNode] {
        var nodes = rootNodes
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
            for file in detected { load(file) }
            return
        }
        load(WorkspaceAutoDetector.detect(url: url))
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
                statusMessage = "Loaded \(file.url.lastPathComponent) — \(index.entries.count) entries."

            case .levelResource, .sceneryResource:
                let data = try Data(contentsOf: file.url)
                let node = try RM2Parser.parse(data: data, fileKind: fileKind(for: file), fileName: file.url.lastPathComponent)
                rootNodes.append(node)
                statusMessage = "Loaded \(file.url.lastPathComponent) — \(node.children.count) top-level chunks."

            case .archiveData:
                statusMessage = "Drop the matching .BH file to browse \(file.url.lastPathComponent) (a .BD alone has no index)."

            case .folder, .unknown:
                break
            }
        } catch {
            lastError = "\(file.url.lastPathComponent): \(error)"
        }
    }

    private func fileKind(for file: DetectedFile) -> TwinsFileKind {
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
    /// Runs off the main thread since a full archive (hundreds of files) can
    /// take tens of seconds; the UI stays responsive and `isScanning` drives
    /// a progress indicator instead of freezing during the scan.
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resultsByRoot: [UUID: [String: ChunkNode]] = [:]
            for (rootID, index) in targets {
                var parsedByName: [String: ChunkNode] = [:]
                for entry in index.entries where Self.isChunkFileName(entry.name) {
                    guard let data = try? BDArchiveParser.readEntryData(entry, index: index) else { continue }
                    let kind = Self.fileKind(forEntryNamed: entry.name)
                    guard let parsed = try? RM2Parser.parse(data: data, fileKind: kind, fileName: entry.name) else { continue }
                    parsedByName[entry.name] = parsed
                }
                resultsByRoot[rootID] = parsedByName
            }
            DispatchQueue.main.async {
                self?.applyBulkScan(resultsByRoot)
            }
        }
    }

    private func applyBulkScan(_ resultsByRoot: [UUID: [String: ChunkNode]]) {
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
        statusMessage = failedCount == 0
            ? "Scan complete — parsed \(parsedCount) level file(s). Use the type filter to browse by asset kind."
            : "Scan complete — parsed \(parsedCount) level file(s), \(failedCount) failed to parse."
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
        selectedNode = node
        guard let node, isExpandableArchiveEntry(node) else { return }
        guard let rootID = owningArchiveRootID(of: node) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.expandArchiveEntry(node, rootID: rootID)
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

    // MARK: - Linked asset resolution / Model Viewer

    /// Resolves `node` (a `RigidModel` or a `GraphicsInfo` skeleton) into a
    /// fully textured `ResolvedModelAsset` and opens the Model Viewer on it.
    /// This is the fix for "the model and its textures show up as separate,
    /// unrelated files": it cross-references the node's enclosing file's
    /// Graphics/Code sections (mesh, material, texture, skeleton records)
    /// instead of treating them as independent chunks.
    public func openModelViewer(for node: ChunkNode) {
        guard let fileRoot = findFileRoot(containing: node, in: rootNodes) else {
            lastError = "Couldn't find the file this record belongs to."
            return
        }
        let index = AssetResolver.buildIndex(fileRoot: fileRoot)
        let displayName = "\(fileRoot.displayName) — \(node.displayName)"

        let resolved: ResolvedModelAsset?
        switch node.payload {
        case .rigidModel(let rigidModel):
            resolved = AssetResolver.resolveRigidModel(rigidModel, displayName: displayName, index: index)
        case .skeleton(let skeleton):
            resolved = AssetResolver.resolveSkeleton(skeleton, displayName: displayName, index: index)
        default:
            resolved = nil
        }

        guard let resolved else {
            lastError = "Couldn't resolve this model — its referenced mesh ID wasn't found in this file's Graphics section."
            return
        }
        modelViewerAsset = resolved
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
}
