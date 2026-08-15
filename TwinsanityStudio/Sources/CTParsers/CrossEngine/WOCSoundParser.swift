import Foundation

/// Decodes WoC's centralized sound archive: `SFX.DAT` (and the
/// structurally-identical `ATS.DAT`, which turned out to hold compiled
/// text scripts rather than audio -- same container, different payload).
/// Confirmed on the real disc: a plain offset-table archive of standard
/// Sony `VAGp`-header PS-ADPCM clips, PS2-sector-aligned (2048 bytes).
///
/// Independently re-verified against real bytes (not just an agent
/// report): the offset-table chain (`next.offset ==
/// roundup(prev.offset+prev.size, 2048)`) holds for all 781 consecutive
/// pairs in the real `SFX.DAT`, every VAG header's `data_size` field plus
/// its own 48-byte header exactly equals the outer table's `size` field
/// for every entry checked, and decoded PCM from several entries spread
/// across the whole file shows real-waveform statistics (wide dynamic
/// range, high lag-1 sample autocorrelation) rather than noise.
///
/// Per-level `.GSC` files carry no sound of their own -- every sound in
/// the game lives in this one archive.
public enum WOCSoundParser {
    public enum ParseError: Error, Equatable {
        case fileTooSmall
        case badTableSentinel
        case badVAGMagic
    }

    /// One playable clip: its byte range in the archive (`offset`/`size`
    /// span the 48-byte VAG header *and* the ADPCM payload together, as
    /// stored in the outer table) plus the sample rate read from its own
    /// VAG header at decode time.
    public struct Entry: Identifiable, Hashable {
        public var id: Int { index }
        public let index: Int
        public let offset: UInt32
        public let size: UInt32
    }

    /// Reads only the archive's 8-byte header plus its trailing table --
    /// megabytes of audio payload in between are never touched. Cheap
    /// enough to call on every launch against a 289MB real archive.
    public static func parseTable(fileURL: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        guard let headerData = try handle.read(upToCount: 8), headerData.count == 8 else {
            throw ParseError.fileTooSmall
        }
        let dataSize = headerData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }

        try handle.seek(toOffset: UInt64(dataSize))
        guard let tableHead = try handle.read(upToCount: 8), tableHead.count == 8 else {
            throw ParseError.fileTooSmall
        }
        let sentinel = tableHead.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        let count = tableHead.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard sentinel == 0xFFFFFFFF else { throw ParseError.badTableSentinel }

        guard let recordsData = try handle.read(upToCount: Int(count) * 16), recordsData.count == Int(count) * 16 else {
            throw ParseError.fileTooSmall
        }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        recordsData.withUnsafeBytes { raw in
            for i in 0..<Int(count) {
                let base = i * 16
                let offset = raw.loadUnaligned(fromByteOffset: base, as: UInt32.self)
                let size = raw.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)
                entries.append(Entry(index: i, offset: offset, size: size))
            }
        }
        return entries
    }

    /// One decoded clip: sample rate from the real VAG header, plus PCM16
    /// mono samples from the standard PS-ADPCM decode.
    public struct DecodedClip {
        public let sampleRate: UInt32
        public let samples: [Int16]
    }

    /// Reads exactly `entry.size` bytes at `entry.offset` and decodes
    /// them: 48-byte `VAGp` header (big-endian fields, standard Sony
    /// format) followed by 16-byte PS-ADPCM blocks (28 samples/block).
    public static func decode(_ entry: Entry, fileURL: URL) throws -> DecodedClip {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        guard let blob = try handle.read(upToCount: Int(entry.size)), blob.count >= 48 else {
            throw ParseError.fileTooSmall
        }
        guard blob.prefix(4).elementsEqual([0x56, 0x41, 0x47, 0x70]) else { // "VAGp"
            throw ParseError.badVAGMagic
        }
        let sampleRate = blob.withUnsafeBytes { raw -> UInt32 in
            let be = raw.loadUnaligned(fromByteOffset: 0x10, as: UInt32.self)
            return UInt32(bigEndian: be)
        }
        let adpcm = blob.suffix(from: 48)
        let samples = WOCADPCMDecoder.decode(adpcm)
        return DecodedClip(sampleRate: sampleRate, samples: samples)
    }
}
