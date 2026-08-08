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
    /// chunk file (`.RM2`/`.SM2`/`.RMX`/`.SMX`) — the sidebar shows a "Parse"
    /// affordance for these instead of a byte-size-only leaf.
    public func isExpandableArchiveEntry(_ node: ChunkNode) -> Bool {
        guard node.children.isEmpty, node.payload == nil else { return false }
        let ext = (node.displayName as NSString).pathExtension.uppercased()
        return ["RM2", "SM2", "RMX", "SMX"].contains(ext)
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
            objectWillChange.send()
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
