import Foundation
import CTCore
import CTModels

/// Decodes a `GameObject` record (`Object` section, sub-ID 0 under `Code`)
/// — but only through the `OGIs` list. Ported from `Twinsanity/Items/Code/
/// GameObject.cs`'s `Load`:
/// ```
/// uint32 UnkBitfield
/// byte[8] ScriptSlots
/// int32 nameLength; char[nameLength] Name
/// int32 ui32Count;  uint32[ui32Count]  UI32
/// int32 ogiCount;   uint16[ogiCount]   OGIs      <- this is all this reader needs
/// int32 animCount;  uint16[animCount]  Anims
/// ... (Scripts, Objects, Sounds lists, an optional instance-properties
///      block, an optional linked-ID block, and a trailing script-bytecode
///      command tree — none of it needed to answer "what does this object
///      render as," so not read here; this record's `ChunkNode.byteSize`
///      is independently known from its own index-table entry, so leaving
///      the cursor short of the record's true end is harmless).
/// ```
public enum GameObjectParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> GameObjectInfo {
        _ = try cursor.readUInt32() // UnkBitfield
        _ = try cursor.readBytes(8) // ScriptSlots

        let nameLength = Int(try cursor.readInt32())
        let name = try cursor.readASCIIString(length: nameLength)

        let ui32Count = try cursor.readInt32()
        for _ in 0..<max(0, ui32Count) { _ = try cursor.readUInt32() }

        let ogiCount = try cursor.readInt32()
        var ogiIDs: [UInt32] = []
        ogiIDs.reserveCapacity(cursor.safeReserveCount(ogiCount, elementSize: 2))
        for _ in 0..<max(0, ogiCount) {
            ogiIDs.append(UInt32(try cursor.readUInt16()))
        }

        return GameObjectInfo(id: recordID, name: name, ogiIDs: ogiIDs)
    }
}
