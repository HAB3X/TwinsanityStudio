import Foundation

/// Decodes the real, name-indexed animation clip catalog found in most
/// `CHARS.DAT` entries (see `WOCCharacterArchiveParser` for the archive
/// container/decompression layer this builds on).
///
/// **CONFIRMED, high confidence** -- validated across 64 real multi-clip
/// catalog entries plus 78 real single-clip entries (the `WOCCharacter
/// ArchiveParser`-documented "Format B"/"dummy"-placeholder shape turns
/// out to be the `clipCount == 1` degenerate case of this exact same
/// template, unifying what looked like two separate entry families into
/// one):
/// ```
/// Entry (decompressed) := clipCount:UInt32LE
///         BlobOffset(clipCount)   -- UInt32LE, byte offset within the entry where that clip's data starts
///         NameOffset(clipCount)   -- UInt32LE, byte offset within the entry of that clip's null-terminated ASCII name
///         [name strings, packed, null-terminated]
///         [clip blobs, back-to-back in BlobOffset order -- clip i's length is
///          BlobOffset[i+1] - BlobOffset[i], or (entry length - BlobOffset[i]) for the last clip]
/// ```
/// Real clip names confirmed across multiple real characters: a 47-joint
/// Crash rig's own catalog (entry 66, 82 clips) includes
/// `A\BodySlam`, `A\Run`, `A\RunJump`, `A\SlidAttk`, `A\Sprint`,
/// `A\TipToe`, `A\Walk`, `B\Die`, `C\MechRun`, `C\GldrIdle`, `C\CptrIdle`,
/// `D\SubIdle`, `E\KartJump`, `E\BzIdle`, `F\JpDeath`, `F\RunLL` --
/// Crash's full moveset across every WoC gameplay mode (on-foot,
/// mech/glider/copter, submarine, kart, jetpack). Smaller catalogs (e.g.
/// a 2-clip `\attack`/`\idle` pair) validate the same structure at a
/// much smaller scale. This entry sits 5 slots before the confirmed
/// 47-joint Crash skeleton (`WOCCharacterSkeletonParser`, entry 71) in
/// the archive, though no literal skeleton back-reference was found
/// inside a catalog entry -- the catalog-to-skeleton association is
/// positional (same archive neighborhood), not stored explicitly.
///
/// **What's NOT decoded**: each clip's blob -- the actual per-joint
/// keyframe/curve data that would drive real animation playback. A
/// naive float32 quaternion scan (checking `x²+y²+z²+w² ≈ 1`) and a
/// naive int16 fixed-point scan both found nothing; the blob's byte
/// pattern (long zero runs punctuated by sparse nonzero bytes) reads as
/// a compressed/delta-coded bitstream rather than a plain per-frame
/// transform array. `Clip.blob` is exposed as raw `Data` rather than
/// guessed at.
///
/// **A concrete, byte-exact candidate hypothesis (found post-hoc, NOT yet
/// checked against real bytes -- disc access was unavailable when this
/// was written)**: `Games Files/Reference Files/OpenCrashWOC-main/code/src/nu3dx/nuanim.c`/`.h`
/// contains WoC's real on-disk animation-curve reader, `NuAnimDataRead`
/// (not just the pointer-relocation code found earlier in
/// `GHG_GSC_FUNCTIONS.txt`'s `ReadAnimationLibrary` -- this is the actual
/// byte-level decoder). Its on-disk sequence, read verbatim from the
/// function body:
/// ```
/// AnimData := nameLen:Int32LE Name(nameLen)? time:Float32LE nchunks:Int32LE
///             Chunk(nchunks)
/// Chunk    := numnodes:Int32LE
///             keyBlobLen16:Int32LE Bytes(keyBlobLen16*16)?   -- raw nuanimkey_s[]: {time,dtime,c,d}:Float32LE ×4 each
///             curveBlobLen16:Int32LE Bytes(curveBlobLen16*16)?  -- raw nuanimcurve_s[]: {mask:UInt32LE, keyPtrPlaceholder:UInt32LE, numkeys:UInt32LE, flags:UInt32LE} each
///             CurveSet(numnodes)
/// CurveSet := curveCount:Int8
///             (flags:Int32LE constants:Float32LE[curveCount])?   -- present only if curveCount != 0
/// ```
/// where a `constants[i] == FLOAT_MAX` sentinel marks "this is a real
/// animated curve, consume the next entry from the flat `curves`/`keys`
/// arrays" rather than a plain constant value -- i.e. the same
/// count-then-conditional-blob, sentinel-gated-variant shape already
/// familiar from this codebase's own `TAS0`/`ALIB` work, not a new
/// pattern class. `nuanimkey_s`'s `{time, dtime, c, d}` fields are
/// confirmed (by `NuAnimCurveCalcVal2`'s real interpolation math, not
/// just the struct declaration) to be a Hermite-style cubic curve segment
/// (`c`/`d` are tangent/value terms), and per-joint curve-set component
/// order is fixed: indices 0-2 = translation XYZ, 3-5 = rotation XYZ
/// (stored in degrees, converted via a `10430.378`-scale fixed-point
/// constant before use), 6-8 = scale XYZ.
///
/// There's also a documented **compressed variant** (`nuanimdata2_s` /
/// `nuanimcurve2_s` / `nuanimcurvedata_s`, same header) using a
/// bitmask-plus-popcount key lookup (`BitCountTable`) and one of three
/// quantized key formats (`NUANIMKEYBIG_s` 16 bytes, `NUANIMKEYINTEGER_s`
/// 8 bytes, `NUANIMKEYSMALL_s` 4 bytes -- `SMALL` is explicitly
/// unimplemented even in this reference source: `NuErrorProlog(...,"not
/// supporting NUANIMKEYTYPE_SMALL yet")`) -- a materially closer match to
/// this catalog's own "long zero runs punctuated by sparse nonzero bytes"
/// observation than the plain variant above, and the leading hypothesis
/// for what `Clip.blob` actually is. **Do not implement against this
/// hypothesis without real-byte verification first** -- it comes from a
/// different file family (`.GSC`-embedded `ALIB` data) in the same engine
/// lineage, not from a `CHARS.DAT` clip blob directly, and neither
/// variant has been checked against a single real `Clip.blob` byte yet.
///
/// **Update, checked against real bytes**: the plain `nuanimdata_s`
/// hypothesis above is now **refuted** for `Clip.blob` -- direct
/// inspection of real blobs shows the first several dozen bytes are
/// byte-*identical* across clips with different names and durations
/// (`\attack` vs `\idle`, and separately `A\BodySlam`/`A\Crawl`/
/// `A\CrchDwn`/`A\Land` from an unrelated 82-clip catalog), which is
/// impossible for a format whose first field is a per-clip name length +
/// name. `VIFInterpreter` (this codebase's existing, trusted PS2 VU
/// microcode interpreter, built for the original Twinsanity's own VIF
/// packet format) was also tried directly against a raw `Clip.blob`: it
/// completes without error but decodes zero real vectors, using only the
/// blob's first ~144 bytes under its own DMA-tag-style `qwc`-in-low-16-
/// bits wrapper convention -- inconclusive, not a confirmation; the
/// wrapper convention doesn't have to be the same between the two games.
///
/// **Update, broader follow-up sample (272 clips across 141 distinct real
/// catalog entries, blob sizes 1,472-33,296 bytes)** -- this sharpens
/// every field above with real numbers instead of an 8-blob guess:
/// - The **template prefix ends at exactly byte 240**, confirmed stable
///   across all 141 catalogs (bytes 16-239 identical in every one of the
///   272 samples once the known-varying fields below are masked out).
///   **Byte 240 itself is a hard constant, `0xC4`, in all 272 samples,
///   zero exceptions** -- a real fixed marker byte worth checking as a
///   validity/resync anchor. Byte 241 is the first byte that diverges in
///   most samples (68%), matching the earlier ~241 estimate almost
///   exactly.
/// - The offset-0 byte is **not a free-varying field**: across the whole
///   sample it takes exactly 3 values (`0x02`, `0x04`, `0x08`), and it
///   correlates with a blob-size bucket (`0x02` only appears on 1-clip
///   `dummy` placeholder catalogs, 1,472-1,552 bytes; `0x04` on
///   2,528-2,608-byte blobs; `0x08` on everything 4,544 bytes and up).
/// - The offset-2 `UInt16LE` is **not** proportional to `blob.count`
///   directly, but `blob.count` divided by it is *always an exact
///   integer* with zero remainder (checked on 60 samples) -- i.e. it's a
///   real block/chunk count, just one whose block size varies per clip
///   rather than being a fixed page size. It moves together with the
///   offset-0 byte (`2↔1`, `4↔1`, `8↔{1,2,4,8}`).
/// - The offset-8 8-byte field is **not** a per-entry hash or pointer as
///   the smaller sample left open -- across 25 distinct catalog entries
///   it takes only 3 distinct values total (all-zero in 21/25 entries;
///   `44 80 65 DC 51 06 E9 18` in 3 entries with otherwise-unrelated clip
///   names/sizes; one more value in a single entry). Confirmed constant
///   within every multi-clip entry checked (63/63, zero exceptions) --
///   still catalog-level, but it reads as a small categorical tag (e.g.
///   a character-class/rig-family flag), not a per-catalog unique ID.
/// - The dense-divergence region from byte 241 onward shows **no
///   plausible float32 data anywhere checked** (every 4-byte window read
///   as float32 produced denormals or implausible exponents, never a
///   sane time/rotation/position range) -- int32 interpretation is far
///   more plausible, including a real recurring pattern: small
///   ascending-by-1 bytes (`0x51`, `0x52`, `0x53`) at regular ~20-byte
///   intervals, present at matching relative offsets in both the
///   shortest and longest sampled blobs. This looks like a repeating
///   fixed sub-record (index/tag bytes), not raw motion data -- real,
///   size-and-name-dependent content divergence doesn't become dense
///   until byte 256 (82% of samples diverge there). **If this is
///   float-encoded motion data at all, it most likely starts later than
///   byte 400**, not right after the byte-240 template.
/// - Correlating blob size against nearby skeletons' joint counts (via
///   ``WOCCharacterSkeletonParser``) was tried and came up empty: the
///   same 47-joint rig sits near several catalogs with wildly different
///   per-clip blob sizes (2,576-16,944 bytes), so blob size is not a
///   clean `jointCount x frames x constant` -- a real negative result,
///   not a gap to fill in later.
///
/// Still genuinely open: what's actually stored in the byte 256-400+
/// region. The "PS2 VU microcode-upload header" reading of the byte
/// 0-240 template remains a plausible shape (not a confirmed format).
/// **Update, the `0x51`/`0x52`/`0x53` pattern characterized further**
/// (17 clips across 7 catalogs): it is NOT 3 adjacent bytes -- it's a
/// single byte position, at a fixed intra-record offset, whose VALUE
/// climbs by exactly 1 across 3 consecutive 16-byte-stride records
/// (`81, 82, 83` decimal). Its own position is phase-locked: in all 17
/// samples the last ("83") record starts at a byte offset satisfying
/// `(offset - 248) % 16 == 0` exactly -- i.e. `248 = 240 + 8` is a real
/// second boundary, 8 bytes into the first row after the byte-240
/// template marker, and every row from there is a uniform 16-byte
/// record. The row *count* before reaching this ascending 3-row tail
/// varies per clip (7, 9, or 11 rows seen in the 17-sample check).
///
/// **Update, full-corpus sweep (261 clips, every one of the 141 real
/// catalog entries in `CHARS.DAT`)** -- this table's real shape is now
/// fully characterized end-to-end, zero exceptions:
/// - Row 0: a small tag correlated with the already-known byte-0/byte-2
///   header fields (`2`, `2`, or `4` depending on that clip's `(byte0,
///   u16@2)` bucket).
/// - Rows 1 through N-5: **exactly zero**, 261/261, zero exceptions.
/// - Row N-4: a hard constant, `0x0E` (14), 261/261.
/// - Rows N-3, N-2, N-1: a hard constant **3-row terminator**, `0x51,
///   0x52, 0x53` (81/82/83) -- so the "ascending pattern" from the
///   smaller sample was an illusion of only ever having sampled the
///   tail; it is a fixed marker, not a per-clip-varying sequence.
/// - **What determines row count**: not blob size directly and not
///   nearby skeletons' joint counts (tried, clean negative -- row counts
///   of 7-14 don't track a 47-joint rig at all). The real relationship:
///   define `remainder = blobSize - 248 - 16*rowCount` (the byte count
///   from the end of this table to the end of the blob) -- within each
///   `(byte0, u16@2)` bucket, `remainder` is a **perfectly constant**
///   value (e.g. `(8,2)` bucket: always exactly `8280`, 81/81 samples),
///   meaning row count is the one real free variable per clip within its
///   size class, trading off exactly against the fixed-size region that
///   follows. Working hypothesis, not yet independently confirmed: row
///   count is a per-clip *animated-node count* (a subset of the full
///   skeleton, not the whole rig).
/// - **What immediately follows the table**: 228/261 samples (87%) are 16
///   bytes of pure zero; the other 33/261 show recurring nibble-repeat /
///   solid-`0xFF`-run patterns (e.g. `11 11 11...`, `FF FF FF...`) more
///   consistent with flag/bitmask data than with float-encoded motion --
///   a real structural echo of this doc's own already-documented
///   `nuanimcurve2_s` compressed-variant hypothesis (bitmask-plus-
///   popcount key lookup), worth chasing next over the plain variant.
///
/// **Update: characterized the region immediately after the table**
/// (10 clips, 6 catalogs). It's a long run of zero bytes -- much longer
/// than previously checked, often 500-2000+ bytes -- followed by a
/// sparse pattern that recurs identically in every sample: a small 1-2
/// byte nonzero value (values seen: `0x1f10`, `0x0ccc`, `0x0010`,
/// `0x0080`, `0x0422`, `0xfff3`, `0x3f70`, `0x0001`, `0x0210`, `0x0008`),
/// always preceded by at least 16 bytes of zero and followed by more
/// zero -- i.e. real, sparse, 16-byte-aligned data, not raw motion
/// floats. **The position of this first sparse value is highly
/// variable** (33 to 2191 bytes past the table across the 10 samples,
/// with no correlation found to blob size, row count, or table length)
/// -- a real, load-bearing signal that this region's length is itself
/// per-clip data (plausibly proportional to that clip's real animation
/// duration/frame count), not a fixed-size header field. This is the
/// clearest evidence yet for genuinely sparse, delta/quantized-coded
/// motion data starting somewhere in this region -- consistent with
/// both this doc's original "long zero runs punctuated by sparse
/// nonzero bytes" observation (from before the byte-248 table was even
/// found) and the `nuanimcurve2_s` compressed-variant hypothesis
/// (bitmask-plus-popcount key lookup over quantized keys). **Still not
/// decoded**: what the sparse 1-2 byte values themselves mean (no
/// quantized-key format tried yet reproduces them cleanly), and where
/// exactly real motion data starts vs. more structural padding --
/// pinning that down needs a systematic per-frame-time correlation (do
/// sparse-value positions align with real keyframe times for a clip
/// whose duration is independently known), not yet attempted.
///
/// **Bottom line**: the byte-248 table is a small, fixed-shape per-clip
/// header -- not the motion data itself. The real keyframe/curve payload
/// almost certainly starts somewhere in the sparse region just
/// characterized, but its own internal format is still genuinely open.
public enum WOCCharacterAnimationCatalogParser {
    public enum ParseError: Error, Equatable {
        case truncated
    }

