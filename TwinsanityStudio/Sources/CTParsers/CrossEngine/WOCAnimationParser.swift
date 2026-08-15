import Foundation
import CTCore

/// Decoder for WoC `.ANM` files -- a plain, uncompressed loose file per
/// level, like `.AI`/`.GRA`/`.PAD`.
///
/// Format, confirmed by exact byte consumption on 4 real files
/// (`AVALANCH.ANM` 212B, `CASTLE.ANM` 92B, `CASTLE_C.ANM` 52B,
/// `SPACE_R.ANM` 8B/0 entries):
/// ```
/// File  := formatFlag:UInt32LE entryCount:UInt32LE Entry(entryCount)
/// Entry := name:Bytes(16, null-padded ASCII) flag:UInt32LE(==0 in samples)
///          subCount:UInt32LE reserved:Bytes(20) SubEntry(subCount)
/// SubEntry := name:Bytes(16, null-padded ASCII) flag:UInt32LE
///             params:(Float32, Float32, Float32, Float32, Float32)
/// ```
/// **This is confirmed only for "simple" animation files** -- small
/// object animations like `"avalanche"` (sub-entries `AVA_MID`/
/// `AVA_SML`/`AVA_LRG`...) or `"ball_04"` (sub-entry `BALL`). A 5th real
/// file, `TOONARMY.ANM` (1128 bytes, 20 top-level entries with
/// Maya-derived names like `"pcube2318"`), does NOT fit this template --
/// decoding diverges after the first entry, indicating real
/// skeletal-animation files use a materially different, more complex
/// per-joint curve encoding that hasn't been decoded. `parse` will throw
/// rather than silently return garbage if the byte-consumption doesn't
/// land exactly on end-of-file, so callers can detect this case.
public enum WOCAnimationParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case didNotConsumeWholeFile
    }

    public struct SubEntry {
        public let name: String
        public let flag: UInt32
        public let params: (Float, Float, Float, Float, Float)
    }

    public struct Entry {
        public let name: String
        public let flag: UInt32
        public let subEntries: [SubEntry]
    }

    public static func parse(_ data: Data) throws -> [Entry] {
        var cursor = BinaryCursor(data: data)
        _ = try cursor.readUInt32() // formatFlag, unconfirmed meaning
        let entryCount = try cursor.readUInt32()

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        for _ in 0..<entryCount {
            let nameBytes = try cursor.readBytes(16)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            let flag = try cursor.readUInt32()
            let subCount = try cursor.readUInt32()
            _ = try cursor.readBytes(20) // reserved

            var subEntries: [SubEntry] = []
            subEntries.reserveCapacity(Int(subCount))
            for _ in 0..<subCount {
                let subNameBytes = try cursor.readBytes(16)
                let subName = String(decoding: subNameBytes.prefix { $0 != 0 }, as: UTF8.self)
                let subFlag = try cursor.readUInt32()
                let p0 = try cursor.readFloat32()
                let p1 = try cursor.readFloat32()
                let p2 = try cursor.readFloat32()
                let p3 = try cursor.readFloat32()
                let p4 = try cursor.readFloat32()
                subEntries.append(SubEntry(name: subName, flag: subFlag, params: (p0, p1, p2, p3, p4)))
            }
            entries.append(Entry(name: name, flag: flag, subEntries: subEntries))
        }

        guard cursor.remaining == 0 else { throw ParseError.didNotConsumeWholeFile }
        return entries
    }
}
