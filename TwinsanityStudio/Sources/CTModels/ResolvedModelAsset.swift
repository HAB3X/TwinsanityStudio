import Foundation
import CTCore

/// ID-keyed lookup tables built from one parsed file's `Graphics`/`Code`
/// sections — the "linked asset resolution" step. On disk, a mesh, its
/// materials, its textures, and its skeleton are independent chunk records
/// that only reference each other by numeric ID (`RigidModel.meshID`,
/// `Material.shader.textureId`, `GraphicsInfo.skinID`, ...); nothing in the
/// chunk tree itself groups them into one logical asset. This index exists
/// so that grouping can happen once, in one place, instead of ad hoc ID
/// lookups scattered through UI code.
public struct GraphicsAssetIndex: Sendable {
    public var textures: [UInt32: TextureAsset] = [:]
    public var materials: [UInt32: MaterialInfo] = [:]
    /// Rigid (non-skinned) geometry, keyed by its record ID in the `Model` section.
    public var models: [UInt32: MeshAsset] = [:]
    /// Skinned geometry, keyed by its record ID in the `Skin` section.
    public var skins: [UInt32: MeshAsset] = [:]
    public var rigidModels: [UInt32: RigidModelInfo] = [:]
    public var skeletons: [UInt32: SkeletonAsset] = [:]
    public var animations: [UInt32: AnimationAsset] = [:]

    public init() {}
}

/// One submesh's resolved texture, if its material/texture chain resolved
/// successfully. Aligned index-for-index with `ResolvedModelAsset.mesh.submeshes`.
public struct ResolvedSubmeshMaterial: Sendable {
    public var materialID: UInt32?
    public var textureID: UInt32?
    public var texture: TextureAsset?

    public init(materialID: UInt32? = nil, textureID: UInt32? = nil, texture: TextureAsset? = nil) {
        self.materialID = materialID
        self.textureID = textureID
        self.texture = texture
    }
}

/// A mesh bound together with everything needed to actually render it: a
/// resolved texture per submesh, and — for rigged characters — the skeleton
/// and the animations available to preview against it. This is the single
/// logical asset the Model Viewer renders, replacing the "mesh here, texture
/// floating separately over there" experience of browsing raw chunk records.
public struct ResolvedModelAsset: Sendable, Identifiable {
    /// Synthesized, globally unique — deliberately *not* `recordID`.
    /// RigidModel IDs and Skeleton IDs are independent on-disk namespaces
    /// (a RigidModel and a Skeleton can legitimately share the same numeric
    /// ID), and a global list aggregating results from hundreds of files
    /// will see the same `recordID` recur constantly. Using `recordID`
    /// itself as `Identifiable.id` would make SwiftUI's list/sheet identity
    /// tracking silently collide across unrelated models.
    public let id = UUID()
    public let recordID: UInt32
    public var displayName: String
    public var mesh: MeshAsset
    public var submeshMaterials: [ResolvedSubmeshMaterial]
    public var skeleton: SkeletonAsset?
    public var availableAnimations: [AnimationAsset]

    public init(
        recordID: UInt32,
        displayName: String,
        mesh: MeshAsset,
        submeshMaterials: [ResolvedSubmeshMaterial],
        skeleton: SkeletonAsset? = nil,
        availableAnimations: [AnimationAsset] = []
    ) {
        self.recordID = recordID
        self.displayName = displayName
        self.mesh = mesh
        self.submeshMaterials = submeshMaterials
        self.skeleton = skeleton
        self.availableAnimations = availableAnimations
    }

    public var isFullyTextured: Bool { submeshMaterials.allSatisfy { $0.texture != nil } }
}

public enum AssetResolver {
    private static let graphicsSectionTypes: Set<SectionType> = [.graphics, .graphicsX, .graphicsD]
    private static let codeSectionTypes: Set<SectionType> = [.code, .codeX, .codeDemo]

    /// Builds a `GraphicsAssetIndex` from a parsed file's root node (the
    /// node representing a whole `.RM2`/`.SM2`, whose direct children
    /// include the top-level `Graphics` and `Code` sections).
    public static func buildIndex(fileRoot: ChunkNode) -> GraphicsAssetIndex {
        var index = GraphicsAssetIndex()

        if let graphics = fileRoot.children.first(where: { graphicsSectionTypes.contains($0.sectionType) }) {
            for section in graphics.children {
                for leaf in section.children {
                    guard let payload = leaf.payload else { continue }
                    switch payload {
                    case .texture(let texture):
                        index.textures[leaf.recordID] = texture
                    case .material(let material):
                        index.materials[leaf.recordID] = material
                    case .mesh(let mesh):
                        if mesh.isSkinned {
                            index.skins[leaf.recordID] = mesh
                        } else {
                            index.models[leaf.recordID] = mesh
                        }
                    case .rigidModel(let rigidModel):
                        index.rigidModels[leaf.recordID] = rigidModel
                    case .skeleton, .animation, .position, .instance, .trigger, .camera, .collision, .raw:
                        break
                    }
                }
            }
        }

        if let code = fileRoot.children.first(where: { codeSectionTypes.contains($0.sectionType) }) {
            if let ogi = code.children.first(where: { $0.sectionType == .ogi }) {
                for leaf in ogi.children {
                    if case .skeleton(let skeleton) = leaf.payload {
                        index.skeletons[leaf.recordID] = skeleton
                    }
                }
            }
            if let animationSection = code.children.first(where: { $0.sectionType == .animation }) {
                for leaf in animationSection.children {
                    if case .animation(let animation) = leaf.payload {
                        index.animations[leaf.recordID] = animation
                    }
                }
            }
        }

        return index
    }

