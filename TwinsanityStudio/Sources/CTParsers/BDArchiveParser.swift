import Foundation
import CTCore
import CTModels

public enum BDArchiveError: Error, CustomStringConvertible {
    case missingCounterpart(String)
    case badMagic(UInt32)
    case entryOutOfBounds(name: String, offset: UInt32, size: UInt32, fileSize: Int)

    public var description: String {
        switch self {
        case .missingCounterpart(let path):
            return "Could not find the matching .BD/.BH file for \(path)."
        case .badMagic(let magic):
            return String(format: "Unexpected .BH magic number: 0x%08X (expected 0x501).", magic)
        case .entryOutOfBounds(let name, let offset, let size, let fileSize):
            return "Archive entry '\(name)' (offset \(offset), size \(size)) exceeds the .BD file size (\(fileSize))."
        }
    }
}

/// Reads and writes Twinsanity's `.BD`/`.BH` archive pair.
///
/// Format (ported from `Twinsanity/BDArchive.cs`):
/// - `.BH` (index): `int32 magic` (0x501 when written) followed by back-to-back,
///   EOF-terminated entries: `int32 nameLength`, `char[nameLength]` ASCII name,
///   `uint32 offset`, `uint32 size`. No explicit entry count.
/// - `.BD` (data): raw file bytes concatenated back-to-back at the offsets named
///   above. No alignment or padding between entries.
public enum BDArchiveParser {
    /// Given either a `.BH` or `.BD` URL (any case), resolves the sibling path,
    /// preserving the original tool's case-sensitive suffix-swap behavior
    /// (`BDArchive.cs:13-41`) so archives written by the Windows tool keep working.
    public static func counterpartURL(for url: URL) throws -> (bh: URL, bd: URL) {
        let path = url.path
        if path.hasSuffix(".BH") {
            return (url, URL(fileURLWithPath: String(path.dropLast(1)) + "D"))
        } else if path.hasSuffix(".bh") {
            return (url, URL(fileURLWithPath: String(path.dropLast(1)) + "d"))
        } else if path.hasSuffix(".BD") {
            return (URL(fileURLWithPath: String(path.dropLast(1)) + "H"), url)
        } else if path.hasSuffix(".bd") {
            return (URL(fileURLWithPath: String(path.dropLast(1)) + "h"), url)
        } else {
            return (url.appendingPathExtension("BH"), url.appendingPathExtension("BD"))
        }
    }

    /// Parses just the `.BH` index — cheap, does not touch the (potentially huge) `.BD`.
    public static func readIndex(bhURL: URL) throws -> ArchiveIndex {
        let (bh, bd) = try counterpartURL(for: bhURL)
        let data = try Data(contentsOf: bh)
        var cursor = BinaryCursor(data: data)
        _ = try cursor.readInt32() // magic; not validated on read, mirrors original tool's tolerance for foreign archives

        var entries: [ArchiveEntry] = []
        while !cursor.isAtEnd {
            let nameLen = Int(try cursor.readInt32())
            guard nameLen >= 0 else { break }
            let name = try cursor.readASCIIString(length: nameLen)
            let offset = try cursor.readUInt32()
            let size = try cursor.readUInt32()
            entries.append(ArchiveEntry(name: normalizingSeparators(name), offset: offset, size: size))
        }
        return ArchiveIndex(bhURL: bh, bdURL: bd, entries: entries)
    }

    /// Reads a single entry's bytes out of the `.BD` file.
    public static func readEntryData(_ entry: ArchiveEntry, index: ArchiveIndex) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: index.bdURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard Int(entry.offset) + Int(entry.size) <= fileSize else {
            throw BDArchiveError.entryOutOfBounds(name: entry.name, offset: entry.offset, size: entry.size, fileSize: fileSize)
        }
        let handle = try FileHandle(forReadingFrom: index.bdURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.offset))
        return try handle.read(upToCount: Int(entry.size)) ?? Data()
    }

    /// Extracts every entry to `destinationDirectory`, recreating the archive's
    /// internal directory structure (entries may embed `/`-separated paths).
    public static func extractAll(index: ArchiveIndex, to destinationDirectory: URL) throws {
        let fm = FileManager.default
        let bdHandle = try FileHandle(forReadingFrom: index.bdURL)
        defer { try? bdHandle.close() }

        for entry in index.entries {
            let outURL = destinationDirectory.appendingPathComponent(entry.name)
            try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bdHandle.seek(toOffset: UInt64(entry.offset))
            let data = try bdHandle.read(upToCount: Int(entry.size)) ?? Data()
            try data.write(to: outURL)
        }
    }

    private static func normalizingSeparators(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }

    /// Rebuilds a `.BH`/`.BD` pair from a directory tree, matching
    /// `BDArchive.CompileAll` byte-for-byte in spirit (2 MiB streamed copies,
    /// no padding between entries, magic `0x501`).
    ///
    /// This is intentionally a *fresh rebuild from a directory*, not an in-place
    /// patch — see `ArchiveRepackager` (CTExport) for the "replace just these
    /// entries, keep everything else identical" workflow the app's UI drives.
    public static func compileAll(from sourceDirectory: URL, bhURL: URL, bdURL: URL) throws {
        let fm = FileManager.default
        var files: [(relativePath: String, url: URL)] = []
        // Resolve symlinks before computing relative paths: on macOS
        // `FileManager.default.temporaryDirectory` (and `/tmp` generally) is
        // itself a symlink to `/private/tmp`, and `enumerator(at:)` returns
        // paths through the *resolved* location — a naive string-prefix
        // strip against the unresolved `sourceDirectory.path` silently fails
        // to strip anything, leaving full absolute paths as "relative" names.
        let sourceComponents = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        if let enumerator = fm.enumerator(at: sourceDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { continue }
                let resolvedComponents = fileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                let relative = resolvedComponents.dropFirst(sourceComponents.count).joined(separator: "/")
                files.append((relative, fileURL))
            }
        }
        files.sort { $0.relativePath < $1.relativePath }

        fm.createFile(atPath: bhURL.path, contents: nil)
        fm.createFile(atPath: bdURL.path, contents: nil)
        let bhHandle = try FileHandle(forWritingTo: bhURL)
        let bdHandle = try FileHandle(forWritingTo: bdURL)
        defer { try? bhHandle.close(); try? bdHandle.close() }

        var header = BinaryWriter()
        header.writeInt32(0x501)
        bhHandle.write(header.data)

        for (relativePath, fileURL) in files {
            let fileData = try Data(contentsOf: fileURL)
            var entryHeader = BinaryWriter()
            let nameBytes = Array(relativePath.utf8)
            entryHeader.writeInt32(Int32(nameBytes.count))
            entryHeader.writeBytes(nameBytes)
            let offset = try bdHandle.offset()
            entryHeader.writeUInt32(UInt32(offset))
            entryHeader.writeUInt32(UInt32(fileData.count))
            bhHandle.write(entryHeader.data)
            bdHandle.write(fileData)
        }
    }
}
