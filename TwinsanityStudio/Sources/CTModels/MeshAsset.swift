import Foundation
import simd

/// One decoded `SubModel`/rigid-skin submesh: a triangle strip of vertices plus
/// a per-vertex connectivity flag (`Conn`) that says whether this vertex extends
/// the strip from its two predecessors or starts a fresh strip.
public struct MeshSubmesh: Sendable {
    public var vertices: [StaticVertex]
    /// `connectivity[i] == true` means vertex `i` extends the strip from its
    /// two predecessors — i.e. vertices `(i-2, i-1, i)` form a real triangle;
    /// `false` means vertex `i` restarts the strip instead. See
    /// `triangleIndices()` for how this is read (the flag on the *apex*
    /// vertex, not the first vertex, of each candidate triangle).
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
    /// buffer or an OBJ `f` line. Winding-order swap ported from
    /// `Model.ToPLY`'s face-writing loop (`Twinsanity/Items/Graphics/
    /// Model.cs:339-345`): the strip alternates winding, so only the first
    /// two indices swap on odd `i`, and `i+2` is always the newest/apex vertex.
    ///
    /// Which vertex's `Conn` flag gates triangle `(i, i+1, i+2)` is where
    /// `ToPLY` disagrees with itself: its face-*counting* loop three lines
    /// above the one this was ported from tests `Vertexes[f+2].Conn`
    /// (`Model.cs:303`), not `Vertexes[f].Conn` — i.e. the header's face
    /// count and the actual emitted faces are computed from two different
    /// index conventions in the reference tool itself. `i+2` is also the
    /// only one of the two that makes sense as a strip-restart flag: a
    /// restart flag naturally belongs to the vertex that would need two
    /// predecessors to complete a triangle (the newest one), not to a
    /// vertex that's about to *start* a fresh strip. Using `connectivity[i]`
    /// here (as this used to) shows up as stray triangles bridging across
    /// every strip restart — vertices from unrelated parts of the mesh
    /// stitched together, which is exactly the crisscrossed/torn look a
    /// wrong texture would show even though the UVs themselves decode
    /// correctly.
    public func triangleIndices() -> [(Int, Int, Int)] {
        guard vertices.count >= 3 else { return [] }
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(vertices.count)
        for i in 0..<(vertices.count - 2) {
            let apex = i + 2
            guard apex < connectivity.count, connectivity[apex] else { continue }
            let odd = (i & 1) == 1
            let a = odd ? i + 1 : i
            let b = odd ? i : i + 1
            triangles.append((a, b, apex))
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
