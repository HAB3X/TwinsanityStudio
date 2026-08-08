import Foundation
import CTCore

/// Decoded payload attached to a leaf `ChunkNode`, when the parser understands
/// that record's contents. Sections (which only hold child records) carry `nil`.
public enum ChunkPayload: Sendable {
    case texture(TextureAsset)
    case mesh(MeshAsset)
    case rigidModel(RigidModelInfo)
    case material(MaterialInfo)
    case skeleton(SkeletonAsset)
    case animation(AnimationAsset)
    case position(PositionMarker)
    case instance(PlacedInstance)
    case trigger(TriggerVolume)
    case camera(PlacedCamera)
    case collision(CollisionMesh)
    /// Understood record kind, but not (yet) decoded into a typed model —
    /// still browsable/exportable as a hex/raw blob.
    case raw(byteCount: Int)

    /// Coarse category used for type-based filtering (e.g. "show me every
    /// animation in the archive") — distinct from `SectionType`, which
    /// distinguishes many more format-level record kinds than a user
    /// browsing by *asset kind* cares about. Materials are deliberately not
    /// a filterable kind of their own — they're plumbing (mesh -> material
    /// -> texture), not something a user browses for directly.
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case texture = "Textures"
        case model = "Models"
        case skeleton = "Skeletons"
        case animation = "Animations"
        case instance = "Entities"
        case trigger = "Triggers"
        case camera = "Cameras"
        case collision = "Collision"
        public var id: String { rawValue }
    }

    public var kind: Kind? {
        switch self {
        case .texture: return .texture
        case .mesh, .rigidModel: return .model
        case .skeleton: return .skeleton
        case .animation: return .animation
        case .instance: return .instance
        case .trigger: return .trigger
        case .camera: return .camera
        case .collision: return .collision
        case .material, .position, .raw: return nil
        }
    }
}

/// A node in the RM2/SM2 chunk tree, used directly by the sidebar's
/// `OutlineGroup` and by the search/filter model. Reference type: these trees
/// can have thousands of nodes for a full level, and SwiftUI's `OutlineGroup`
/// performs far better walking identity-stable class instances than diffing
/// deeply nested value-type arrays on every render.
///
/// `@unchecked Sendable`: a tree is built single-threaded inside one parse
/// call (see `RM2Parser`/`WorkspaceViewModel.scanAllArchives`'s parse
/// task), never mutated concurrently from more than one task while being
/// built, and is only handed across a task/actor boundary once construction
/// finishes — at which point it behaves like an immutable value from the
/// receiver's perspective (later in-place edits, e.g. `expandArchiveEntry`,
/// only ever happen back on the main actor). The compiler can't verify that
/// discipline for a reference type, so it's asserted here rather than
/// inferred.
public final class ChunkNode: Identifiable, @unchecked Sendable {
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

    /// Depth-first search across this node and its descendants for nodes
    /// whose decoded payload matches `kind` (e.g. every `Animation` record
    /// anywhere under this node, no matter how deep). Ancestors of a match
    /// are kept so the result is still a navigable tree, not a flat list.
    public func filtered(byKind kind: ChunkPayload.Kind) -> ChunkNode? {
        let matchesSelf = payload?.kind == kind
        let matchingChildren = children.compactMap { $0.filtered(byKind: kind) }
        guard matchesSelf || !matchingChildren.isEmpty else { return nil }
        return ChunkNode(
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: matchesSelf ? children : matchingChildren,
            payload: payload
        )
    }
}
