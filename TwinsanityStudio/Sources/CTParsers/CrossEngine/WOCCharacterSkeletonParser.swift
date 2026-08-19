import Foundation

/// Decodes a real joint hierarchy from one already-decompressed
/// `CHARS.DAT` entry (see `WOCCharacterArchiveParser` for the archive
/// container/decompression layer this builds on).
///
/// **CONFIRMED, very high confidence** -- corpus-validated across all 12
/// real "skeleton" entries in the archive (decompressed-header offset 4
/// `== 0` and offset 12 `== 0`, i.e. no mesh geometry -- see
/// `WOCCharacterArchiveParser`'s doc comment on the Format-A header
/// shape this refines), zero exceptions:
/// ```
/// Entry (decompressed) := totalSize:UInt32LE(==own length) 0:UInt32LE 0:UInt32LE 0:UInt32LE
///         field16:UInt32LE field20:UInt32LE
///         jointCount:UInt32LE tableAOffset:UInt32LE tableBOffset:UInt32LE tableCOffset:UInt32LE
///         0:UInt32LE tableDOffset:UInt32LE
///         nameTableOffset:UInt32LE nameTableLength:UInt32LE
///         ... (unrelated bytes before/around/between the tables above)
/// JointRecord := Bytes(96), see ``Joint`` for the two confirmed fields within it
/// ```
/// `tableAOffset`/`tableBOffset`/`tableCOffset`/`tableDOffset` are
/// **stored absolute byte offsets into the entry**, not fixed structural
/// positions -- confirmed by direct arithmetic: `tableAOffset +
/// jointCount*96 == tableBOffset`, and `tableBOffset + jointCount*64 ==
/// tableCOffset`, exactly, on every real skeleton entry checked (this is
/// `WOCCharacterArchiveParser`'s already-independently-confirmed "Table
/// A"/two 64-byte tables, now with their real addressing scheme pinned
/// down). Tables B/C (each `jointCount * 64` bytes -- plausibly bind-pose
/// or world transform matrices per joint, identity for the root joint in
/// samples checked, unconfirmed) and table D are not decoded by this
/// type. `field16`/`field20` correlate with something outside the scope
/// of skeleton entries (`WOCCharacterArchiveParser`'s own "N"/mesh-arc
/// count investigation) and are ignored here.
///
/// `nameTableOffset`/`nameTableLength` mark a packed, null-terminated
/// ASCII string table (e.g. entry 71, a real 47-joint Crash rig:
/// `"CrashBones\0Pelvis\0LeftLeg\0LeftKnee\0LeftAnkle\0LeftToe\0..."`) --
/// but `JointRecord.name` is resolved via each record's own absolute
/// name offset (below), not by walking this table in order, so this
/// range is informational rather than required for decoding.
///
/// Validated end-to-end on all 12 real skeleton entries: exactly one
/// root joint (`parentIndex == -1`) and zero invalid parent references
/// (every non-root `parentIndex` is a valid, already-defined, strictly
/// earlier joint index -- a real DAG) in every single one, including a
/// full 47-bone anatomically-correct Crash rig (`Pelvis -> LeftLeg ->
/// LeftKnee -> LeftAnkle -> LeftToe`, a mirrored `Right*` chain, `Back ->
/// UpperTorso -> NeckBase -> {LeftArm, RightArm, Face}`, finger and
/// spike/ear chains all correctly parented), a 3-joint creature rig
/// (`Mouse_Root -> Mouse_Tail`/`Mouse_Head`), and 8 single-bone prop
/// roots (`blue_root`, `bonus_gem_root`, `Crystal_Root`, ...).
public enum WOCCharacterSkeletonParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case notASkeletonEntry
    }

    /// One joint. Only the two confirmed fields within the real 96-byte
    /// record are exposed as typed properties -- see `raw` for the rest.
    public struct Joint {
        public let name: String
        /// `-1` for the root joint; otherwise a valid, strictly-earlier
        /// index into the same `Skeleton.joints` array (confirmed a real
        /// DAG on every sample checked -- see this file's own doc
        /// comment).
        public let parentIndex: Int
        /// The full 96-byte record. Byte 81 is a small flag (`8` on the
        /// two "material root"/entry-0-joint cases checked, `1`
        /// otherwise) -- real, structured, but not decoded further. The
        /// remaining ~90 bytes are undecoded.
        public let raw: Data
    }

    public struct Skeleton {
        public let joints: [Joint]
    }

    /// - Parameter decompressed: one entry's already-decompressed bytes
    ///   (see `WOCCharacterArchiveParser.decode(_:fileURL:)`).
    /// - Throws: ``ParseError/notASkeletonEntry`` if this entry doesn't
    ///   have the confirmed skeleton-entry header shape (most `CHARS.DAT`
    ///   entries are mesh or placeholder entries, not skeletons -- see
    ///   `WOCCharacterArchiveParser`'s doc comment on the three header
    ///   families).
    public static func parseSkeleton(_ decompressed: Data) throws -> Skeleton {
        let bytes = [UInt8](decompressed)
        guard bytes.count >= 56 else { throw ParseError.truncated }
        guard leUInt32(bytes, 0) == UInt32(bytes.count), leUInt32(bytes, 4) == 0, leUInt32(bytes, 12) == 0 else {
            throw ParseError.notASkeletonEntry
        }

        let jointCount = Int(leUInt32(bytes, 24))
        let tableAOffset = Int(leUInt32(bytes, 28))
        guard jointCount > 0, tableAOffset >= 0, tableAOffset + jointCount * 96 <= bytes.count else {
            throw ParseError.truncated
        }

        var joints: [Joint] = []
        joints.reserveCapacity(jointCount)
        for i in 0..<jointCount {
            let recordBase = tableAOffset + i * 96
            let nameOffset = Int(leUInt32(bytes, recordBase + 76))
            guard nameOffset >= 0, nameOffset < bytes.count else { throw ParseError.truncated }

            var cursor = nameOffset
            var nameBytes: [UInt8] = []
            while cursor < bytes.count, bytes[cursor] != 0 {
                nameBytes.append(bytes[cursor])
                cursor += 1
            }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let parentIndex = Int(Int8(bitPattern: bytes[recordBase + 80]))
            let raw = Data(bytes[recordBase..<(recordBase + 96)])
            joints.append(Joint(name: name, parentIndex: parentIndex, raw: raw))
        }
        return Skeleton(joints: joints)
    }

    private static func leUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
}
