import Foundation
import CTCore

/// Decoded payload attached to a leaf `ChunkNode`, when the parser understands
/// that record's contents. Sections (which only hold child records) carry `nil`.
public enum ChunkPayload: Sendable {
    case texture(TextureAsset)
    case mesh(MeshAsset)
    case rigidModel(RigidModelInfo)
    case skeleton(SkeletonAsset)
    case animation(AnimationAsset)
    /// Understood record kind, but not (yet) decoded into a typed model —
    /// still browsable/exportable as a hex/raw blob.
    case raw(byteCount: Int)
}

/// A node in the RM2/SM2 chunk tree, used directly by the sidebar's
/// `OutlineGroup` and by the search/filter model. Reference type: these trees
/// can have thousands of nodes for a full level, and SwiftUI's `OutlineGroup`
/// performs far better walking identity-stable class instances than diffing
/// deeply nested value-type arrays on every render.
public final class ChunkNode: Identifiable {
    public let id = UUID()
    public var recordID: UInt32
    public var sectionType: SectionType
    public var displayName: String
    public var byteSize: Int
    public var children: [ChunkNode]
    public var payload: ChunkPayload?
    /// Absolute byte offset of this record's data in the originating file, kept
    /// for the inspector's "jump to hex" affordance and for re-injection.
    public var fileOffset: Int

    public init(
        recordID: UInt32,
        sectionType: SectionType,
        displayName: String,
        byteSize: Int,
        fileOffset: Int,
        children: [ChunkNode] = [],
        payload: ChunkPayload? = nil
    ) {
        self.recordID = recordID
        self.sectionType = sectionType
        self.displayName = displayName
        self.byteSize = byteSize
        self.fileOffset = fileOffset
        self.children = children
        self.payload = payload
    }

    public var isLeaf: Bool { children.isEmpty }

    /// Depth-first search across this node and its descendants for nodes whose
    /// display name or section type contains `query` (case-insensitive).
    public func filtered(matching query: String) -> ChunkNode? {
        guard !query.isEmpty else { return self }
        let matchesSelf = displayName.localizedCaseInsensitiveContains(query)
            || sectionType.rawValue.localizedCaseInsensitiveContains(query)
            || String(recordID).contains(query)
        let matchingChildren = children.compactMap { $0.filtered(matching: query) }
        guard matchesSelf || !matchingChildren.isEmpty else { return nil }
        let node = ChunkNode(
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: matchesSelf ? children : matchingChildren,
            payload: payload
        )
        return node
    }
}
