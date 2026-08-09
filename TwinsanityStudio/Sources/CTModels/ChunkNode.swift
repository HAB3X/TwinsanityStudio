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
    case scenery(SceneryAsset)
    case dynamicScenery(DynamicSceneryAsset)
    case soundEffect(SoundEffectAsset)
    /// A `GameObject` record — see `GameObjectInfo`'s own doc comment.
    /// Plumbing (`Instance.objectID` -> this -> a `GraphicsInfo`/mesh),
    /// same reasoning as `.material` below, not a filterable kind of its
    /// own.
    case gameObject(GameObjectInfo)
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
        case soundEffect = "Audio"
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
        case .soundEffect: return .soundEffect
        case .material, .position, .scenery, .dynamicScenery, .gameObject, .raw: return nil
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
    /// Was `let id = UUID()` (always freshly minted) — see `filtered(matching:)`/
    /// `filtered(byKind:)`'s doc comments for why that was a real, user-facing
    /// bug: it's now a settable-at-init identity so a filtered *view* of an
    /// existing node can preserve that node's real identity instead of
    /// inventing a new one every time the filter re-runs.
    public let id: UUID
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
        id: UUID = UUID(),
        recordID: UInt32,
        sectionType: SectionType,
        displayName: String,
        byteSize: Int,
        fileOffset: Int,
        children: [ChunkNode] = [],
        payload: ChunkPayload? = nil
    ) {
        self.id = id
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
    ///
    /// Returns a *view* over the matching subset, not a copy with a new
    /// identity — critically, `id: self.id` below. This used to omit `id:`,
    /// which let the synthesized `ChunkNode(id: UUID())` default mint a
    /// fresh random UUID for every filtered node, on every single
    /// evaluation of this (uncached, computed-property-backed) filter. In
    /// the sidebar, clicking a filtered row round-trips through exactly two
    /// separate evaluations of `filteredRootNodes` (once to tag the row
    /// when the `List` renders, once again inside the selection
    /// `Binding`'s `set` to look the clicked id back up) — with fresh IDs
    /// each time, the id captured by the click could never match anything
    /// in the freshly-recomputed tree, `findNode` always returned `nil`,
    /// and `select(nil)` silently wiped the entire selection. Every click
    /// on a filtered item looked like it "closed all the files." Preserving
    /// the real underlying node's `id` here makes a filtered node's
    /// identity stable across every re-evaluation, exactly like the
    /// unfiltered tree's already was.
    public func filtered(matching query: String) -> ChunkNode? {
        guard !query.isEmpty else { return self }
        let matchesSelf = displayName.localizedCaseInsensitiveContains(query)
            || sectionType.rawValue.localizedCaseInsensitiveContains(query)
            || String(recordID).contains(query)
        let matchingChildren = children.compactMap { $0.filtered(matching: query) }
        guard matchesSelf || !matchingChildren.isEmpty else { return nil }
        let node = ChunkNode(
            id: id,
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
    /// See `filtered(matching:)`'s doc comment — `id: self.id` here fixes
    /// the exact same identity bug for the type-filter picker.
    public func filtered(byKind kind: ChunkPayload.Kind) -> ChunkNode? {
        let matchesSelf = payload?.kind == kind
        let matchingChildren = children.compactMap { $0.filtered(byKind: kind) }
        guard matchesSelf || !matchingChildren.isEmpty else { return nil }
        return ChunkNode(
            id: id,
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: matchesSelf ? children : matchingChildren,
            payload: payload
        )
    }

    /// "Smart File Filtering": recursively drops undecoded/raw leaves
    /// (payload `.none`/`.raw`) and any container whose entire subtree
    /// pruned away — the "hide folders that only contain raw files" half of
    /// the same feature. `nil` means "this whole node is uninteresting,
    /// drop it"; a non-`nil` result always preserves `id: self.id` on every
    /// surviving node, same reasoning as `filtered(matching:)`'s own doc
    /// comment: a filtered *view* must keep the real node's identity, or
    /// sidebar selection breaks exactly like it did before that fix.
    public func prunedOfRawContent() -> ChunkNode? {
        guard !children.isEmpty else {
            // An unexpanded archive entry (`.RM2`/`.SM2`/etc. sitting inside
            // a `.BH` archive, not yet parsed) looks identical to a genuinely
            // uninteresting leaf at this point — no children, `payload ==
            // nil` — but it's the exact opposite: it's a real file the user
            // can still click "Parse" on (see `WorkspaceViewModel.
            // isExpandableArchiveEntry`), and every archive starts with
            // hundreds of these before scanning finishes. Pruning it away
            // would hide the entire unscanned tree, not just raw junk.
            if payload == nil, byteSize > 0, Self.looksLikeChunkFileName(displayName) {
                return self
            }
            switch payload {
            case .none, .raw: return nil
            default: return self
            }
        }
        let keptChildren = children.compactMap { $0.prunedOfRawContent() }
        guard !keptChildren.isEmpty else { return nil }
        return ChunkNode(
            id: id,
            recordID: recordID,
            sectionType: sectionType,
            displayName: displayName,
            byteSize: byteSize,
            fileOffset: fileOffset,
            children: keptChildren,
            payload: payload
        )
    }

    /// Same "does this filename look like a chunk file" check
    /// `WorkspaceViewModel`/`WorkspaceAutoDetector` each already make their
    /// own way (extension-based, no magic-number peek needed at this
    /// layer) — small enough, and different enough in what each caller
    /// already has on hand, that sharing one implementation across module
    /// boundaries wasn't worth it; this one only needs a display name.
    private static func looksLikeChunkFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.uppercased()
        return ["RM2", "SM2", "RMX", "SMX"].contains(ext)
    }
}
