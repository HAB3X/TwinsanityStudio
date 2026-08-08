import Foundation
import CTModels

public enum OBJExportError: Error, CustomStringConvertible {
    case emptyMesh
    public var description: String { "Mesh has no vertex data to export." }
}

/// Exports a decoded ``MeshAsset`` to Wavefront OBJ. Each submesh becomes its
/// own `o` group; positions/UVs/normals are written 1:1 with the decoded
/// vertex order, and faces use the same triangle-strip winding as
/// ``MeshSubmesh/triangleIndices()`` (which itself mirrors the reference
/// tool's `Model.ToPLY`), so exported geometry visually matches the original
/// tool's output.
public enum OBJExporter {
    /// - Parameters:
    ///   - submeshMaterialIDs: Explicit per-submesh material IDs, aligned by
    ///     index with `mesh.submeshes`. Needed for rigid (`Model`-based)
    ///     meshes, whose per-submesh material comes from the *separate*
    ///     `RigidModel.materialIDs` array rather than being stored on the
    ///     submesh itself (only `Skin` submeshes carry their own
    ///     `materialID` — see `MeshSubmesh`). When `nil`, falls back to each
    ///     submesh's own `materialID`, matching the previous behavior.
    ///   - mtlFileName: If given, writes an `mtllib` header line so the OBJ
    ///     links to a sibling `.mtl` file (see `WorkspaceViewModel.exportCompleteAsset`).
    @discardableResult
    public static func export(
        _ mesh: MeshAsset,
        submeshMaterialIDs: [UInt32?]? = nil,
        mtlFileName: String? = nil,
        to url: URL
    ) throws -> URL {
        guard mesh.totalVertexCount > 0 else { throw OBJExportError.emptyMesh }

        var lines: [String] = [
            "# Exported by TwinsanityStudio",
            "# Mesh record #\(mesh.id)\(mesh.isSkinned ? " (skinned)" : "")"
        ]
        if let mtlFileName {
            lines.append("mtllib \(mtlFileName)")
        }
        var vertexOffset = 0

        for (subIndex, sub) in mesh.submeshes.enumerated() {
            guard !sub.vertices.isEmpty else { continue }
            lines.append("o Submesh_\(subIndex)")
            let resolvedMaterialID = (submeshMaterialIDs.flatMap { subIndex < $0.count ? $0[subIndex] : nil }) ?? sub.materialID
            if let resolvedMaterialID {
                lines.append("usemtl material_\(resolvedMaterialID)")
            }
            for v in sub.vertices {
                lines.append("v \(format(v.position.x)) \(format(v.position.y)) \(format(v.position.z))")
            }
            for v in sub.vertices {
                lines.append("vt \(format(v.uv.x)) \(format(v.uv.y))")
            }
            for v in sub.vertices {
                lines.append("vn \(format(v.normal.x)) \(format(v.normal.y)) \(format(v.normal.z))")
            }
            for (a, b, c) in sub.triangleIndices() {
                let ia = a + vertexOffset + 1
                let ib = b + vertexOffset + 1
                let ic = c + vertexOffset + 1
                lines.append("f \(ia)/\(ia)/\(ia) \(ib)/\(ib)/\(ib) \(ic)/\(ic)/\(ic)")
            }
            vertexOffset += sub.vertices.count
        }

        let contents = lines.joined(separator: "\n") + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func format(_ v: Float) -> String {
        String(format: "%.6f", v)
    }
}
