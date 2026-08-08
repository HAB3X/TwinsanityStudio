import Foundation
import CTCore
import CTModels

/// Decodes `Position`/`Instance`/`Trigger` leaf records — the `Instance`
/// container's sub-ID-3/6/7 collections (see `RM2Parser.tier1ChildType`).
/// Ported 1:1 (including its two on-disk redundant count fields per list)
/// from `Twinsanity/Items/Instances/{Position,Instance,Trigger}.cs`.
public enum WorldPlacementParser {
    public static func parsePosition(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> PositionMarker {
        PositionMarker(id: recordID, point: try cursor.readVector4())
    }

    public static func parseInstance(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> PlacedInstance {
        let position = try cursor.readVector4()
        let rotX = try cursor.readUInt16()
        let comRotX = try cursor.readUInt16()
        let rotY = try cursor.readUInt16()
        let comRotY = try cursor.readUInt16()
        let rotZ = try cursor.readUInt16()
        let comRotZ = try cursor.readUInt16()

        let childInstanceIDs = try readCountedUInt16List(&cursor)
        let childPositionIDs = try readCountedUInt16List(&cursor)
        let childPathIDs = try readCountedUInt16List(&cursor)

        let objectID = try cursor.readUInt16()
        let refList = try cursor.readInt16()
        let scriptID = try cursor.readInt16()
        _ = try cursor.readUInt32() // PHeader — redundant packed count of the three unknown lists below, recomputed on save
        let flags = try cursor.readUInt32()

        let unknownUInt32List = try readUInt32List(&cursor)
        let unknownFloatList = try readFloatList(&cursor)
        let unknownUInt32List2 = try readUInt32List(&cursor)

        return PlacedInstance(
            id: recordID,
            position: position,
            rotationRaw: SIMD3(rotX, rotY, rotZ),
            comRotationRaw: SIMD3(comRotX, comRotY, comRotZ),
            childInstanceIDs: childInstanceIDs,
            childPositionIDs: childPositionIDs,
            childPathIDs: childPathIDs,
            objectID: objectID,
            refList: refList,
            scriptID: scriptID,
            flags: flags,
            unknownUInt32List: unknownUInt32List,
            unknownFloatList: unknownFloatList,
            unknownUInt32List2: unknownUInt32List2
        )
    }

    public static func parseTrigger(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> TriggerVolume {
        let header = try cursor.readUInt32()
        let enabledMask = try cursor.readUInt32()
        let someFloat = try cursor.readFloat32()
        let rotationQuaternion = try cursor.readVector4()
        let position = try cursor.readVector4()
        let size = try cursor.readVector4()

        let instanceIDs = try readCountedUInt16List(&cursor)

        let arg1 = try cursor.readUInt16()
        let arg2 = try cursor.readUInt16()
        let arg3 = try cursor.readUInt16()
        let arg4 = try cursor.readUInt16()

        return TriggerVolume(
            id: recordID,
            header: header,
            enabledMask: enabledMask,
            someFloat: someFloat,
            rotationQuaternion: rotationQuaternion,
            position: position,
            size: size,
            instanceIDs: instanceIDs,
            arg1: arg1,
            arg2: arg2,
            arg3: arg3,
            arg4: arg4
        )
    }

    /// Reads an ID list in the shape shared by `Instance`'s three lists and
    /// `Trigger`'s single list: `int32 count` written twice back-to-back
    /// (the reference tool reads both but only keeps the second), then one
    /// more `int32` field ("SomeNum" on `Instance`, "SectionHead" on
    /// `Trigger` — same byte layout, different label), then `count` `uint16`s.
    private static func readCountedUInt16List(_ cursor: inout BinaryCursor) throws -> [UInt16] {
        _ = try cursor.readInt32() // duplicate count
        let count = try cursor.readInt32()
        _ = try cursor.readInt32() // SomeNum / SectionHead — unused by this reader
        var values: [UInt16] = []
        values.reserveCapacity(max(0, Int(count)))
        for _ in 0..<max(0, count) {
            values.append(try cursor.readUInt16())
        }
        return values
    }

    private static func readUInt32List(_ cursor: inout BinaryCursor) throws -> [UInt32] {
        let count = try cursor.readInt32()
        var values: [UInt32] = []
        values.reserveCapacity(max(0, Int(count)))
        for _ in 0..<max(0, count) {
            values.append(try cursor.readUInt32())
        }
        return values
    }

    private static func readFloatList(_ cursor: inout BinaryCursor) throws -> [Float] {
        let count = try cursor.readInt32()
        var values: [Float] = []
        values.reserveCapacity(max(0, Int(count)))
        for _ in 0..<max(0, count) {
            values.append(try cursor.readFloat32())
        }
        return values
    }
}
