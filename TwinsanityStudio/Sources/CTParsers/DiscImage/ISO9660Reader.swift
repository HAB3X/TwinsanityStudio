import Foundation
import CTModels

public enum ISO9660Error: Error, Equatable {
    case notAnISO9660Image
}

/// One real entry from a mounted ISO-9660 volume's directory tree —
/// `lba`/`size` are the record's actual on-disc extent location/length,
/// used by `ISO9660Reader.readFile` to pull the real bytes back out.
public struct ISO9660Entry: Sendable, Identifiable {
    public let id = UUID()
    public var name: String
    public var isDirectory: Bool
    public var lba: UInt32
    public var size: UInt32
    public var children: [ISO9660Entry]

    public init(name: String, isDirectory: Bool, lba: UInt32, size: UInt32, children: [ISO9660Entry] = []) {
        self.name = name
        self.isDirectory = isDirectory
        self.lba = lba
        self.size = size
        self.children = children
    }
}

/// Reads a real ISO-9660 (ECMA-119) volume — the standard, publisher-
/// agnostic CD-ROM filesystem every PS2 disc image uses at its root, not
/// anything specific to Twinsanity. "Native ISO & BIN/CUE Disc Image
/// Mounting" (Task 7) — this is what lets a `.iso`/`.bin`+`.cue` be
/// mounted and its real contents (including a real `SYSTEM.CNF`, see
/// `SystemCNFParser`) browsed at all.
///
/// Deliberately narrow: Level 1/2 primary volume descriptor + directory
/// records only, no Rock Ridge/Joliet extensions (a PS2 disc's file tree
/// is plain 8.3-ish ISO-9660, not a Unix/Windows-authored one) and no
/// write-back — repacking a modified image back into a bootable disc is
/// real, separate work this doesn't attempt.
public enum ISO9660Reader {
    private static let sectorSize = 2048
    private static let volumeDescriptorStartSector = 16
    private static let cd001 = Data("CD001".utf8)

    public static func readRootDirectory(from source: any LogicalSectorSource) throws -> ISO9660Entry {
        guard let pvd = findPrimaryVolumeDescriptor(in: source) else {
            throw ISO9660Error.notAnISO9660Image
        }
        // The Root Directory Record is embedded directly in the PVD at
        // byte offset 156, always exactly 34 bytes (ECMA-119 8.4.24).
        let rootRecord = pvd.subdata(in: (pvd.startIndex + 156)..<(pvd.startIndex + 156 + 34))
        guard let rootLBA = readUInt32LE(rootRecord, at: 2), let rootSize = readUInt32LE(rootRecord, at: 10) else {
            throw ISO9660Error.notAnISO9660Image
        }
        return readDirectory(name: "", lba: rootLBA, size: rootSize, source: source)
    }

    /// Extracts `entry`'s real file bytes straight from the volume.
    public static func readFile(_ entry: ISO9660Entry, from source: any LogicalSectorSource) -> Data? {
        guard !entry.isDirectory else { return nil }
        var result = Data()
        // `entry.size` comes straight from the directory record — a
        // corrupt/malformed image could declare a bogus huge size with no
        // real sectors behind it. Cap the up-front reservation at what
        // `source` could possibly contain, so a bad size can't force a
        // multi-gigabyte blind allocation before the per-sector read below
        // (which already returns nil on a genuinely out-of-range sector)
        // gets a chance to fail gracefully.
        let maxPossibleBytes = source.sectorCount * sectorSize
        result.reserveCapacity(min(Int(entry.size), maxPossibleBytes))
        let sectorCount = max(1, Int((Int(entry.size) + sectorSize - 1) / sectorSize))
        for i in 0..<sectorCount {
            guard let sector = source.sector(Int(entry.lba) + i) else { return nil }
            result.append(sector)
        }
        return result.prefix(Int(entry.size))
    }

    private static func findPrimaryVolumeDescriptor(in source: any LogicalSectorSource) -> Data? {
        var index = volumeDescriptorStartSector
        // Real bound: the Volume Descriptor Set is always terminated
        // (type 255) well within a few sectors on every real disc; this
        // just keeps a malformed image from spinning forever.
        while index < volumeDescriptorStartSector + 32 {
            guard let sector = source.sector(index) else { return nil }
            let type = sector[sector.startIndex]
            let identifier = sector.subdata(in: (sector.startIndex + 1)..<(sector.startIndex + 6))
            guard identifier == cd001 else { return nil }
            if type == 1 { return sector }
            if type == 255 { return nil } // Volume Descriptor Set Terminator
            index += 1
        }
        return nil
    }

    private static func readDirectory(name: String, lba: UInt32, size: UInt32, source: any LogicalSectorSource) -> ISO9660Entry {
        var extent = Data()
        let sectorCount = max(1, Int((Int(size) + sectorSize - 1) / sectorSize))
        for i in 0..<sectorCount {
            guard let sector = source.sector(Int(lba) + i) else { break }
            extent.append(sector)
        }

        var children: [ISO9660Entry] = []
        var offset = 0
        while offset < extent.count {
            let recordLength = Int(extent[extent.startIndex + offset])
            guard recordLength > 0 else {
                // Zero padding runs to the next sector boundary within a
                // multi-sector directory extent — skip straight to it
                // rather than stepping one zero byte at a time.
                let nextBoundary = ((offset / sectorSize) + 1) * sectorSize
                guard nextBoundary > offset, nextBoundary <= extent.count else { break }
                offset = nextBoundary
                continue
            }
            guard offset + recordLength <= extent.count else { break }
            let record = extent.subdata(in: (extent.startIndex + offset)..<(extent.startIndex + offset + recordLength))
            offset += recordLength

            guard record.count >= 33 else { continue }
            let fileIDLength = Int(record[record.startIndex + 32])
            guard record.count >= 33 + fileIDLength else { continue }
            let fileIDBytes = record.subdata(in: (record.startIndex + 33)..<(record.startIndex + 33 + fileIDLength))
            // Identifier byte 0x00 is "." (self), 0x01 is ".." (parent) —
            // real ECMA-119 special entries every directory carries,
            // skipped here rather than shown as regular children.
            if fileIDLength == 1, let first = fileIDBytes.first, first == 0 || first == 1 { continue }

            guard let entryLBA = readUInt32LE(record, at: 2), let entrySize = readUInt32LE(record, at: 10) else { continue }
            let flags = record[record.startIndex + 25]
            let isDirectory = (flags & 0x02) != 0
            var entryName = String(data: fileIDBytes, encoding: .ascii) ?? ""
            // Regular (non-directory) identifiers carry a standard
            // ";<version>" suffix (ECMA-119 7.5.1) — stripped for display
            // and extension matching, same as every real ISO-9660 browser.
            if !isDirectory, let semicolonIndex = entryName.firstIndex(of: ";") {
                entryName = String(entryName[entryName.startIndex..<semicolonIndex])
            }

            if isDirectory {
                children.append(readDirectory(name: entryName, lba: entryLBA, size: entrySize, source: source))
            } else {
                children.append(ISO9660Entry(name: entryName, isDirectory: false, lba: entryLBA, size: entrySize))
            }
        }
        return ISO9660Entry(name: name, isDirectory: true, lba: lba, size: size, children: children)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }
}
