import Foundation
import CTCore
import CTModels

/// Real write-back for `SceneryData` -- currently just the one field this
/// codebase has a byte offset for: an *existing* placement's own 4-row
/// `modelMatrix` (see `SceneryModelPlacement.matrixFileOffset`'s doc
/// comment for why this is a patch-in-place, not a full record
/// re-encode). This does **not** support inserting a brand-new
/// placement -- that needs real insertion into `SceneryData`'s nested
/// `SceneryGroup`/`SceneryModelGroup` tree (which group does a new
/// placement join? its own bounding box needs computing; every sibling
/// placement after the insertion point shifts by 64 bytes) and isn't
/// built yet.
public enum SceneryDataWriter {
    /// Encodes exactly the 64 bytes `SceneryDataParser.parseSceneryModelGroup`
    /// reads for one placement's `modelMatrix` (4 rows of `Vector4`,
    /// x/y/z/w each as `Float32`) -- the exact inverse of that read, so
    /// this can patch straight into `matrixFileOffset` with no other byte
    /// in the file moving.
    public static func writeModelMatrix(_ matrix: [SIMD4<Float>]) -> Data {
        var writer = BinaryWriter()
        for row in matrix {
            writer.writeFloat32(row.x)
            writer.writeFloat32(row.y)
            writer.writeFloat32(row.z)
            writer.writeFloat32(row.w)
        }
        return writer.data
    }
}
