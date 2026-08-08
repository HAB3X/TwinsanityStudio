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

    public init(id: UInt32, joints: [Joint], exitPoints: [ExitPoint], skinTransforms: [SkinTransform], skinID: UInt32, blendSkinID: UInt32, modelLinks: [ModelLink]) {
        self.id = id
        self.joints = joints
        self.exitPoints = exitPoints
        self.skinTransforms = skinTransforms
        self.skinID = skinID
        self.blendSkinID = blendSkinID
        self.modelLinks = modelLinks
    }

    /// Builds the parent/child joint tree, replicating
    /// `GraphicsInfo.BuildSkeleton` (`GraphicsInfo.cs:301-330`): joint 0 is
    /// always the root; every other joint attaches under whichever joint has a
    /// matching `jointIndex`, looked up by value (not array position).
    public func buildTree() -> SkeletonTreeNode? {
        guard let rootJoint = joints.first else { return nil }
        var nodesByIndex: [UInt32: SkeletonTreeNode] = [:]
        var root = SkeletonTreeNode(joint: rootJoint, children: [])
        nodesByIndex[rootJoint.jointIndex] = root

        // Two-pass build: first create every node, then link parent -> children,
        // since Swift value-type trees can't be mutated "in place" through a
        // dictionary of structs the way the C# reference-type version can.
        for joint in joints.dropFirst() {
            nodesByIndex[joint.jointIndex] = SkeletonTreeNode(joint: joint, children: [])
        }

        func attach(_ node: inout SkeletonTreeNode) {
            node.children = joints
                .filter { $0.parentJointIndex == node.joint.jointIndex && $0.jointIndex != node.joint.jointIndex }
                .compactMap { nodesByIndex[$0.jointIndex] }
            for i in node.children.indices {
                attach(&node.children[i])
            }
        }
        attach(&root)
        return root
    }
}

/// Value-type joint tree node for SwiftUI `OutlineGroup`/skinning traversal.
public struct SkeletonTreeNode: Sendable, Identifiable {
    public var id: UInt32 { joint.jointIndex }
    public var joint: Joint
    public var children: [SkeletonTreeNode]
}
