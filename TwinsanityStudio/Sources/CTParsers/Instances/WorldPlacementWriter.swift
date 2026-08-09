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
    /// "Backend Requirement: safely inject this new record" (Part 4D) —
    /// encodes a **complete**, brand-new `Instance` record, not just the
    /// transform prefix `writeInstanceTransform` patches into an existing
    /// one. Field order matches `Instance.cs`'s `Save` exactly (verified
    /// against `WorldPlacementParser.parseInstance`'s matching `Load`
    /// order); every field this build has no reason to give a specific
    /// value to uses the *reference class's own default-constructor
    /// values* (`SomeNum1/2/3 = 10`, `RefList = -1`, `ScriptID = -1`,
    /// `Flags = 0x6`, `UnkI321 = []`, `UnkI322 = [1]`, `UnkI323 = [0, 0]`)
    /// — real defaults a freshly-`new Instance()`'d record in the
    /// reference tool actually has, not invented placeholder data. No
    /// child Instance/Position/Path IDs: a newly placed object starts
    /// with no scripted relationships to anything else in the level. Takes
    /// no record ID — unlike every field encoded below, the ID lives in
    /// the *enclosing section's* index-table entry (see
    /// `ChunkSectionInserter`), not inside the record's own bytes.
    public static func writeNewInstance(objectID: UInt16, position: SIMD4<Float>, rotationDegrees: SIMD3<Float>) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)

        let rotX = PlacedInstance.rawAngle(fromDegrees: rotationDegrees.x)
        let rotY = PlacedInstance.rawAngle(fromDegrees: rotationDegrees.y)
        let rotZ = PlacedInstance.rawAngle(fromDegrees: rotationDegrees.z)
        writer.writeUInt16(rotX)
        writer.writeUInt16(0) // COMRotX — no COM offset for a fresh placement
        writer.writeUInt16(rotY)
        writer.writeUInt16(0) // COMRotY
        writer.writeUInt16(rotZ)
        writer.writeUInt16(0) // COMRotZ

        // Three counted ID lists (InstanceIDs/PositionIDs/PathIDs), each
        // [count, count (written twice, per Instance.cs's own Save), SomeNum, values...] —
        // empty for a fresh placement, SomeNum defaults to 10 either way.
        for someNum: Int32 in [10, 10, 10] {
            writer.writeInt32(0)
            writer.writeInt32(0)
            writer.writeInt32(someNum)
        }

        writer.writeUInt16(objectID)
        writer.writeInt16(-1) // RefList
        writer.writeInt16(-1) // ScriptID — no script attached
        // PHeader: (byte)UnkI321.Count | (UnkI322.Count << 8) | (UnkI323.Count << 16)
        // = 0 | (1 << 8) | (2 << 16), matching the UnkI322/UnkI323 defaults below.
        writer.writeUInt32(0x0002_0100)
        writer.writeUInt32(0x6) // Flags — reference default

        writer.writeInt32(0) // UnkI321.Count — empty
        writer.writeInt32(1) // UnkI322.Count
        writer.writeFloat32(1) // UnkI322[0] — reference default
        writer.writeInt32(2) // UnkI323.Count
        writer.writeUInt32(0) // UnkI323[0]
        writer.writeUInt32(0) // UnkI323[1]

        return writer.data
    }

    /// Encodes a complete `AIPosition` record — the exact inverse of
    /// `AINavigationParser.parseAIPosition`. Fixed-size (18 bytes: `Pos`
    /// then `Num`, matching `AIPosition.cs`'s own `GetSize() => 18`
    /// exactly), so — like `writePosition` — this can patch straight into
    /// an existing record's offset with no other offset in the file
    /// needing to move, and works equally well for encoding a brand-new
    /// record to insert (`ChunkSectionInserter` doesn't care that this
    /// record type wasn't its original use case; the section-header/index
    /// layout it rebuilds is the same for every collection).
    public static func writeAIPosition(position: SIMD4<Float>, rawNodeType: UInt16) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(position.x)
        writer.writeFloat32(position.y)
        writer.writeFloat32(position.z)
        writer.writeFloat32(position.w)
        writer.writeUInt16(rawNodeType)
        return writer.data
    }

    /// Encodes an `Instance`'s `objectID` back to its on-disk 2-byte form
    /// — "Recipe Book" (roadmap 6.4) character/prop swap: reassigning
    /// which real `GameObject`/`RigidModel` an existing placement resolves
    /// to, patched at `PlacedInstance.objectIDFileOffset` the same way a
    /// moved camera control point patches its own offset. Never changes
    /// the record's size (`UInt16` in, `UInt16` out), so — like every
    /// other patch in this file — nothing else in the file needs to move.
    public static func writeInstanceObjectID(_ objectID: UInt16) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt16(objectID)
        return writer.data
    }

    /// Encodes one Camera Path/Spline control point (`CameraPath.unkVectors`/
    /// `CameraSpline.unkVectors`) back to its on-disk 16-byte form — the
    /// exact inverse of `BinaryCursor.readVector4` at the offset captured
    /// in `controlPointFileOffsets` during parse. A dragged control point
    /// never changes the record's total size (same value in, same value
    /// out, just different bits), so — like `writePosition` — this patches
    /// straight into a copy of the file at the point's exact absolute
    /// offset (`ChunkNode.fileOffset + controlPointFileOffsets[i]`) with
    /// nothing else in the file needing to move.
    public static func writeCameraControlPoint(_ vector: SIMD4<Float>) -> Data {
        var writer = BinaryWriter()
        writer.writeFloat32(vector.x)
        writer.writeFloat32(vector.y)
        writer.writeFloat32(vector.z)
        writer.writeFloat32(vector.w)
        return writer.data
    }

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
