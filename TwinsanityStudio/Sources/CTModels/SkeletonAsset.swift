import simd

/// A single skeleton joint. Note this is **matrix-based, not quaternion +
/// translation** — `matrix` holds 5 raw XYZW rows as stored on disk
/// (`GraphicsInfo.Joint.Matrix`, `Twinsanity/Items/Code/GraphicsInfo.cs:402-410`).
/// Interpreting those 5 rows into a usable 4x4 transform is left to the
/// animation/skinning layer, since the original tool never fully documents the
/// exact row semantics either (bind pose + something auxiliary per the parser's
/// own comments).
public struct Joint: Sendable, Identifiable, Codable {
    public var id: UInt32 { jointIndex }
    public var reactJointID: UInt32
    public var jointIndex: UInt32
    public var parentJointIndex: UInt32
    public var childJointAmount: UInt32
    public var childJointAmount2: UInt32
    public var matrix: [SIMD4<Float>] // 5 rows

    public init(reactJointID: UInt32, jointIndex: UInt32, parentJointIndex: UInt32, childJointAmount: UInt32, childJointAmount2: UInt32, matrix: [SIMD4<Float>]) {
        self.reactJointID = reactJointID
        self.jointIndex = jointIndex
        self.parentJointIndex = parentJointIndex
        self.childJointAmount = childJointAmount
        self.childJointAmount2 = childJointAmount2
        self.matrix = matrix
    }
}

public struct ExitPoint: Sendable, Identifiable, Codable {
    public var id: UInt32
    public var parentJointIndex: UInt32
    public var matrix: [SIMD4<Float>] // 4 rows

    public init(id: UInt32, parentJointIndex: UInt32, matrix: [SIMD4<Float>]) {
        self.id = id
        self.parentJointIndex = parentJointIndex
        self.matrix = matrix
    }
}

/// Column-major skinning transform per joint (`GraphicsInfo.SkinTransform`).
public struct SkinTransform: Sendable, Codable {
    public var matrix: [SIMD4<Float>] // 4 rows

    public init(matrix: [SIMD4<Float>]) {
        self.matrix = matrix
    }
}

public struct ModelLink: Sendable, Codable {
    public var jointIndex: UInt32
    public var modelID: UInt32

    public init(jointIndex: UInt32, modelID: UInt32) {
        self.jointIndex = jointIndex
        self.modelID = modelID
    }
}

/// "Collision Mask Alignment" — one `GI_CollisionData` entry
/// (`GraphicsInfo.cs`'s `GI_CollisionData`): a per-object collision blob,
/// keyed to this specific model/skeleton, not the level-wide `ColData`
/// mesh (`CollisionMesh`) — see that type's own doc comment for why those
/// two are unrelated. Ported only as far as the reference tool's *own*
/// code actually decodes it: the header's first count field selects a
/// block of raw `Vector4`s (`positions` here) from the blob; the
/// reference itself never further interprets the remaining 6 header-
/// addressed blocks, so this doesn't invent a meaning for them either —
/// `rawBlob` keeps the untouched bytes around (currently unused beyond
/// that first block) for anything built on this later.
public struct GraphicsInfoCollisionData: Sendable, Codable {
    /// The 11 `UInt16` header fields exactly as stored — element counts
    /// and byte offsets into `rawBlob` for 7 sub-blocks, only the first of
    /// which (`positions`) the reference tool's own code ever reads.
    public var header: [UInt16]
    /// Raw `Vector4`s from the blob's first sub-block (`header[0]` many) —
    /// real, decoded per-object coordinates; not confirmed to be
    /// positions-only vs. a mixed position/radius encoding, so no further
    /// semantic (e.g. "hull vertex") is claimed beyond "this many real
    /// vectors, in this order."
    public var positions: [SIMD4<Float>]

    public init(header: [UInt16], positions: [SIMD4<Float>]) {
        self.header = header
        self.positions = positions
    }
}

/// A fully decoded `GraphicsInfo` (OGI) record: bind-pose skeleton plus links to
/// the skin/blend-skin/model records it drives.
public struct SkeletonAsset: Sendable, Identifiable, Codable {
    public let id: UInt32
    public var joints: [Joint]
    public var exitPoints: [ExitPoint]
    public var skinTransforms: [SkinTransform]
    public var skinID: UInt32
    public var blendSkinID: UInt32
    public var modelLinks: [ModelLink]
    /// "Collision Mask Alignment" — every per-object `GI_CollisionData`
    /// entry this `GraphicsInfo` carries. Empty for the many objects that
    /// have none (`collisionDataCount == 0` on disk).
    public var collisionData: [GraphicsInfoCollisionData]

    public init(id: UInt32, joints: [Joint], exitPoints: [ExitPoint], skinTransforms: [SkinTransform], skinID: UInt32, blendSkinID: UInt32, modelLinks: [ModelLink], collisionData: [GraphicsInfoCollisionData] = []) {
        self.id = id
        self.joints = joints
        self.exitPoints = exitPoints
        self.skinTransforms = skinTransforms
        self.skinID = skinID
        self.blendSkinID = blendSkinID
        self.modelLinks = modelLinks
        self.collisionData = collisionData
    }

    /// Builds the parent/child joint tree, replicating
    /// `GraphicsInfo.BuildSkeleton` (`GraphicsInfo.cs:301-330`): joint 0 is
    /// always the root; every other joint attaches under whichever joint has a
    /// matching `jointIndex`, looked up by value (not array position).
    ///
    /// Groups every joint by its `parentJointIndex` once, up front, rather
    /// than re-filtering the full joint list once per node (the previous
    /// approach was O(joints²)). This matters because the hierarchy this
    /// builds is 100% invariant across animation frames — only each joint's
    /// *transform* changes frame to frame — yet `AnimationSkeletonBinding`
    /// calls `buildTree()` fresh multiple times per rendered frame during
    /// 30fps playback, so a quadratic rebuild here was real, repeated,
    /// avoidable work every single frame.
    public func buildTree() -> SkeletonTreeNode? {
        guard let rootJoint = joints.first else { return nil }

        var childrenByParentIndex: [UInt32: [Joint]] = [:]
        for joint in joints.dropFirst() {
            childrenByParentIndex[joint.parentJointIndex, default: []].append(joint)
        }

        // Guards against more than just a joint being its own direct
        // parent: a malformed/corrupt file could have a longer
        // `parentJointIndex` cycle (A's parent is B, B's parent is A),
        // which would otherwise recurse forever — same "don't let a
        // corrupt file crash the app via runaway indirection" reasoning as
        // `AssetResolver.resolveModelID`'s depth guard on `LodModel` chains.
        var visited: Set<UInt32> = [rootJoint.jointIndex]
        func build(_ joint: Joint) -> SkeletonTreeNode {
            let childJoints = (childrenByParentIndex[joint.jointIndex] ?? []).filter { !visited.contains($0.jointIndex) }
            for child in childJoints { visited.insert(child.jointIndex) }
            return SkeletonTreeNode(joint: joint, children: childJoints.map(build))
        }
        return build(rootJoint)
    }
}

/// Value-type joint tree node for SwiftUI `OutlineGroup`/skinning traversal.
public struct SkeletonTreeNode: Sendable, Identifiable {
    public var id: UInt32 { joint.jointIndex }
    public var joint: Joint
    public var children: [SkeletonTreeNode]
}
