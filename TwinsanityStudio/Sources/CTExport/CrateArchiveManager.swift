import Foundation

public enum CrateArchiveError: Error, LocalizedError, Equatable {
    case unzipToolUnavailable
    case unzipFailed(Int32)
    case manifestMissing

    public var errorDescription: String? {
        switch self {
        case .unzipToolUnavailable: return "The system unzip tool (/usr/bin/unzip) isn't available on this Mac."
        case .unzipFailed(let code): return "unzip exited with status \(code)."
        case .manifestMissing: return "This archive has no modcrateinfo.txt at its root — it isn't a CrateModLoader .crate package."
        }
    }
}

/// Reads real `.crate` mod packages — the inspection/extraction
/// counterpart to `CrateExporter`, which only writes them. A `.crate` is a
/// plain zip (see `CrateExporter`'s doc comment for the verified layout:
/// `modcrateinfo.txt` at the root plus one `layer<N>/` folder per install
/// layer); this shells out to the system `/usr/bin/unzip` the same way
/// `CrateExporter` shells out to `/usr/bin/zip`, for the same reason —
/// `CrateModLoader` itself reads/writes crates with .NET's
/// `System.IO.Compression.ZipFile`, so round-tripping through a real zip
/// tool on both ends is what stays compatible with it.
public enum CrateArchiveManager {
    /// Every entry path inside the archive, root-relative, directories
    /// included with a trailing `/` — `unzip -Z1` (zipinfo's "just the
    /// names" mode) lists them without extracting anything.
    public static func listEntries(in crateURL: URL) throws -> [String] {
        let output = try runUnzip(["-Z1", crateURL.path])
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Parses the manifest without extracting the whole archive to disk —
    /// `modcrateinfo.txt`/`modcratesettings.txt` are pulled into a
    /// throwaway temp directory, and layer/icon presence is read straight
    /// off the real entry list rather than assumed.
    public static func readManifest(from crateURL: URL) throws -> ModManifest {
        let entries = try listEntries(in: crateURL)
        guard entries.contains("modcrateinfo.txt") else { throw CrateArchiveError.manifestMissing }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinsanityStudioCrateRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try runUnzip(["-o", "-q", crateURL.path, "modcrateinfo.txt", "-d", tempDir.path])
        let infoText = try String(contentsOf: tempDir.appendingPathComponent("modcrateinfo.txt"), encoding: .utf8)

        var settingsText: String?
        if entries.contains("modcratesettings.txt") {
            try runUnzip(["-o", "-q", crateURL.path, "modcratesettings.txt", "-d", tempDir.path])
            settingsText = try? String(contentsOf: tempDir.appendingPathComponent("modcratesettings.txt"), encoding: .utf8)
        }

        return ModManifestParser.parseInfo(
            infoText,
            settingsText: settingsText,
            layerIndices: layerIndices(in: entries),
            hasIcon: entries.contains("modcrateicon.png")
        )
    }

    /// The real files inside one `layer<N>/` folder, relative to that
    /// layer's own root (directory entries excluded).
    public static func filesInLayer(_ layerIndex: Int, entries: [String]) -> [String] {
        let prefix = "layer\(layerIndex)/"
        return entries
            .filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/") }
            .map { String($0.dropFirst(prefix.count)) }
            .sorted()
    }

    /// Extracts one `layer<N>/` folder's contents into `destinationURL`,
    /// stripping the `layer<N>/` prefix so the files land exactly where
    /// `CrateModLoader.InstallLayerMod` would place them relative to a game
    /// install directory.
    public static func extractLayer(_ layerIndex: Int, from crateURL: URL, to destinationURL: URL) throws {
        let prefix = "layer\(layerIndex)/"
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwinsanityStudioCrateExtract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        try runUnzip(["-o", "-q", crateURL.path, "\(prefix)*", "-d", stagingDir.path])

        let layerRoot = stagingDir.appendingPathComponent(String(prefix.dropLast()))
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        // The string-relative `enumerator(atPath:)` API, not the URL-based
        // one: `layerRoot` sits under `FileManager.default.temporaryDirectory`
        // (`/var/folders/...`, a symlink to `/private/var/folders/...`), but
        // `enumerator(at:)` resolves that symlink in the URLs it hands back
        // while `layerRoot.path` doesn't — so computing "relative path" by
        // dropping `layerRoot.path`'s length as a string prefix silently
        // produces garbage. Enumerating by path sidesteps the mismatch
        // entirely: every element already comes back relative to
        // `layerRoot`, no prefix arithmetic needed.
        guard let enumerator = FileManager.default.enumerator(atPath: layerRoot.path) else { return }
        for case let relativePath as String in enumerator {
            let source = layerRoot.appendingPathComponent(relativePath)
            let target = destinationURL.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
    }

    /// Extracts the whole archive as-is (manifest + every layer folder) —
    /// the "just show me the files" counterpart to `extractLayer`.
    public static func extractAll(from crateURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try runUnzip(["-o", "-q", crateURL.path, "-d", destinationURL.path])
    }

    private static func layerIndices(in entries: [String]) -> [Int] {
        var found = Set<Int>()
        for entry in entries {
            guard entry.hasPrefix("layer") else { continue }
            let rest = entry.dropFirst("layer".count)
            guard let slashIndex = rest.firstIndex(of: "/") else { continue }
            if let index = Int(rest[rest.startIndex..<slashIndex]) {
                found.insert(index)
            }
        }
        return found.sorted()
    }

    @discardableResult
    private static func runUnzip(_ arguments: [String]) throws -> String {
        guard FileManager.default.fileExists(atPath: "/usr/bin/unzip") else {
            throw CrateArchiveError.unzipToolUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        // Drain stdout before waiting: a large `-Z1` listing can exceed the
        // pipe's kernel buffer, and waiting first would deadlock against a
        // child that's blocked writing to a full pipe.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CrateArchiveError.unzipFailed(process.terminationStatus)
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
