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
    @Published public var selectedNode: ChunkNode?
    @Published public var statusMessage: String = "Drop a .BH/.BD archive, .RM2/.SM2 file, or a folder to begin."
    @Published public var isLoading = false
    @Published public var lastError: String?

    private var archiveIndexByRootID: [UUID: ArchiveIndex] = [:]

    public init() {}

    /// The tree the sidebar actually renders: unfiltered when there's no
    /// search query, otherwise a freshly pruned copy (see
    /// `ChunkNode.filtered(matching:)`) containing only matching nodes and
    /// their ancestors.
    public var filteredRootNodes: [ChunkNode] {
        guard !searchQuery.isEmpty else { return rootNodes }
        return rootNodes.compactMap { $0.filtered(matching: searchQuery) }
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
        let ext = (node.displayName as NSString).pathExtension.uppercased()
        return ["RM2", "SM2", "RMX", "SMX"].contains(ext)
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
    /// chunk tree in place, so levels packed inside a master archive are
    /// browsable without a separate manual extract step.
    public func expandArchiveEntry(_ node: ChunkNode, rootID: UUID) {
        guard let index = archiveIndexByRootID[rootID] else { return }
        guard let entry = index.entries.first(where: { $0.name == node.displayName }) else { return }
        let ext = (entry.name as NSString).pathExtension.uppercased()
        let kind: TwinsFileKind = (ext == "RMX") ? .rmx : (ext == "SMX") ? .smx : (ext == "SM2") ? .sm2 : .rm2

        isLoading = true
        defer { isLoading = false }
        do {
            let data = try BDArchiveParser.readEntryData(entry, index: index)
            let parsed = try RM2Parser.parse(data: data, fileKind: kind, fileName: entry.name)
            node.sectionType = parsed.sectionType
            node.children = parsed.children
            node.payload = parsed.payload
            // Belt-and-suspenders: `node` is a nested reference type inside
            // `rootNodes`, so mutating it in place doesn't itself satisfy
            // `@Published`'s change detection. `objectWillChange.send()`
            // covers observers of the view model directly; reassigning
            // `rootNodes` to itself additionally forces any diffing keyed on
            // that array (List/OutlineGroup's data source) to re-derive from
            // the mutated tree rather than relying on it noticing nested
            // mutations on its own.
            objectWillChange.send()
            rootNodes = rootNodes
        } catch {
            lastError = "\(entry.name): \(error)"
        }
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
