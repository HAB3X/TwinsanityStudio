import Foundation
import CTCore
import CTModels

/// Encodes a `PathAsset` back to its real on-disk layout — the exact
/// inverse of `PathParser.parse` (mirrors `Editors/PathEditor.cs` in the
/// reference tool). Only safe to use with `WorkspaceViewModel.
/// patchedFileBytes(replacing:with:)` when `positions.count`/`params.count`
/// are unchanged from the decoded record.
public enum PathWriter {
    public static func write(_ path: PathAsset) -> Data {
        var w = BinaryWriter()
        w.writeInt32(Int32(path.positions.count))
        for position in path.positions {
            w.writeVector4(position)
        }
        w.writeInt32(Int32(path.params.count))
        for param in path.params {
            w.writeFloat32(param.p1)
            w.writeFloat32(param.p2)
        }
        return w.data
    }
}
