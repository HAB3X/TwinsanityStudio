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

    /// Encodes just `Instance`'s leading 28-byte transform prefix (`position`,
    /// then the six interleaved rotation/COM-rotation `UInt16`s) — the exact
    /// inverse of the first six reads in `WorldPlacementParser.parseInstance`,
    /// stopping right before the variable-length `childInstanceIDs` list.
    /// Unlike `writePosition` this is *not* the whole record: `Instance` is
    /// variable-size (three counted ID lists plus three undocumented trailing
    /// lists), so re-encoding the full record would mean recomputing offsets
    /// for everything after it in the file — real, separate work this write
    /// path doesn't do. Patching only this fixed-size, fixed-offset prefix
    /// sidesteps that: a transform edit never changes the record's total
    /// size, so nothing after it moves.
    public static func writeInstanceTransform(position: SIMD4<Float>, rotationRaw: SIMD3<UInt16>, comRotationRaw: SIMD3<UInt16>) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)
        writer.writeUInt16(rotationRaw.x)
        writer.writeUInt16(comRotationRaw.x)
        writer.writeUInt16(rotationRaw.y)
        writer.writeUInt16(comRotationRaw.y)
        writer.writeUInt16(rotationRaw.z)
        writer.writeUInt16(comRotationRaw.z)
        return writer.data
    }
}
