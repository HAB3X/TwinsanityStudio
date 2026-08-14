import Foundation
import CTModels

public enum ISO9660WriterError: Error, LocalizedError, Equatable {
    /// The entry's declared extent (from its own directory record) or its
    /// own directory-record offset don't fit inside the image bytes
    /// actually supplied — a mismatched/corrupt image, not a real file to
    /// patch.
    case entryOutOfBounds

    public var errorDescription: String? {
        switch self {
        case .entryOutOfBounds: return "This entry's real on-disc location doesn't fit inside the supplied image — it may not be the same image this entry was read from."
        }
    }
}

/// Rebuilds a modified `.iso` image with one file's contents replaced —
/// the write-back counterpart to `ISO9660Reader`. Deliberately scoped to
/// plain `.iso` images only, not `.bin`/`.cue`: a raw-sector `.bin` image
/// additionally frames every 2048-byte logical sector inside a larger
/// (typically 2352-byte) raw sector with sync/header/ECC/EDC data that
/// would need to be correctly regenerated per sector on write — real,
/// separate work this doesn't attempt. Read a `.bin`/`.cue` pair through
/// `BinCueLogicalSource` as before; only rebuilding one back out isn't
/// supported here.
///
/// Two real strategies, chosen automatically by the new data's size —
/// standard ISO-9660 doesn't require a file's extent to be contiguous
/// with its own directory record, or with any other file, so neither
/// strategy needs to touch anything beyond the one directory record for
/// the file being replaced:
/// - **Same size or smaller**: patches the file's bytes in place at its
///   existing LBA (zero-padding the rest of its originally-reserved
///   sectors) and updates just the size field in its directory record.
///   No other bytes in the image move.
/// - **Larger**: appends the new data as fresh sectors onto the end of
///   the image, then patches the directory record's LBA *and* size to
///   point at the new location. The old sectors are simply orphaned
///   (unreferenced, not reclaimed) — real, but harmless: nothing in a
///   valid ISO-9660 volume can still reach them once the directory record
///   no longer points there.
public enum ISO9660Writer {
    private static let sectorSize = 2048

    /// - Parameters:
    ///   - entry: An `ISO9660Entry` read from `imageData` itself via
    ///     `ISO9660Reader` — its `lba`/`size`/`directoryRecordAbsoluteOffset`
    ///     all have to be real positions inside `imageData`, not a
    ///     different copy of the same disc.
    ///   - newData: The file's replacement contents.
    ///   - imageData: The full, flat, plain-`.iso` image bytes.
    /// - Returns: A new, complete image with the one file replaced.
    public static func replacingFile(_ entry: ISO9660Entry, with newData: Data, in imageData: Data) throws -> Data {
        var image = imageData
        if newData.count <= Int(entry.size) {
            try replaceInPlace(entry, with: newData, in: &image)
        } else {
            try appendAndRelocate(entry, with: newData, in: &image)
        }
        return image
    }

    private static func replaceInPlace(_ entry: ISO9660Entry, with newData: Data, in image: inout Data) throws {
        let byteOffset = Int(entry.lba) * sectorSize
        // The number of sectors originally reserved for this file — the
        // space available to zero-pad into without touching whatever
        // follows.
        let reservedSpan = sectorCount(for: Int(entry.size)) * sectorSize
        guard byteOffset >= 0, byteOffset + reservedSpan <= image.count else {
            throw ISO9660WriterError.entryOutOfBounds
        }
        var padded = newData
        padded.append(Data(repeating: 0, count: max(0, reservedSpan - newData.count)))
        let range = (image.startIndex + byteOffset)..<(image.startIndex + byteOffset + reservedSpan)
        image.replaceSubrange(range, with: padded)
        try patchDirectoryRecord(at: entry.directoryRecordAbsoluteOffset, lba: entry.lba, size: UInt32(newData.count), in: &image)
    }

    private static func appendAndRelocate(_ entry: ISO9660Entry, with newData: Data, in image: inout Data) throws {
        // Sector-align the image first — every real ISO-9660 image already
        // is, but this keeps the new LBA meaningful even if it somehow
        // weren't.
        let paddingToAlign = (sectorSize - (image.count % sectorSize)) % sectorSize
        if paddingToAlign > 0 { image.append(Data(repeating: 0, count: paddingToAlign)) }
        let newLBA = UInt32(image.count / sectorSize)

        var padded = newData
        let paddedSize = sectorCount(for: newData.count) * sectorSize
        padded.append(Data(repeating: 0, count: paddedSize - newData.count))
        image.append(padded)

        try patchDirectoryRecord(at: entry.directoryRecordAbsoluteOffset, lba: newLBA, size: UInt32(newData.count), in: &image)
    }

    private static func sectorCount(for byteCount: Int) -> Int {
        max(1, (byteCount + sectorSize - 1) / sectorSize)
    }

    /// Overwrites the LBA (record bytes 2-9) and size (bytes 10-17)
    /// fields of one directory record in place — both fields are stored
    /// twice, little-endian then big-endian (ECMA-119 7.3.3/7.3.1), so
    /// both copies get written, not just the little-endian half
    /// `ISO9660Reader` reads.
    private static func patchDirectoryRecord(at offset: Int, lba: UInt32, size: UInt32, in image: inout Data) throws {
        guard offset >= 0, offset + 34 <= image.count else { throw ISO9660WriterError.entryOutOfBounds }
        let base = image.startIndex + offset
        writeBothEndianUInt32(lba, at: base + 2, in: &image)
        writeBothEndianUInt32(size, at: base + 10, in: &image)
    }

    private static func writeBothEndianUInt32(_ value: UInt32, at offset: Int, in image: inout Data) {
        let le: [UInt8] = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        for (i, byte) in le.enumerated() { image[offset + i] = byte }
        for (i, byte) in le.reversed().enumerated() { image[offset + 4 + i] = byte }
    }
}