    /// Resolves a static/rigid `RigidModel` into a fully textured mesh:
    /// geometry via `meshID`, and per-submesh textures via
    /// `materialIDs[i]` — `RigidModel.materialIDs` and the mesh's submeshes
    /// are parallel arrays (same index order), matching how the original
    /// engine associates them (`RigidModel.cs`).
    public static func resolveRigidModel(_ rigidModel: RigidModelInfo, displayName: String, index: GraphicsAssetIndex) -> ResolvedModelAsset? {
        guard let mesh = index.models[rigidModel.meshID] else { return nil }
        var materials: [ResolvedSubmeshMaterial] = []
        materials.reserveCapacity(mesh.submeshes.count)
        for i in mesh.submeshes.indices {
            guard i < rigidModel.materialIDs.count else {
                materials.append(ResolvedSubmeshMaterial())
                continue
            }
            let materialID = rigidModel.materialIDs[i]
            let textureID = index.materials[materialID]?.primaryTextureID
            let texture = textureID.flatMap { index.textures[$0] }
            materials.append(ResolvedSubmeshMaterial(materialID: materialID, textureID: textureID, texture: texture))
        }
        return ResolvedModelAsset(recordID: rigidModel.id, displayName: displayName, mesh: mesh, submeshMaterials: materials)
    }

    /// Resolves a rigged character via its `GraphicsInfo` skeleton:
    /// geometry via `skinID`. Unlike `RigidModel`, a `Skin` record carries
    /// its material ID *per submesh* directly (already decoded onto
    /// `MeshSubmesh.materialID` by `SkinParser`), so no parallel array
    /// lookup is needed here. Every decoded `Animation` in the same file's
    /// `Code` section is offered as a preview candidate — the format has no
    /// stored link from a specific animation to a specific skeleton (that
    /// association lives in the undecoded `Object`/`Script` game-logic
    /// layer), so "same file" is the best available heuristic.
    public static func resolveSkeleton(_ skeleton: SkeletonAsset, displayName: String, index: GraphicsAssetIndex) -> ResolvedModelAsset? {
        guard let mesh = index.skins[skeleton.skinID] else { return nil }
        let materials = mesh.submeshes.map { submesh -> ResolvedSubmeshMaterial in
            guard let materialID = submesh.materialID else { return ResolvedSubmeshMaterial() }
            let textureID = index.materials[materialID]?.primaryTextureID
            let texture = textureID.flatMap { index.textures[$0] }
            return ResolvedSubmeshMaterial(materialID: materialID, textureID: textureID, texture: texture)
        }
        let animations = Array(index.animations.values)
        return ResolvedModelAsset(recordID: skeleton.id, displayName: displayName, mesh: mesh, submeshMaterials: materials, skeleton: skeleton, availableAnimations: animations)
    }

    /// Resolves *any* composite-eligible node — not just a `RigidModel`/
    /// `GraphicsInfo` link record itself, but any of the components it's
    /// built from (a raw `Model`/`Skin` mesh, a `Material`, a `Texture`, or
    /// an `Animation`) — into the same complete `ResolvedModelAsset` its
    /// parent resolves to. This is what makes "select an isolated texture,
    /// see the whole character it belongs to" possible: rather than a
    /// texture knowing its own parent, this walks the same index every
    /// other resolution path already builds and asks "what points at me?"
    ///
    /// `nil` means either this node's `payload` kind was never linkable
    /// (e.g. a `Position`/`Trigger`) or nothing in this file's Graphics/Code
    /// sections currently references it — the latter is exactly what the
    /// Scrapped Content Scanner (`scanForOrphans`) flags separately.
    public static func resolveComposite(for node: ChunkNode, fileRoot: ChunkNode, displayNamePrefix: String) -> ResolvedModelAsset? {
        let index = buildIndex(fileRoot: fileRoot)

        switch node.payload {
        case .rigidModel(let rigidModel):
            return resolveRigidModel(rigidModel, displayName: displayNamePrefix + node.displayName, index: index)

        case .skeleton(let skeleton):
            return resolveSkeleton(skeleton, displayName: displayNamePrefix + node.displayName, index: index)

        case .mesh:
            // A raw `Model`/`Skin` geometry record: found by which link
            // record's meshID/skinID points at it, not by its own ID.
            if let rigidModel = index.rigidModels.values.first(where: { $0.meshID == node.recordID }) {
                return resolveRigidModel(rigidModel, displayName: displayNamePrefix + "Object #\(rigidModel.id)", index: index)
            }
            if let skeleton = index.skeletons.values.first(where: { $0.skinID == node.recordID }) {
                return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)
            }
            return nil

        case .texture, .material:
            let materialID: UInt32?
            if case .texture = node.payload {
                materialID = index.materials.first(where: { $0.value.primaryTextureID == node.recordID })?.key
            } else {
                materialID = node.recordID
            }
            guard let materialID else { return nil }
            if let rigidModel = index.rigidModels.values.first(where: { $0.materialIDs.contains(materialID) }) {
                return resolveRigidModel(rigidModel, displayName: displayNamePrefix + "Object #\(rigidModel.id)", index: index)
            }
            if let skinEntry = index.skins.first(where: { $0.value.submeshes.contains { $0.materialID == materialID } }),
               let skeleton = index.skeletons.values.first(where: { $0.skinID == skinEntry.key }) {
                return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)
            }
            return nil

        case .animation:
            // No stored link from an animation to a specific skeleton (see
            // `resolveSkeleton`'s doc comment) — "the first skeleton in the
            // same file" is the same heuristic used to offer animations as
            // preview candidates in the first place.
            guard let skeleton = index.skeletons.values.first else { return nil }
            return resolveSkeleton(skeleton, displayName: displayNamePrefix + "Character #\(skeleton.id)", index: index)

        default:
            return nil
        }
    }
}
