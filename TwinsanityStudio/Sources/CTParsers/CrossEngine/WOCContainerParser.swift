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
/// **Decoded so far** (this list has grown across several sessions --
/// including a real self-correction, see `INST` below, from a broad
/// 54-file sweep that overturned an earlier 2-file-verified claim):
/// - `NTBL` (name table) -- see ``parseNameTable(_:)``. Fully decoded: a
///   byte-length-prefixed blob of null-terminated names. The trailer bytes
///   between the name blob and the next section are not understood (their
///   length varies non-trivially and doesn't reduce to a formula from the
///   name list alone).
/// - `MS00` -- see ``parseMeshSet(_:)``. Confirmed to be `count` fixed
///   464-byte records (exact division verified universally across the
///   full 54-file corpus, zero exceptions). Record internals not decoded.
/// - `IABL` -- see ``parseAttributeBlock(_:)``. Same framing, confirmed
///   fixed 96-byte records across 3 files. Sibling `ALIB` was explicitly
///   tested and ruled out as fixed-width (different widths per file).
/// - `INST` (placed object instances) -- see ``parseInstances(_:)`` and
///   ``Instance``. The 80-byte records are real 4x4 world transforms
///   (`w == 1.0` universally, translations plot into recognizable real
///   level layouts, e.g. `CASTLE_C.GSC`'s cross-shaped corridor). The
///   tail's first field is a confirmed reference into `OBJ0` (see
///   ``Instance/objectIndex`` for the full story, including a real
///   correction after an initial 2-file check accidentally verified the
///   wrong property).
/// - `SPEC` -- see ``parseSpecRecords(_:)`` and ``SpecRecord``. Same
///   80-byte record shape as `INST`, but a curated, strictly-increasing
///   pointer-list *into* `INST` -- each record's matrix is byte-identical
///   to the `INST` record it references (verified for every record in 7
///   files, not sampled).
/// - `TST0` -- see ``parseTextureEntry(_:trailerOffset:)`` and
///   ``scanTextureEntries(_:)``. Not a record table at all: a serialized
///   PS2 Graphics Synthesizer texture-upload command stream. The per-entry
///   size/width/height math is confirmed exactly on 201 real entries
///   across 6 files, but the entry-boundary *scan* is a documented
///   heuristic, not a complete parser (misses some entries, and one file
///   uses an unhandled variant -- see that function's doc comment).
/// - `SST0` (always the last section) -- see ``parseFooterHeader(_:)``.
///   Outer shape confirmed (`A:u32` + `B:u32` blob-length + blob + small
///   trailer), and in 3 of 5 files checked the trailer's last field
///   exactly echoes the section's own outer `length` field back -- but
///   this exact trailer shape is absent or different in the other files
///   (one file's `SST0` is entirely empty), so it's real but not
///   universal. Blob internals unresolved.
/// - `OBJ0`, `TAS0`, `ALIB` -- not decoded. `OBJ0` is the next
///   highest-value target: its per-entry format holds real embedded mesh
///   geometry (a 16-byte vertex quadword pattern was confirmed and
///   visually verified -- see ``parseVertexQuadwords(_:byteOffset:count:)``),
///   and its `count` is now confirmed (54-file sweep) to be exactly the
///   number of distinct objects `INST` instances reference -- but entry
///   *boundaries* within `OBJ0` are still unsolved (no offset table or
///   self-length-prefix found).
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

    /// Reads the leading `UInt32LE` "count" field present at the start of
    /// every count-prefixed section payload (`MS00`/`INST`/`IABL`/`OBJ0`).
    /// A small standalone helper since callers sometimes need this count
    /// (e.g. to cross-reference against another section) without wanting
    /// the full fixed-width record decode.
    public static func leadingCount(_ payload: Data) throws -> Int {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { throw ParseError.truncated }
        return Int(leUInt32(bytes, 0))
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
        /// A reference into the sibling `OBJ0` section's entry array --
        /// i.e. which object/mesh definition this placed instance uses.
        /// This was originally (WRONGLY) documented as "this instance's
        /// own array position" based on 2 small files where that
        /// coincidentally held (`AIRSHIP.GSC`/`FARM.GSC`, where every
        /// object happens to be placed exactly once). A full 53-file
        /// sweep found the real pattern instead, and it's rock solid:
        /// in **every one of the 53 real files checked**, this field's
        /// set of distinct values across all instances is *exactly*
        /// `0..<OBJ0.count` (same count, same max, zero out-of-bounds
        /// references anywhere) -- i.e. every `OBJ0` entry is referenced
        /// by at least one instance, and no instance ever references
        /// past the end. Levels with heavy prop reuse (e.g.
        /// `CASTLE_A.GSC`: 2111 instances referencing only 408 distinct
        /// `OBJ0` entries) make this unambiguous -- it cannot be a
        /// coincidental position match at that scale. Named
        /// `objectIndex` for what it verifiably references; `OBJ0`'s own
        /// per-entry internal format (beyond entry 0's confirmed
        /// embedded vertex geometry) is still not decoded.
        public let objectIndex: UInt32
        /// Only ever `4` or `5` across all 564 real instances checked in
        /// 2 files -- both values are valid `MS00` record indices in both
        /// files (57 and 69 `MS00` records respectively), so a direct
        /// "which `MS00` mesh does this instance use" reference is
        /// plausible on bounds alone, but a real per-level object palette
        /// should reference far more than 2 distinct meshes; a value this
        /// narrow reads more like a small type/category enum than a
        /// general mesh index. Neither interpretation is confirmed --
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
    /// way as ``parseMeshSet(_:)``. See ``Instance/objectIndex`` for the
    /// (now fully confirmed, 53-file) `OBJ0` cross-reference relationship.
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
            let objectIndex = leUInt32(bytes, tailStart)
            let typeOrMeshIndex = leUInt32(bytes, tailStart + 4)
            let unknownTail1 = leUInt32(bytes, tailStart + 8)
            let unknownTail2 = leUInt32(bytes, tailStart + 12)
            instances.append(Instance(
                matrix: (floats[0], floats[1], floats[2], floats[3],
                         floats[4], floats[5], floats[6], floats[7],
                         floats[8], floats[9], floats[10], floats[11],
                         floats[12], floats[13], floats[14], floats[15]),
                objectIndex: objectIndex, typeOrMeshIndex: typeOrMeshIndex,
                unknownTail1: unknownTail1, unknownTail2: unknownTail2
            ))
        }
        return instances
    }

    /// One 16-byte quadword from an `OBJ0` entry's vertex-like data block:
    /// a leading control word (unparsed -- see below) followed by 3 floats
    /// that behave exactly like a position.
    public struct VertexQuadword {
        public let control: UInt32
        public let position: SIMD3<Float>
    }

    /// Extracts `count` 16-byte quadwords starting at `byteOffset` within
    /// an `OBJ0` section's payload as `(control:UInt32, position:xyz Float)`
    /// pairs. This is **not** a full `OBJ0` entry parser -- `OBJ0`'s
    /// per-entry byte length is not yet known (entries are variable-size,
    /// no offset table or self-length-prefix was found at their start, and
    /// this section is not a fixed-width record table like `MS00`/`INST`),
    /// so callers must supply the start offset and count explicitly rather
    /// than iterating entries automatically.
    ///
    /// What *is* confirmed, from real `AIRSHIP.GSC` bytes: at least the
    /// first ~39 quadwords of `OBJ0`'s first entry decode to a smoothly
    /// varying, visually coherent curved-surface vertex strip (plotted and
    /// visually inspected, not just numerically plausible) -- real
    /// geometry, not noise. The `control` word's low byte was observed
    /// counting down (3, 1, 1, 0, 0, ...) across the first few quadwords
    /// while its second byte flips from `0x80` to `0x00`, echoing this
    /// same codebase's own `ModelParser`/`SkinParser` strip-connectivity
    /// encoding (`(binaryW & 0xFF00) >> 8`) closely enough to be a
    /// plausible cousin format -- but that specific interpretation is an
    /// observation, not verified, so `control` is returned raw/unparsed.
    /// An earlier pass through this data mistakenly described the Y
    /// values as exact `sin(9n)` steps; a precise check showed that's
    /// false (the fit drifts progressively worse per step) -- the values
    /// are smoothly varying and plausible, not a confirmed closed-form
    /// curve, and are documented here only as strongly as that.
    public static func parseVertexQuadwords(_ payload: Data, byteOffset: Int, count: Int) throws -> [VertexQuadword] {
        let bytes = [UInt8](payload)
        guard byteOffset >= 0, count >= 0, byteOffset + count * 16 <= bytes.count else {
            throw ParseError.truncated
        }
        var result: [VertexQuadword] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let base = byteOffset + i * 16
            let control = leUInt32(bytes, base)
            let x = leFloat32(bytes, base + 4)
            let y = leFloat32(bytes, base + 8)
            let z = leFloat32(bytes, base + 12)
            result.append(VertexQuadword(control: control, position: SIMD3(x, y, z)))
        }
        return result
    }

    /// Decodes an `IABL` ("Instance Attribute BLock"?) section's payload
    /// the same way as ``parseMeshSet(_:)``: `count:UInt32LE` +
    /// `reserved:UInt32LE` + `count` fixed-width records. Confirmed
    /// cross-file: the width is **96 bytes** in all 3 real files checked
    /// (`FARM.GSC` 21 records, `HUB.GSC` 33, `CASTLE_C.GSC` 163 -- exact
    /// division every time, not approximate).
    ///
    /// Record internals not decoded, but worth noting for a future
    /// session: records are mostly zero with a small non-zero region
    /// starting around byte 64, containing a varying float that read as
    /// exact values like `0.3`/`0.5` in the samples checked (plausibly a
    /// per-object radius or scale), two constant exact `1.0`s nearby, and
    /// a small varying integer in the last 4 bytes -- an attribute-block
    /// shape consistent with the section's name, but not verified enough
    /// to commit to field offsets.
    ///
    /// **Ruled out, not just unattempted:** the sibling `ALIB` section
    /// ("ATTRIBUTE LIBrary"?) looked at first like the same fixed-width
    /// pattern (its leading count field divided its payload evenly in 2 of
    /// 3 files checked), but the resulting width was *different* between
    /// those two files (1456 in `FARM.GSC`, 5242 in `HUB.GSC`) and didn't
    /// divide evenly at all in the third (`CASTLE_C.GSC`) -- so `ALIB` is
    /// NOT a simple fixed-width record table, and no parser is provided
    /// for it here to avoid a future session re-deriving the same dead end.
    public static func parseAttributeBlock(_ payload: Data) throws -> (records: [Data], recordWidth: Int) {
        try parseMeshSet(payload) // identical framing -- count(u32) + reserved(u32) + count fixed records
    }

    /// A single record from a `SPEC` section: byte-for-byte the same
    /// 80-byte layout as `INST`'s records (4x4 transform + 4-field tail),
    /// but referencing `INST`, not `OBJ0` -- see ``parseSpecRecords(_:)``.
    public struct SpecRecord {
        public let matrix: (Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float,
                             Float, Float, Float, Float)
        /// Confirmed (checked every record in all 7 real files, not a
        /// sample): a valid index into the sibling `INST` section's own
        /// instance array, strictly increasing across `SPEC`'s record
        /// list (no duplicates, ascending order), and this record's
        /// `matrix` is byte-for-byte identical to
        /// `INST[referencedInstanceIndex]`'s matrix every time. `SPEC`
        /// reads as a curated pointer-list into `INST` -- e.g. in
        /// `AIRSHIP.GSC` it references instances `[34,35,36,37,38]` of
        /// 41 total. What selection criterion picks these specific
        /// instances is not visible in any decoded field yet.
        public let referencedInstanceIndex: UInt32
        /// Monotonically non-decreasing across the record list in every
        /// file checked, starting near 0 -- reads like a cumulative
        /// running count/offset into some other, not-yet-located
        /// per-instance sub-list (per-record deltas are fairly regular
        /// within a file but vary by file, e.g. mostly +7/+8 in one file,
        /// +9/+10/+11 in another). Checked and ruled out as an index into
        /// `SST0`, `MS00`, `IABL`, or `NTBL`. Genuinely unresolved.
        public let cumulativeOffset: UInt32
        /// Ruled out as a meaningful index or float: values are a mix of
        /// small plausible-looking integers and a narrow recurring band
        /// (~329,000,000-330,400,000 as `Int32`) consistent with a
        /// leftover/uninitialized heap pointer written to disk, not
        /// intentional per-record data. Exposed raw rather than
        /// interpreted.
        public let unknownTail3: UInt32
        public let unknownTail4: UInt32

        public var translation: SIMD3<Float> { SIMD3(matrix.12, matrix.13, matrix.14) }
    }

    /// Decodes a `SPEC` section's payload: `count:UInt32LE` +
    /// `reserved:UInt32LE` (confirmed `0` in all 7 files checked) +
    /// `count` fixed-width 80-byte records -- `payload.count == 8 +
    /// count*80` exactly (not just an even division) in all 7 files
    /// checked. Same on-disk record shape as `INST`
    /// (``parseInstances(_:)``), but see ``SpecRecord`` for why the
    /// fields mean something different here.
    public static func parseSpecRecords(_ payload: Data) throws -> [SpecRecord] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { throw ParseError.truncated }
        let count = Int(leUInt32(bytes, 0))
        let remaining = bytes.count - 8
        guard count > 0, remaining % count == 0, remaining / count == 80 else { return [] }

        var records: [SpecRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let start = 8 + i * 80
            var floats = [Float](repeating: 0, count: 16)
            for f in 0..<16 { floats[f] = leFloat32(bytes, start + f * 4) }
            let tailStart = start + 64
            let referencedInstanceIndex = leUInt32(bytes, tailStart)
            let cumulativeOffset = leUInt32(bytes, tailStart + 4)
            let unknownTail3 = leUInt32(bytes, tailStart + 8)
            let unknownTail4 = leUInt32(bytes, tailStart + 12)
            records.append(SpecRecord(
                matrix: (floats[0], floats[1], floats[2], floats[3],
                         floats[4], floats[5], floats[6], floats[7],
                         floats[8], floats[9], floats[10], floats[11],
                         floats[12], floats[13], floats[14], floats[15]),
                referencedInstanceIndex: referencedInstanceIndex, cumulativeOffset: cumulativeOffset,
                unknownTail3: unknownTail3, unknownTail4: unknownTail4
            ))
        }
        return records
    }

    /// A single texture upload found inside a `TST0` section. `TST0` turns
    /// out not to be a record table at all -- see ``scanTextureEntries(_:)``.
    public struct TextureEntry {
        /// Byte offset (within the `TST0` payload) of this entry's 20-byte
        /// trailer (`sizePlus`, `size`, `fmtA`, `fmtB`, `marker==76`).
        public let trailerOffset: Int
        public let width: Int
        public let height: Int
        /// `1` for indexed/paletted textures (`fmtA == fmtB` in the
        /// trailer) or `4` for direct-color RGBA (`fmtA == 2*fmtB`) --
        /// confirmed via `width*height*bytesPerPixel == size` holding
        /// exactly for every entry checked.
        public let bytesPerPixel: Int
        /// Byte range of this entry's raw texel data within the `TST0`
        /// payload (not decoded further -- still packed in whatever PS2 GS
        /// pixel layout the game used, e.g. indexed textures need their
        /// CLUT/palette to interpret, which is not yet located).
        public let texelDataRange: Range<Int>
    }

    /// Decodes one texture entry given the byte offset of its 20-byte
    /// trailer within a `TST0` payload. `TST0` is **not** a fixed-width
    /// record table (confirmed: `(payload.count-8)` does not divide its
    /// leading count field evenly in any file checked) -- it is a
    /// serialized stream of raw PS2 Graphics Synthesizer texture-upload
    /// command packets (`BITBLTBUF`/`TRXPOS`/`TRXREG`/`TRXDIR` GS register
    /// writes, the standard PS2 "upload image to VRAM" sequence), each
    /// followed by its raw texel bytes.
    ///
    /// Per-entry layout, all CONFIRMED across 201 real texture entries in
    /// 6 of 7 files checked (100% match, zero exceptions -- the 7th file,
    /// `E3HUB.GSC`, uses a variant without the padding this decoder
    /// anchors on; see ``scanTextureEntries(_:)``):
    /// ```
    /// [[0x0CD filler, 32 or 80 bytes]]
    /// trailer (20 bytes): sizePlus:u32 size:u32 fmtA:u32 fmtB:u32 marker:u32(==76)
    /// header (172 bytes): fixed GS-register block; only these fields are decoded:
    ///     word19 (byte 76):  GIFtag-like value; low 15 bits == NLOOP == size/16 + 5
    ///     word31 (byte 124): width (pixels)
    ///     word32 (byte 128): height (pixels)
    /// texelData: `size` bytes immediately after the header
    /// ```
    /// `sizePlus == size + 0xC4` and `width*height*bytesPerPixel == size`
    /// both held exactly for every one of the 201 checked entries -- not
    /// approximate, not "most of the time".
    public static func parseTextureEntry(_ payload: Data, trailerOffset: Int) throws -> TextureEntry {
        let bytes = [UInt8](payload)
        guard trailerOffset >= 0, trailerOffset + 20 + 172 <= bytes.count else { throw ParseError.truncated }
        let sizePlus = leUInt32(bytes, trailerOffset)
        let size = Int(leUInt32(bytes, trailerOffset + 4))
        let fmtA = leUInt32(bytes, trailerOffset + 8)
        let fmtB = leUInt32(bytes, trailerOffset + 12)
        guard sizePlus == UInt32(size) + 0xC4 else { throw ParseError.truncated }

        let headerStart = trailerOffset + 20
        let width = Int(leUInt32(bytes, headerStart + 124))
        let height = Int(leUInt32(bytes, headerStart + 128))
        let bytesPerPixel = fmtA == fmtB ? 1 : 4

        let texelStart = headerStart + 172
        guard texelStart + size <= bytes.count else { throw ParseError.truncated }
        return TextureEntry(trailerOffset: trailerOffset, width: width, height: height,
                             bytesPerPixel: bytesPerPixel, texelDataRange: texelStart..<(texelStart + size))
    }

    /// Scans a `TST0` payload for texture entries by searching for the
    /// `marker == 76` trailer signature at 4-byte-aligned offsets and
    /// validating each candidate via ``parseTextureEntry(_:trailerOffset:)``.
    ///
    /// **This is a heuristic scan, not a guaranteed-complete parser** --
    /// on the real `AIRSHIP.GSC` sample it found only 16 of the 42
    /// textures the section's own leading count field declares. The
    /// likely reason (not yet confirmed): some entries -- plausibly
    /// paletted textures with a companion CLUT/palette upload -- carry an
    /// extra register block this scan doesn't recognize, so it skips past
    /// them. A register-triplet count check in a separate file found more
    /// `TRXPOS`/`TRXREG`/`TRXDIR` triplets than `2 x declared count` in
    /// some files, consistent with that idea, but unconfirmed. Use this
    /// for "here are some real, individually-validated textures", not for
    /// "here is every texture in the file".
    public static func scanTextureEntries(_ payload: Data) -> [TextureEntry] {
        let bytes = [UInt8](payload)
        var entries: [TextureEntry] = []
        var offset = 16 // past the 16-byte TST0 header (count, reserved, word2, word3)
        while offset + 4 <= bytes.count {
            if leUInt32(bytes, offset) == 76, offset >= 16 {
                let trailerOffset = offset - 16
                if let entry = try? parseTextureEntry(payload, trailerOffset: trailerOffset) {
                    entries.append(entry)
                }
            }
            offset += 4
        }
        return entries
    }

    /// Decodes an `SST0` section's outer shape (`SST0` is always the last
    /// section in the file, i.e. a "footer"). CONFIRMED across the files
    /// checked: `blobLength:u32` at payload offset 4 exactly accounts for
    /// a byte range (`blob = payload[8..<8+blobLength]`), with whatever
    /// remains after that (`trailer`) always a small handful of bytes,
    /// never garbage-length.
    ///
    /// One recurring but NOT universal pattern worth flagging for a future
    /// session: in 3 of 5 files checked (`FARM.GSC`, `HUB.GSC`,
    /// `EARTH_B.GSC`), the trailer is exactly 12 bytes and its *last* 4
    /// bytes exactly equal this `SST0` section's own outer `length` field
    /// from the top-level container header (echoing the section's total
    /// size back into its own footer) -- independently re-verified before
    /// documenting this, not just taken from an agent report. But
    /// `CASTLE_C.GSC` has a shorter 8-byte trailer with no such echo,
    /// `JUNGLE_A.GSC` has no trailer at all (the blob accounts for every
    /// remaining byte), and `AIRSHIP.GSC`'s entire `SST0` is degenerate
    /// (`firstField`/`blobLength` both `0`, no blob, no trailer). So this
    /// function only decodes the confirmed outer split; the trailer-echo
    /// pattern is documented but not enforced/parsed, since it isn't
    /// universal.
    public static func parseFooterHeader(_ payload: Data) throws -> (firstField: UInt32, blob: Data, trailer: Data) {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return (0, Data(), Data()) }
        let firstField = leUInt32(bytes, 0)
        let blobLength = Int(leUInt32(bytes, 4))
        guard 8 + blobLength <= bytes.count else { throw ParseError.truncated }
        let blob = Data(bytes[8..<(8 + blobLength)])
        let trailer = Data(bytes[(8 + blobLength)...])
        return (firstField, blob, trailer)
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
