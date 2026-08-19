import Foundation
import CTCore

/// Decoder for WoC `.PTL` (particle effect definitions) and `.CPT`
/// (checkpoint-touch effects) files -- both plain, uncompressed loose
/// files per level, sharing the exact same 839-byte record format
/// (confirmed across 11 real files: `SPARKS`/`FIRE_DEBRIS`/`BUBBLES`-
/// named `.CPT` records decode to equally sane values as `.PTL`'s
/// `Rain`/`RainDust`/`WCrunch1`-named ones).
///
/// ```
/// File (.PTL) := tag:UInt32LE recordCount:UInt32LE Record(recordCount) trailer:Bytes(4, ==0)
/// File (.CPT) := tag:UInt32LE recordCount:UInt32LE Record(recordCount)   -- no trailer
/// Record := Bytes(839), see ParticleRecord for the fields decoded within it
/// ```
/// `tag` is a small constant that differs by sample (`15`/`11` seen in
/// `.PTL` files, `13` in `.CPT` files) -- meaning unconfirmed, read but
/// not enforced.
///
/// **This only covers the "simple", fixed-839-byte-record case.** Larger
/// files (`CASTLE.PTL`, `INTRO.PTL`) carry variable-length records with
/// extra nested data this does not decode -- `parse` throws rather than
/// guessing when a file doesn't fit the confirmed shape (either a
/// bounds error partway through the fixed-stride record read, or a
/// trailer that isn't exactly 0 or 4 bytes).
public enum WOCParticleParser {
    public enum ParseError: Error, Equatable {
        case truncated
        /// The file didn't end with exactly a 0-byte (`.CPT`) or 4-byte
        /// (`.PTL`) trailer after `recordCount` fixed 839-byte records --
        /// likely one of the not-yet-decoded variable-length files
        /// (`CASTLE.PTL`-shaped) rather than the confirmed simple format.
        case notSimpleFixedRecordFormat
    }

    private static let recordWidth = 839

    /// One particle/effect definition record. Only the fields with real,
    /// cross-file-validated evidence are exposed as typed properties --
    /// see each field's own doc comment for how it was confirmed. The
    /// rest of the 839-byte record (roughly 85% of it, effectively
    /// always zero in every real "simple" record checked) is exposed as
    /// `raw` rather than guessed at. Several more candidate fields were
    /// found but are NOT exposed here pending more evidence: a signed
    /// `Int16` at relative offset `0x10` that looks like a rate
    /// multiplier, a `UInt16` at `0x12` that looks like a particle
    /// count, a `UInt16` at `0x20` that's always `0` or `2`, a `Float32`
    /// at `0x2A` that looks like an emission rate (often a copy-pasted
    /// default repeated verbatim across records in the same file), and a
    /// `Float32` pair at `0x186`/`0x1C6` that moves together with
    /// `maxSizeWidth`/`maxSizeHeight` but isn't a clean function of them.
    public struct ParticleRecord {
        /// Null-terminated ASCII from relative offset `0x00`; the buffer
        /// past the terminator isn't always zeroed (leftover copy/rename
        /// garbage from the original authoring tool, e.g. a name field
        /// that continues `"...\0ck3OLD"` after its own null) -- only the
        /// part before the first zero byte is kept.
        public let name: String
        /// Relative offset `0x9A`. Sane range (0.15-5.05 seconds) across
        /// all 44 records checked in 11 real files; matches particle
        /// lifetime semantically (quick impact effects ~0.2s, lingering
        /// smoke/dust 2-5s).
        public let lifetimeSeconds: Float
        /// Relative offsets `0x1FE`/`0x202`. Dominated by round values
        /// (`-360...360`, a few `-720...720`) with real per-effect tuning
        /// seen too (e.g. `392.6`/`350.2` on one record) -- matches a
        /// min/max rotation range in degrees.
        public let minRotationDegrees: Float
        public let maxRotationDegrees: Float
        /// Relative offsets `0x18A`/`0x1CA` (64 bytes apart). Usually
        /// equal (round/square particles) but diverges meaningfully and
        /// physically for real effects (e.g. `Rain`: 51.2/5000.0 -- thin
        /// and tall; `RainDust`: 5000.0/2640.8 -- squashed) -- matches a
        /// max particle size per axis (width/height).
        public let maxSizeWidth: Float
        public let maxSizeHeight: Float
        /// The full 839-byte record, for any future decoding of the
        /// still-open fields noted on this type's own doc comment.
        public let raw: Data
    }

    public static func parse(_ data: Data) throws -> (records: [ParticleRecord], trailer: Data) {
        var cursor = BinaryCursor(data: data)
        _ = try cursor.readUInt32() // tag, unconfirmed meaning
        let recordCount = try cursor.readUInt32()

        var records: [ParticleRecord] = []
        records.reserveCapacity(Int(recordCount))
        for _ in 0..<recordCount {
            let recordStart = cursor.position
            let raw = try cursor.readBytes(recordWidth)
            let name = String(decoding: raw.prefix(16).prefix { $0 != 0 }, as: UTF8.self)

            let lifetimeSeconds = try cursor.withTemporarySeek(to: recordStart + 0x9A) { try $0.readFloat32() }
            let minRotationDegrees = try cursor.withTemporarySeek(to: recordStart + 0x1FE) { try $0.readFloat32() }
            let maxRotationDegrees = try cursor.withTemporarySeek(to: recordStart + 0x202) { try $0.readFloat32() }
            let maxSizeWidth = try cursor.withTemporarySeek(to: recordStart + 0x18A) { try $0.readFloat32() }
            let maxSizeHeight = try cursor.withTemporarySeek(to: recordStart + 0x1CA) { try $0.readFloat32() }

            records.append(ParticleRecord(
                name: name,
                lifetimeSeconds: lifetimeSeconds,
                minRotationDegrees: minRotationDegrees,
                maxRotationDegrees: maxRotationDegrees,
                maxSizeWidth: maxSizeWidth,
                maxSizeHeight: maxSizeHeight,
                raw: raw
            ))
        }

        guard cursor.remaining == 0 || cursor.remaining == 4 else {
            throw ParseError.notSimpleFixedRecordFormat
        }
        let trailer = try cursor.readBytes(cursor.remaining)
        return (records, trailer)
    }
}
