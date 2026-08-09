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

    /// Encodes the leading 60-byte prefix `Trigger` and `Camera` records
    /// share byte-for-byte — `header`/`enabledMask`/`someFloat`/
    /// `rotationQuaternion`/`position`/`size`, in that order — the exact
    /// inverse of the first six reads in `WorldPlacementParser.parseTrigger`
    /// (and, separately, `parseCamera`, whose first six reads are
    /// identical; see `PlacedCamera`'s own doc comment: "same Header/
    /// Enabled/Coords/Instances shape as Trigger"). Both records go
    /// variable-length immediately after this (a counted `instanceIDs`
    /// list, then — for `Camera` only — many more fields and an optional
    /// polymorphic sub-payload), so same reasoning as `writeInstanceTransform`:
    /// this patches only the fixed-size, fixed-offset prefix, never the
    /// record's total size.
    public static func writeTriggerOrCameraPrefix(header: UInt32, enabledMask: UInt32, someFloat: Float, rotationQuaternion: SIMD4<Float>, position: SIMD4<Float>, size: SIMD4<Float>) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(header)
        writer.writeUInt32(enabledMask)
        writer.writeFloat32(someFloat)
        writer.writeFloat32(rotationQuaternion.x)
        writer.writeFloat32(rotationQuaternion.y)
        writer.writeFloat32(rotationQuaternion.z)
        writer.writeFloat32(rotationQuaternion.w)
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)
        writer.writeFloat32(size.x)
        writer.writeFloat32(size.y)
        writer.writeFloat32(size.z)
        writer.writeFloat32(size.w)
        return writer.data
    }
}