    public struct Clip {
        public let name: String
        /// The clip's raw data region -- real byte range, undecoded
        /// content. See this type's own doc comment for what's been
        /// ruled out as its internal encoding.
        public let blob: Data
    }

    public static func parseCatalog(_ decompressed: Data) throws -> [Clip] {
        let bytes = [UInt8](decompressed)
        guard bytes.count >= 4 else { throw ParseError.truncated }
        let clipCount = Int(leUInt32(bytes, 0))
        guard clipCount > 0, clipCount < 10_000 else { throw ParseError.truncated }

        let blobOffsetsTableStart = 4
        let nameOffsetsTableStart = blobOffsetsTableStart + clipCount * 4
        guard nameOffsetsTableStart + clipCount * 4 <= bytes.count else { throw ParseError.truncated }

        var blobOffsets: [Int] = []
        var nameOffsets: [Int] = []
        blobOffsets.reserveCapacity(clipCount)
        nameOffsets.reserveCapacity(clipCount)
        for i in 0..<clipCount {
            blobOffsets.append(Int(leUInt32(bytes, blobOffsetsTableStart + i * 4)))
            nameOffsets.append(Int(leUInt32(bytes, nameOffsetsTableStart + i * 4)))
        }

        var clips: [Clip] = []
        clips.reserveCapacity(clipCount)
        for i in 0..<clipCount {
            let nameOffset = nameOffsets[i]
            guard nameOffset >= 0, nameOffset < bytes.count else { throw ParseError.truncated }
            var cursor = nameOffset
            var nameBytes: [UInt8] = []
            while cursor < bytes.count, bytes[cursor] != 0 {
                nameBytes.append(bytes[cursor])
                cursor += 1
            }
            let name = String(decoding: nameBytes, as: UTF8.self)

            let blobStart = blobOffsets[i]
            let blobEnd = i + 1 < clipCount ? blobOffsets[i + 1] : bytes.count
            guard blobStart >= 0, blobEnd >= blobStart, blobEnd <= bytes.count else { throw ParseError.truncated }
            let blob = Data(bytes[blobStart..<blobEnd])

            clips.append(Clip(name: name, blob: blob))
        }
        return clips
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
