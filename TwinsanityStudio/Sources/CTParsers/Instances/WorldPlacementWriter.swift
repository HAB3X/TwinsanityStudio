import Foundation
import CTCore
import CTModels

/// Encodes a `PositionMarker` back to its on-disk 16-byte form — the
/// inverse of `WorldPlacementParser.parsePosition`. This is the "Editing
/// GUI" proof of concept's write path: `Position` was chosen as the first
/// record type to round-trip specifically because it's fixed-size (4
/// floats, always 16 bytes in and 16 bytes out), so an edit can be patched
/// straight into a copy of the original file bytes at the record's known
/// offset with no index-table/size recalculation anywhere else in the
/// file — every other decoded record type here is variable-length, which
/// is real, separate work (`ArchiveRepackager`-level offset repacking, not
/// just this one function) left for when this write path grows beyond a
/// single record type.
public enum WorldPlacementWriter {
    public static func writePosition(_ position: PositionMarker) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.point.x)
        writer.writeFloat32(position.point.y)
        writer.writeFloat32(position.point.z)
        writer.writeFloat32(position.point.w)
        return writer.data
    }
}
