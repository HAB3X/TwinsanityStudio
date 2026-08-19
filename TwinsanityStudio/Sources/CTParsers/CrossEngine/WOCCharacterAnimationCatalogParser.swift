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
