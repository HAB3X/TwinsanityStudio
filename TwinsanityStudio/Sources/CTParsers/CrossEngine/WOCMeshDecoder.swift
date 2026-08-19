import Foundation
import simd
import CTModels

/// Builds a real, renderable `MeshAsset` from `OBJ0`'s decoded arcs (see
/// `WOCContainerParser.OBJ0Arc`'s doc comment for the confirmed byte
/// layout this is built on). One `OBJ0` top-level entry -> one
/// `MeshAsset`, one `OBJ0Chunk` within that entry -> one `MeshSubmesh`.
///
/// Reuses `MeshSubmesh.connectivity`/`triangleIndices()` -- the exact
/// same triangle-strip-with-restarts representation `ModelParser`/
/// `SkinParser` already use for original Twinsanity meshes -- rather
/// than inventing a WoC-specific connectivity scheme, since the
/// underlying convention is the same: a vertex's own control word's
/// second byte is `0x80` when it restarts the strip (confirmed on
/// `AIRSHIP.GSC`/`FARM.GSC`/`DROID.GSC`: exactly the first 3 vertices of
/// every real arc, plus occasional later restarts consistent with a
/// normal strip-with-breaks encoding), `0x00` otherwise -- matching
/// `ModelParser.swift`'s own `connRaw != 128` rule exactly.
///
/// **What this does NOT claim**: real UV coordinates, vertex colors, or
/// normals -- none of those are decoded yet (see `WOCContainerParser.
/// parseOBJ0ChunkArcs`'s doc comment on the still-undecoded trailing
/// block per arc). Every `StaticVertex` here carries only a real
/// position; `normal`/`uv`/`color` stay at `StaticVertex`'s own honest
/// defaults (zero/white) rather than a fabricated guess. The triangle
/// connectivity itself is a strong structural match to a known,
/// confirmed convention, but was not independently verified by rendering
/// actual shaded triangles and inspecting winding -- treat it as a good
/// working hypothesis, not settled ground truth on the level the
/// underlying vertex positions are (those were visually confirmed as
/// coherent 3D shapes; connectivity was not, beyond structural pattern
/// matching).
public enum WOCMeshDecoder {
    /// Builds one `MeshAsset` per real `OBJ0` top-level entry, indexed by
    /// entry index (matching `INST.objectIndex`'s own indexing into
    /// `OBJ0`) -- `nil` at an index means that entry's chunk walk hit
    /// `walkOBJ0Chunks`'s known marker-reuse bug (see
    /// `WOCContainerParser.groupOBJ0ChunksIntoEntries`'s doc comment,
    /// e.g. `CASTLE_C.GSC`/`HUB.GSC`) and grouping was refused outright,
    /// so there's nothing safe to build a mesh from for *any* entry in
    /// that file -- an honest empty result, not a guess.
    public static func buildEntryMeshes(objectPayload: Data) -> [MeshAsset]? {
        guard let groups = WOCContainerParser.groupOBJ0ChunksIntoEntries(objectPayload) else { return nil }
        return groups.enumerated().map { entryIndex, chunks in
            buildMesh(objectPayload: objectPayload, chunks: chunks, entryIndex: entryIndex)
        }
    }

    private static func buildMesh(objectPayload: Data, chunks: [WOCContainerParser.OBJ0Chunk], entryIndex: Int) -> MeshAsset {
        let submeshes = chunks.compactMap { chunk -> MeshSubmesh? in
            let arcs = WOCContainerParser.parseOBJ0ChunkArcs(objectPayload, chunk: chunk)
            let quadwords = arcs.flatMap(\.vertices)
            guard !quadwords.isEmpty else { return nil }
            let vertices = quadwords.map { StaticVertex(position: $0.position) }
            let connectivity = quadwords.map { (($0.control >> 8) & 0xFF) != 0x80 }
            return MeshSubmesh(vertices: vertices, connectivity: connectivity, materialID: nil)
        }
        return MeshAsset(id: UInt32(entryIndex), isSkinned: false, submeshes: submeshes)
    }
}
