import Foundation
import CTCore

/// Decoder for WoC `.PAD` files -- a plain, uncompressed loose file per
/// level, like `.AI`/`.GRA`. Name and exact purpose unconfirmed (a
/// leading hypothesis, not verified: an AI path-node graph, since records
/// read as small fixed nodes with a couple of varying fields), so this
/// only decodes the confirmed outer framing rather than guessing at
/// record semantics.
///
/// Format, confirmed by exact byte consumption on all 17 real `.PAD`
/// files in the corpus checked (`40 + recordCount*20 == fileSize` exactly
/// every time, sizes 2180-117360 bytes):
/// ```
/// File := recordCount:UInt32LE constantOne:UInt32LE(==1) recordCountEcho:UInt32LE(==recordCount)
///         magic:UInt32LE reserved:Bytes(24) Record(recordCount)
/// Record := Bytes(20)   -- not decoded further, see below
/// ```
/// `magic` takes one of only 3 observed values across the corpus (7198,
/// 3598, 35998) -- plausibly a level-type or path-graph-variant tag, not
/// confirmed. Record internals are NOT decoded: in the one file inspected
/// closely (`VOLCANO.PAD`), the first several records were found to be
/// completely byte-identical (a constant 4-byte tag, all-zero middle
/// fields, a constant trailing pair) -- not enough real variation was
/// found to commit to field semantics, so records are exposed raw.
public enum WOCPadParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    public struct File {
        public let magic: UInt32
        public let records: [Data]
    }

    public static func parse(_ data: Data) throws -> File {
        var cursor = BinaryCursor(data: data)
        let count = try cursor.readUInt32()
        _ = try cursor.readUInt32() // constant 1
        _ = try cursor.readUInt32() // count echo, confirmed == count
        let magic = try cursor.readUInt32()
        _ = try cursor.readBytes(24) // reserved, unconfirmed content

        var records: [Data] = []
        records.reserveCapacity(Int(count))
        for _ in 0..<count {
            records.append(Data(try cursor.readBytes(20)))
        }
        return File(magic: magic, records: records)
    }
}
