import Foundation

/// Decoder for the top-level container format inside decompressed WoC
/// `.GSC` level files (post-`RNCDecompressor`). This is a brand-new format
/// with no existing reference implementation anywhere in this repo's
/// reference material -- unlike `RNCDecompressor`, every field here was
/// derived by hand from real decompressed bytes (7 real WoC level files
/// spanning very different sizes and areas) and cross-checked for
/// consistency before being treated as confirmed. Fields not yet
/// consistency-checked across multiple real files are called out as such
/// in their doc comments rather than presented as certain.
///
/// **Confirmed file layout** (verified: the section chain below walks every
/// one of the 7 sample files to exactly 100% of its decompressed byte
/// length, with no gaps and no out-of-bounds reads):
/// ```
/// File    := "NU20" negatedByteCount:UInt32LE formatVersion:UInt32LE reserved:UInt32LE Section*
/// Section := tag:ASCII(4) length:UInt32LE payload:Bytes(length - 8)
/// ```
/// - `negatedByteCount`: confirmed by exact arithmetic match across all 7
///   samples to be `(0x1_0000_0000 - totalDecompressedByteCount) mod 2^32`
///   -- i.e. the two's-complement negation of the file's own total decoded
///   size. Purpose unconfirmed (plausibly a cheap self-description a loader
///   checks against the buffer it allocated), but the arithmetic identity
///   itself is exact, not approximate.
/// - `formatVersion`/`reserved`: constant `6` and `0` in all 7 samples.
///   Too few data points to be fully sure these never vary, but there is
///   no evidence yet that they do.
/// - `Section.length` is **relative to the section's own tag position**,
///   not an absolute file offset and not a payload-only length -- it is
///   the exact byte distance from this section's tag start to the next
///   section's tag start (or, for the last section, to end of file).
///   Confirmed identically for both the small top-level sections (`NTBL`)
///   and the largest one (`TST0`, hundreds of KB) via direct byte
///   inspection at the predicted offset.
///
/// **Section tags seen across the 7 samples, in the order they appear**
/// (not confirmed to be exhaustive or always in this exact order -- this is
/// what 7 files showed): `NTBL`, `TST0`, `MS00`, `TAS0` (present in some
/// files, absent in others -- e.g. missing from `AIRSHIP.GSC`/`FARM.GSC`,
/// present in `HUB.GSC`/`CASTLE_C.GSC`), `OBJ0`, `INST`, `IABL`/`ALIB`
/// (also present-in-some/absent-in-others), `SPEC`, `SST0` (always last).
/// Only `NTBL`'s payload is decoded below (see ``parseNameTable(_:)``);
/// every other section's internal structure is still unknown and is
/// exposed as raw ``WOCSection/payload`` bytes rather than guessed at.
public enum WOCContainerParser {
    public enum ParseError: Error, Equatable {
        case badMagic
        case truncated
        case invalidSectionLength(tag: String, length: UInt32, atOffset: Int)
    }

    public struct File {
        public let negatedByteCount: UInt32
        public let formatVersion: UInt32
        public let reserved: UInt32
        public let sections: [Section]
    }

    public struct Section {
        public let tag: String
        /// Total byte length of this section, tag through end -- i.e. the
        /// distance from this section's own tag start to the next one's.
        public let length: UInt32
        /// `length - 8` bytes: everything after the tag and length fields.
        public let payload: Data
    }

    private static let headerSize = 16 // "NU20" + negatedByteCount + formatVersion + reserved

    public static func parse(_ bytes: [UInt8]) throws -> File {
        guard bytes.count >= headerSize else { throw ParseError.truncated }
        guard bytes[0] == 0x4E, bytes[1] == 0x55, bytes[2] == 0x32, bytes[3] == 0x30 else { // "NU20"
            throw ParseError.badMagic
        }
        let negatedByteCount = leUInt32(bytes, 4)
        let formatVersion = leUInt32(bytes, 8)
        let reserved = leUInt32(bytes, 12)

        var sections: [Section] = []
        var offset = headerSize
        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { throw ParseError.truncated }
            guard let tag = asciiTag(bytes, offset) else { break } // non-tag bytes: end of the flat chain
            let length = leUInt32(bytes, offset + 4)
            guard length >= 8, offset + Int(length) <= bytes.count else {
                throw ParseError.invalidSectionLength(tag: tag, length: length, atOffset: offset)
            }
            let payloadStart = offset + 8
            let payloadEnd = offset + Int(length)
            let payload = Data(bytes[payloadStart..<payloadEnd])
            sections.append(Section(tag: tag, length: length, payload: payload))
            offset += Int(length)
        }

        return File(negatedByteCount: negatedByteCount, formatVersion: formatVersion, reserved: reserved, sections: sections)
    }

    /// Decodes an `NTBL` section's payload: a flat, null-terminated ASCII
    /// name list. Confirmed across all 7 samples: `stringBlobLength`
    /// exactly matches the summed byte length (including null terminators)
    /// of the visible name strings that follow it, every time.
    ///
    /// The bytes between the end of the string blob and the end of the
    /// section (`trailer`) are **not understood yet** -- their length
    /// varies non-trivially across samples (2, 9, 9, 11, 12, 13 bytes in
    /// the 6 samples that have a nonempty trailer) with no formula found
    /// yet that explains it from the name list alone, so they're returned
    /// as raw bytes rather than a guessed schema.
    public static func parseNameTable(_ payload: Data) throws -> (names: [String], trailer: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { throw ParseError.truncated }
        let stringBlobLength = Int(leUInt32(bytes, 0))
        guard 4 + stringBlobLength <= bytes.count else { throw ParseError.truncated }

        let blobStart = 4
        let blobEnd = blobStart + stringBlobLength
        let blob = bytes[blobStart..<blobEnd]

        var names: [String] = []
        var current: [UInt8] = []
        for b in blob {
            if b == 0 {
                if !current.isEmpty { names.append(String(decoding: current, as: UTF8.self)) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(b)
            }
        }
        if !current.isEmpty { names.append(String(decoding: current, as: UTF8.self)) }

        let trailer = Data(bytes[blobEnd...])
        return (names, trailer)
    }

    // MARK: - helpers

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    private static func asciiTag(_ b: [UInt8], _ o: Int) -> String? {
        for i in 0..<4 {
            let c = b[o + i]
            let isUpper = c >= 0x41 && c <= 0x5A
            let isDigit = c >= 0x30 && c <= 0x39
            guard isUpper || isDigit else { return nil }
        }
        return String(decoding: b[o..<(o + 4)], as: UTF8.self)
    }
}
