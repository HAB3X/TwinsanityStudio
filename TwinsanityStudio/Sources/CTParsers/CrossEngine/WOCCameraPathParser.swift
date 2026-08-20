import Foundation

/// Decoder for WoC `.VIS` files -- and the one real `.POO` file
/// (`WEST_A.POO`), confirmed to be the exact same format under a
/// different extension (same header shape, same `weecam_*` string
/// vocabulary). Despite the `.VIS` extension, **this is not a
/// visibility/PVS system** -- an earlier survey's "per-instance
/// visibility bitfield" hypothesis is directly ruled out (the payload is
/// float/coordinate-typed, not boolean-packed) and superseded by real
/// evidence of what it actually is.
///
/// **CONFIRMED, high confidence**: every real file (14 `.VIS` + 1
/// `.POO`, zero exceptions) ends in a packed, null-terminated ASCII
/// string table whose real entries are literal named camera path
/// entry points -- `weecam_mid_00`, `weecam_in_bonus`,
/// `weecam_out_bonus`, `weecam_mid_bonus`, `weecam_mid_death`,
/// `weecam_in_death`, `weecam_in_gem`, `weecam_mid_gem`,
/// `weecam_right_bonus` -- "weecam" being WoC's small/cutscene camera.
/// This is real, named **cinematic camera path data**: bonus-round,
/// gem, and death-respawn camera sequences per level, not a spatial
/// visibility system.
/// ```
/// File := sentinel:UInt32LE(==0xFFFFFFFF) nodeCount:UInt32LE headerB:UInt32LE
///         body:Bytes(...)   -- a node/path graph, see below
///         stringCount:UInt32LE
///         String(stringCount)   -- null-terminated ASCII, packed, ends exactly at EOF
/// ```
/// The string table's own leading count is located unambiguously:
/// scanning for the offset where reading that many consecutive
/// null-terminated printable-ASCII strings lands EXACTLY on end-of-file
/// -- verified to find exactly one such offset in all 15 real files,
/// with the real camera-path names as a result (a naive backward scan
/// for "the last run of printable-or-null bytes" is genuinely ambiguous
/// here, since a small count's own zero-padding bytes are
/// indistinguishable from string null-terminators; this scan-forward
/// exact-EOF-landing approach avoids that ambiguity entirely).
///
/// **Not confirmed**: `headerB`'s meaning (checked and ruled out as a
/// simple record count or the string count). The body between the fixed
/// 12-byte header and the string table is a real node/path graph --
/// cross-referenced against that same level's real `INST` world-space
/// coordinate range (via `WOCContainerParser.parseInstances`) and
/// confirmed to contain genuinely spatial float data in the same
/// world-space envelope, plus what looks like a real index/edge table
/// (`4 + nodeCount*16` bytes immediately before the string count, one
/// 16-byte record per node) -- but the index table's own per-record
/// field meanings, and the graph body's exact internal framing, aren't
/// pinned down precisely enough to expose as typed data yet (one real
/// file, `TOONARMY.VIS`, doesn't even fit the uniform 16-byte-per-node
/// index-record width other files do). `body` is exposed raw rather
/// than guessed at.
public enum WOCCameraPathParser {
    public enum ParseError: Error, Equatable {
        case truncated
        case badSentinel
        case stringTableNotFound
    }

    public struct File {
        public let nodeCount: UInt32
        /// Header's third `UInt32` field -- present and real, but its
        /// meaning is not confirmed (checked and ruled out as a simple
        /// record/string count).
        public let headerB: UInt32
        /// Everything between the 12-byte header and the string table --
        /// a real node/path graph (confirmed spatial, real index-table
        /// framing) that isn't decoded at the field level yet. See this
        /// type's own doc comment.
        public let body: Data
        /// Real, decoded named camera path entry points (e.g.
        /// `"weecam_mid_bonus"`).
        public let cameraPathNames: [String]
    }

    public static func parse(_ data: Data) throws -> File {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { throw ParseError.truncated }
        guard leUInt32(bytes, 0) == 0xFFFFFFFF else { throw ParseError.badSentinel }
        let nodeCount = leUInt32(bytes, 4)
        let headerB = leUInt32(bytes, 8)

        guard let (stringTableOffset, names) = findStringTable(bytes) else {
            throw ParseError.stringTableNotFound
        }
        let body = Data(bytes[12..<stringTableOffset])
        return File(nodeCount: nodeCount, headerB: headerB, body: body, cameraPathNames: names)
    }

    /// Scans every 4-byte-aligned offset for the one where "read a
    /// `UInt32` count, then that many null-terminated printable-ASCII
    /// strings" lands exactly on end-of-file. Real files have exactly
    /// one such offset (verified on all 15 real files); this is the
    /// count field's own real position, not a coincidence -- a false
    /// positive would need arbitrary bytes to both look like a plausible
    /// count AND have the following data resolve to N valid strings AND
    /// land exactly at EOF, which doesn't happen in real data.
    private static func findStringTable(_ bytes: [UInt8]) -> (offset: Int, names: [String])? {
        var offset = 12
        while offset + 4 <= bytes.count {
            defer { offset += 4 }
            let count = Int(leUInt32(bytes, offset))
            guard count > 0, count < 1000 else { continue }
            guard let names = tryParseStrings(bytes, from: offset + 4, count: count) else { continue }
            return (offset, names)
        }
        return nil
    }

    private static func tryParseStrings(_ bytes: [UInt8], from start: Int, count: Int) -> [String]? {
        var cursor = start
        var names: [String] = []
        names.reserveCapacity(count)
        for _ in 0..<count {
            let stringStart = cursor
            while cursor < bytes.count, bytes[cursor] != 0 {
                guard bytes[cursor] >= 0x20, bytes[cursor] < 0x7F else { return nil }
                cursor += 1
            }
            guard cursor < bytes.count, cursor > stringStart else { return nil }
            names.append(String(decoding: bytes[stringStart..<cursor], as: UTF8.self))
            cursor += 1 // skip the null terminator
        }
        guard cursor == bytes.count else { return nil }
        return names
    }

    private static func leUInt32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(b[offset]) | (UInt32(b[offset + 1]) << 8) | (UInt32(b[offset + 2]) << 16) | (UInt32(b[offset + 3]) << 24)
    }
}
