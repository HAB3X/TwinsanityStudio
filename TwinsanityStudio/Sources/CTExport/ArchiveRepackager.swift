import Foundation
import CTCore
import CTModels
import CTParsers

/// Safely rebuilds a `.BH`/`.BD` pair with a specific set of entries replaced
/// by new data, streaming every *unmodified* entry's bytes straight through
/// from the original `.BD` rather than requiring the whole archive to be
/// re-extracted to disk first.
///
/// "Safe" here specifically means: this always writes to a **new** output
/// pair rather than mutating the source archive in place. A `.BD`/`.BH` pair
/// is only internally consistent once both files are fully written — an
/// interrupted in-place rewrite (crash, disk full, force-quit) would leave a
/// game-breaking mismatched pair with no way back. Writing fresh files means
/// the original is always intact until the caller explicitly swaps them in.
public enum ArchiveRepackager {
    /// - Parameters:
    ///   - index: The parsed index of the source archive (from `BDArchiveParser.readIndex`).
    ///   - replacements: Entry name -> new bytes. Names matching an existing
    ///     entry replace its data (same name, same position in the index,
    ///     new offset/size); names with no existing match are appended as
    ///     new entries.
    ///   - outputBH: Destination `.BH` path (must not already exist).
    ///   - outputBD: Destination `.BD` path (must not already exist).
    public static func repackage(
        index: ArchiveIndex,
        replacements: [String: Data],
        outputBH: URL,
        outputBD: URL
    ) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: outputBH.path), !fm.fileExists(atPath: outputBD.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        fm.createFile(atPath: outputBH.path, contents: nil)
        fm.createFile(atPath: outputBD.path, contents: nil)
        let bhHandle = try FileHandle(forWritingTo: outputBH)
        let bdHandle = try FileHandle(forWritingTo: outputBD)
        defer { try? bhHandle.close(); try? bdHandle.close() }

        var magicHeader = BinaryWriter()
        magicHeader.writeInt32(0x501)
        bhHandle.write(magicHeader.data)

        let originalBD = try FileHandle(forReadingFrom: index.bdURL)
        defer { try? originalBD.close() }

        var handledNames = Set<String>()
        for entry in index.entries {
            handledNames.insert(entry.name)
            let data: Data
            if let replacement = replacements[entry.name] {
                data = replacement
            } else {
                try originalBD.seek(toOffset: UInt64(entry.offset))
                data = try originalBD.read(upToCount: Int(entry.size)) ?? Data()
            }
            try writeEntry(name: entry.name, data: data, bh: bhHandle, bd: bdHandle)
        }
        for (name, data) in replacements where !handledNames.contains(name) {
            try writeEntry(name: name, data: data, bh: bhHandle, bd: bdHandle)
        }
    }

    private static func writeEntry(name: String, data: Data, bh: FileHandle, bd: FileHandle) throws {
        var entryHeader = BinaryWriter()
        let nameBytes = Array(name.utf8)
        entryHeader.writeInt32(Int32(nameBytes.count))
        entryHeader.writeBytes(nameBytes)
        let offset = try bd.offset()
        entryHeader.writeUInt32(UInt32(offset))
        entryHeader.writeUInt32(UInt32(data.count))
        bh.write(entryHeader.data)
        bd.write(data)
    }
}
