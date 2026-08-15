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
///
/// **Decoded so far:**
/// - `NTBL` (name table) -- see ``parseNameTable(_:)``. Fully decoded: a
///   byte-length-prefixed blob of null-terminated names. The trailer bytes
///   between the name blob and the next section are not understood (their
///   length varies non-trivially and doesn't reduce to a formula from the
///   name list alone).
/// - `MS00` -- see ``parseMeshSet(_:)``. Confirmed to be `count` fixed
///   464-byte records (exact division verified across 4 real files of very
///   different sizes). Record internals not decoded.
/// - `INST` (placed object instances) -- see ``parseInstances(_:)`` and
///   ``Instance``. Fully decoded and the strongest result so far: each of
///   the 80-byte records is a real 4x4 world transform. Confirmed 3 ways:
///   (1) the record width divides cleanly and identically across files,
///   (2) a per-instance index field exactly matches that instance's own
///   array position with 0 mismatches across 564 real instances in 2
///   files, (3) plotting the decoded translations for 4 real levels
///   produces recognizable level layouts (e.g. `CASTLE_C.GSC`'s clear
///   cross-shaped corridor), not noise.
/// - `TST0`, `OBJ0`, `TAS0`, `IABL`, `ALIB`, `SPEC`, `SST0` -- not decoded.
///   `OBJ0`'s count matches `INST`'s count in both files checked
///   (suggesting a 1:1 correspondence, e.g. per-instance mesh/material
///   data) but it is NOT a fixed-width record table like `MS00`/`INST`
///   (average ~9.7KB/entry in the `AIRSHIP.GSC` sample, with no offset
///   table found at its start) -- likely the next highest-value target,
///   left for a future session rather than guessed at under time
///   pressure.
///
/// Every section not listed above as decoded is exposed as raw
/// ``WOCSection/payload`` bytes rather than guessed at.
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

    /// Decodes an `MS00` section's payload as a fixed-width record table:
    /// `count:UInt32LE` + `reserved:UInt32LE` + `count` records of a
    /// constant width. Confirmed across 4 real files of very different
    /// sizes (57/69/89/154 records) that `(payload.count - 8)` divides
    /// `count` **exactly**, and always to the same width: 464 bytes.
    ///
    /// The internal layout of a single 464-byte record is not decoded --
    /// most records are almost entirely zero-filled, with the first ~288
    /// bytes consistently zero and a small non-zero region starting
    /// around byte 288, containing what look like plausible transform-ish
    /// float values (e.g. a `(0.5, 0.5, 0.5)` triplet and a couple of
    /// exact `1.0`s were seen at consistent offsets within one sample
    /// record) -- but this is an observation from a single record, not a
    /// cross-record-verified field layout, so records are returned as raw
    /// bytes rather than a guessed struct.
    public static func parseMeshSet(_ payload: Data) throws -> (records: [Data], recordWidth: Int) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let remaining = bytes.count - 8
        guard count > 0, remaining % count == 0 else {
            return ([], 0)
        }
        let width = remaining / count
        var records: [Data] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let start = 8 + i * width
            records.append(Data(bytes[start..<(start + width)]))
        }
        return (records, width)
    }

    /// A single placed object instance from an `INST` section: a 4x4
    /// world transform plus a small metadata tail. Fully decoded and
    /// hard-verified, not a guess -- see ``parseInstances(_:)``.
    public struct Instance {
        /// Row-major 4x4 transform; translation lives in row 3
        /// (`row3 = (tx, ty, tz, 1.0)`), confirmed by `w` being exactly
        /// `1.0` in every one of 564 real instances checked across 2
        /// files.
        public let matrix: (Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float)
        /// Confirmed to exactly equal this instance's own position in the
        /// `INST` array in every one of 564 real records checked (0
        /// mismatches across `AIRSHIP.GSC` (41 instances) and `FARM.GSC`
        /// (523 instances)) -- not inferred, directly cross-checked.
        public let index: UInt32
        /// Varies per instance (seen values: mostly `5`, occasionally
        /// `4` in the samples checked). Plausibly a mesh-set/type
        /// reference into `MS00`, but that link is not yet confirmed --
        /// treat as an opaque tag for now.
        public let typeOrMeshIndex: UInt32
        /// Zero for the vast majority of real instances (502/523 in the
        /// `FARM.GSC` sample), but *not* always -- about 4% of real
        /// instances there carry a nonzero value tightly clustered in the
        /// `0x13a3xxxx`-`0x13a7xxxx` range, which reads like a stray
        /// serialized runtime pointer (roughly sequential, heap-address
        /// shaped) rather than meaningful per-instance data. Exposed
        /// as-is rather than masked to zero, since it demonstrably isn't
        /// always zero.
        public let unknownTail1: UInt32
        /// Zero in every one of 564 real instances checked across both
        /// samples -- unlike `unknownTail1`, no counterexample found yet.
        public let unknownTail2: UInt32

        public var translation: SIMD3<Float> { SIMD3(matrix.12, matrix.13, matrix.14) }
    }

    /// Decodes an `INST` section's payload: `count:UInt32LE` +
    /// `reserved:UInt32LE` + `count` fixed-width 80-byte records. Record
    /// width and count were cross-verified against real files the same
    /// way as ``parseMeshSet(_:)``, and `INST`'s `count` was additionally
    /// observed to exactly match its sibling `OBJ0` section's own leading
    /// count field in both samples checked, suggesting (not yet confirmed)
    /// a 1:1 correspondence between `OBJ0` entries and `INST` instances.
    public static func parseInstances(_ payload: Data) throws -> [Instance] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let remaining = bytes.count - 8
        guard count > 0, remaining % count == 0, remaining / count == 80 else { return [] }

        var instances: [Instance] = []
        instances.reserveCapacity(count)
        for i in 0..<count {
            let start = 8 + i * 80
            var floats = [Float](repeating: 0, count: 16)
            for f in 0..<16 { floats[f] = leFloat32(bytes, start + f * 4) }
            let tailStart = start + 64
            let index = leUInt32(bytes, tailStart)
            let typeOrMeshIndex = leUInt32(bytes, tailStart + 4)
            let unknownTail1 = leUInt32(bytes, tailStart + 8)
            let unknownTail2 = leUInt32(bytes, tailStart + 12)
            instances.append(Instance(
                matrix: (floats[0], floats[1], floats[2], floats[3],
                         floats[4], floats[5], floats[6], floats[7],
                         floats[8], floats[9], floats[10], floats[11],
                         floats[12], floats[13], floats[14], floats[15]),
                index: index, typeOrMeshIndex: typeOrMeshIndex,
                unknownTail1: unknownTail1, unknownTail2: unknownTail2
            ))
        }
        return instances
    }

    // MARK: - helpers

    private static func leFloat32(_ b: [UInt8], _ o: Int) -> Float {
        Float(bitPattern: leUInt32(b, o))
    }

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
