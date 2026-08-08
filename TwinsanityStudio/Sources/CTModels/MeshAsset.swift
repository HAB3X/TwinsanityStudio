import Foundation
import simd

/// One decoded `SubModel`/rigid-skin submesh: a triangle strip of vertices plus
/// a per-vertex connectivity flag (`Conn`) that says whether this vertex extends
/// the strip from its two predecessors or starts a fresh strip.
public struct MeshSubmesh: Sendable {
    public var vertices: [StaticVertex]
    /// `connectivity[i] == true` means vertices `(i, i+1, i+2)` (with the
    /// winding-order swap below) form a real triangle; `false` breaks the strip.
    public var connectivity: [Bool]
    public var materialID: UInt32?
    /// Per-vertex joint influences, populated only for `Skin` submeshes
    /// (parallel to `vertices`; empty for rigid `Model` submeshes). Up to 3
    /// active joints per vertex, padded to 4 lanes for a clean GPU attribute.
    public var jointIndices: [SIMD4<UInt16>]
    public var jointWeights: [SIMD4<Float>]

    public init(
        vertices: [StaticVertex],
        connectivity: [Bool],
        materialID: UInt32? = nil,
        jointIndices: [SIMD4<UInt16>] = [],
        jointWeights: [SIMD4<Float>] = []
    ) {
        self.vertices = vertices
        self.connectivity = connectivity
        self.materialID = materialID
        self.jointIndices = jointIndices
        self.jointWeights = jointWeights
    }

    public var isSkinned: Bool { !jointWeights.isEmpty }

    /// Triangle index list (into `vertices`), ready for an `MTLBuffer` index
    /// buffer or an OBJ `f` line. Ported from `Model.ToPLY`
    /// (`Twinsanity/Items/Graphics/Model.cs:339-345`): despite the strip having
    /// alternating winding in principle, the original exporter only swaps the
    /// first two indices on odd `i` and always takes `i+2` as the apex — we
    /// replicate that exactly rather than "fixing" it, since the goal is visual
    /// parity with the reference tool's output.
    public func triangleIndices() -> [(Int, Int, Int)] {
        guard vertices.count >= 3 else { return [] }
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(vertices.count)
        for i in 0..<(vertices.count - 2) {
            guard i < connectivity.count, connectivity[i] else { continue }
            let odd = (i & 1) == 1
            let a = odd ? i + 1 : i
            let b = odd ? i : i + 1
            let c = i + 2
            triangles.append((a, b, c))
        }
        return triangles
    }
}

/// A fully decoded `Model` (rigid) or `Skin` (skinned) geometry record.
public struct MeshAsset: Sendable, Identifiable {
    public let id: UInt32
    public var isSkinned: Bool
    public var submeshes: [MeshSubmesh]

    public init(id: UInt32, isSkinned: Bool, submeshes: [MeshSubmesh]) {
        self.id = id
        self.isSkinned = isSkinned
        self.submeshes = submeshes
    }

    public var totalVertexCount: Int { submeshes.reduce(0) { $0 + $1.vertices.count } }
    public var totalTriangleCount: Int { submeshes.reduce(0) { $0 + $1.triangleIndices().count } }
}

/// Decoded `RigidModel` record: links a set of materials and a `Mesh`/`Model`
/// record together (`Twinsanity/Items/Graphics/RigidModel.cs`).
public struct RigidModelInfo: Sendable {
    public let id: UInt32
    public var header: UInt32
    public var materialIDs: [UInt32]
    public var meshID: UInt32

    public init(id: UInt32, header: UInt32, materialIDs: [UInt32], meshID: UInt32) {
        self.id = id
        self.header = header
        self.materialIDs = materialIDs
        self.meshID = meshID
    }
}
