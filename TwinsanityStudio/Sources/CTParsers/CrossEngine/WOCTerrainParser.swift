import Foundation
import CTCore

/// Decoder for WoC `.TER` files (terrain) -- a plain, uncompressed loose
/// file per level, like `.AI`/`.GRA`/`.PAD`/`.ANM`.
///
/// Outer framing confirmed by exact byte consumption on 9 real files
/// (`AIRSHIP.TER` 96428B through `SNOW_B.TER` 1417128B):
/// ```
/// File := halfLength:UInt32LE unknownPair:(UInt16, UInt16) mainBlock:Bytes(halfLength*2 - 8)
///         tailCount:UInt32LE TailRecord(tailCount)
/// TailRecord := Bytes(52)
/// ```
/// i.e. `halfLength*2` marks exactly where the tail record table begins,
/// and `halfLength*2 + 4 + tailCount*52` lands exactly on end-of-file --
/// both confirmed exactly, not approximately, across all 9 files checked.
///
/// **Neither block's internal fields are decoded.** `mainBlock` is the
/// bulk of the file (>99.9% byte-plausible as packed floats) and resisted
/// stride-finding across multiple header-size assumptions -- likely a
/// nested/hierarchical mesh+LOD structure, not a flat array. `TailRecord`
/// looked at first like `id:u32 + position:Vector3 + two u16 indices +
/// reserved + a 0xFFFF marker`, but checking every record in
/// `AIRSHIP.TER` directly found 4 of 5 records have a degenerate
/// all-near-zero position and the proposed marker field doesn't hold --
/// not confirmed enough to expose as decoded fields, so both blocks are
/// returned raw.
public enum WOCTerrainParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    public struct File {
        public let mainBlock: Data
        public let tailRecords: [Data]
    }

    public static func parse(_ data: Data) throws -> File {
        var cursor = BinaryCursor(data: data)
        let halfLength = try cursor.readUInt32()
        _ = try cursor.readUInt16() // unknown pair, unconfirmed meaning
        _ = try cursor.readUInt16()
        let mainBlockLength = Int(halfLength) * 2 - 8
        guard mainBlockLength >= 0 else { throw ParseError.truncated }
        let mainBlock = Data(try cursor.readBytes(mainBlockLength))

        let tailCount = try cursor.readUInt32()
        var tailRecords: [Data] = []
        tailRecords.reserveCapacity(Int(tailCount))
        for _ in 0..<tailCount {
            tailRecords.append(Data(try cursor.readBytes(52)))
        }
        return File(mainBlock: mainBlock, tailRecords: tailRecords)
    }
}
