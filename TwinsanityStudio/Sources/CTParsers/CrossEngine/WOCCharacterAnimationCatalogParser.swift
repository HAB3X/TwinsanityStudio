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
