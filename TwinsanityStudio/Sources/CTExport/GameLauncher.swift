import Foundation
import CTModels
import CTParsers

public enum GameLauncherError: Error, CustomStringConvertible {
    case notAnISO9660Image
    case systemCNFNotFound
    case systemCNFUnreadable
    case bootExecutableNotFound(String)
    case unrecognizedExecutableSerial(String)
    case archiveIndexNotFound
    case levelNotFoundInArchive(String)
    case pcsx2NotConfigured
    case pcsx2LaunchFailed(String)

    public var description: String {
        switch self {
        case .notAnISO9660Image:
            return "That file isn't a plain ISO-9660 image this build can read (raw .bin/.cue images aren't supported for launching — see ISO9660Writer's own doc comment)."
        case .systemCNFNotFound:
            return "No SYSTEM.CNF found at the disc's root — this doesn't look like a real PS2 disc image."
        case .systemCNFUnreadable:
            return "SYSTEM.CNF's BOOT2 line didn't name a real boot executable."
        case .bootExecutableNotFound(let name):
            return "Couldn't find \(name) (SYSTEM.CNF's own boot executable) at the disc's root."
        case .unrecognizedExecutableSerial(let serial):
            return "\(serial) isn't a PS2 serial prefix this build recognizes (expected SLES/SCES, SLUS/SCUS, or SLPS/SCPS/SLPM/SCAJ)."
        case .archiveIndexNotFound:
            return "No .BH archive index found anywhere on this disc."
        case .levelNotFoundInArchive(let name):
            return "\(name) isn't in this disc's archive — can't quick-launch into it."
        case .pcsx2NotConfigured:
            return "PCSX2's app location hasn't been set yet."
        case .pcsx2LaunchFailed(let reason):
            return "Couldn't launch PCSX2: \(reason)"
        }
    }
}

/// What a launch build should apply on top of a real, already-bootable
/// PS2 disc image — deliberately just two things, both real, verified
/// mechanisms this project already has, not a general "build the whole
/// modded game" pipeline (this app has no persistent cross-session dirty-
/// tracking to drive that from — see `WorkspaceViewModel.
/// otherLevelSceneryFileRoots`'s own doc comment on the same limitation
/// elsewhere):
/// - `startingChunkBaseName`: boots straight past the menu into one real
///   chunk, via the exact same executable field `ExecutablePatcher.
///   writingStartingChunkPath` already patches — real byte offsets ported
///   from CrateModLoader, not this project's own reverse engineering.
/// - `archiveReplacements`: real archive entries to swap in before
///   repackaging, keyed by their bare filename (e.g. `"beach.rm2"`) — this
///   build resolves each one against the disc's own real archive index to
///   find its full path, so callers never need to know the "Levels\..."
///   directory structure themselves.
public struct GameLaunchPlan {
    public var startingChunkBaseName: String?
    public var archiveReplacements: [String: Data]

    public init(startingChunkBaseName: String? = nil, archiveReplacements: [String: Data] = [:]) {
        self.startingChunkBaseName = startingChunkBaseName
        self.archiveReplacements = archiveReplacements
    }
}

/// Builds a real, patched copy of an existing bootable PS2 `.iso` and
/// launches it in PCSX2 — "Direct Boot/Launch." Deliberately patches an
/// already-known-bootable image in place (`ISO9660Writer.replacingFile`)
/// rather than building a brand-new disc from a folder tree
/// (`ISO9660ImageBuilder`, which that type's own doc comment is explicit
/// has never been verified to actually boot anywhere) — every byte this
/// doesn't touch is guaranteed identical to the original disc, so nothing
/// about *booting* the result is new risk, only the specific files this
/// plan asks to change.
public enum GameLauncher {
    /// Reads `isoURL`'s full bytes and applies `plan` on top, returning the
    /// finished image ready to write out and boot. `scratchDirectory` holds
    /// short-lived extraction/repackaging files (the disc's own `.BH`/`.BD`
    /// pair, and the repackaged replacement) — safe to delete once this
    /// returns.
    public static func building(isoURL: URL, plan: GameLaunchPlan, scratchDirectory: URL) throws -> Data {
        let isoData = try Data(contentsOf: isoURL, options: .mappedIfSafe)
        let source = PlainISOSource(data: isoData)
        guard let root = try? ISO9660Reader.readRootDirectory(from: source), !root.children.isEmpty else {
            throw GameLauncherError.notAnISO9660Image
        }

        // Created unconditionally, before the early-return below — a
        // caller writing its own output file into `scratchDirectory`
        // afterward (as `GameLauncherView` does) shouldn't have to know
        // whether this call happened to need it internally. A real bug:
        // the "Play in PCSX2" global launch (no starting-chunk override,
        // no archive replacements) hit the early return before this used
        // to run, so the directory never existed and the caller's own
        // write failed with "No such file or directory."
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        var patchedISO = isoData
        guard plan.startingChunkBaseName != nil || !plan.archiveReplacements.isEmpty else {
            return patchedISO
        }

        let (bhEntry, bdEntry) = try locateArchivePair(in: root)
        guard let bhData = ISO9660Reader.readFile(bhEntry, from: source),
              let bdData = ISO9660Reader.readFile(bdEntry, from: source)
        else { throw GameLauncherError.archiveIndexNotFound }

        let tempBH = scratchDirectory.appendingPathComponent((bhEntry.name as NSString).lastPathComponent)
        let tempBD = scratchDirectory.appendingPathComponent((bdEntry.name as NSString).lastPathComponent)
        try bhData.write(to: tempBH)
        try bdData.write(to: tempBD)
        let index = try BDArchiveParser.readIndex(bhURL: tempBH)

        if let baseName = plan.startingChunkBaseName {
            // Unlike `archiveReplacements` (matched by full filename, e.g.
            // "cavent.rm2"), a chunk name has no single extension of its
            // own — it names the pair of .sm2/.rm2 files that share it —
            // so this strips the entry's extension before comparing.
            guard let match = index.entries.first(where: { (entryBaseName($0.name) as NSString).deletingPathExtension.lowercased() == baseName.lowercased() }) else {
                throw GameLauncherError.levelNotFoundInArchive(baseName)
            }
            let windowsPath = match.name.replacingOccurrences(of: "/", with: "\\")
            let startingChunkPath = (windowsPath as NSString).deletingPathExtension
            let (exeEntry, revision) = try locateBootExecutable(in: root, source: source)
            guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
                throw GameLauncherError.bootExecutableNotFound(exeEntry.name)
            }
            let patchedExe = try ExecutablePatcher.writingStartingChunkPath(startingChunkPath, revision: revision, into: exeData)
            patchedISO = try ISO9660Writer.replacingFile(exeEntry, with: patchedExe, in: patchedISO)
        }

        if !plan.archiveReplacements.isEmpty {
            var fullNameReplacements: [String: Data] = [:]
            for (bareName, data) in plan.archiveReplacements {
                guard let match = index.entries.first(where: { entryBaseName($0.name).lowercased() == bareName.lowercased() }) else {
                    throw GameLauncherError.levelNotFoundInArchive(bareName)
                }
                fullNameReplacements[match.name] = data
            }
            let newBH = scratchDirectory.appendingPathComponent("relaunch_\(tempBH.lastPathComponent)")
            let newBD = scratchDirectory.appendingPathComponent("relaunch_\(tempBD.lastPathComponent)")
            try? FileManager.default.removeItem(at: newBH)
            try? FileManager.default.removeItem(at: newBD)
            try ArchiveRepackager.repackage(index: index, replacements: fullNameReplacements, outputBH: newBH, outputBD: newBD)
            let newBHData = try Data(contentsOf: newBH)
            let newBDData = try Data(contentsOf: newBD)
            patchedISO = try ISO9660Writer.replacingFile(bhEntry, with: newBHData, in: patchedISO)
            patchedISO = try ISO9660Writer.replacingFile(bdEntry, with: newBDData, in: patchedISO)
        }

        return patchedISO
    }

    /// Launches PCSX2 with `isoURL` as its boot target — fire-and-forget,
    /// deliberately not waiting for it to quit (unlike this codebase's other
    /// `Process` use in `CrateExporter`/`CrateArchiveManager`, both of which
    /// run short-lived command-line tools and need their exit status; PCSX2
    /// is a long-running interactive GUI app, so `waitUntilExit()` here
    /// would block the whole call until the user closes the emulator).
    public static func launching(pcsx2AppURL: URL, isoURL: URL) throws {
        let executableURL = pcsx2AppURL.pathExtension.lowercased() == "app"
            ? pcsx2AppURL.appendingPathComponent("Contents/MacOS/PCSX2")
            : pcsx2AppURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GameLauncherError.pcsx2LaunchFailed("\(executableURL.lastPathComponent) isn't an executable file.")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--", isoURL.path]
        do {
            try process.run()
        } catch {
            throw GameLauncherError.pcsx2LaunchFailed(error.localizedDescription)
        }
    }

    // MARK: - Disc tree lookups

    private static func entryBaseName(_ archiveEntryName: String) -> String {
        (archiveEntryName as NSString).lastPathComponent
    }

    /// SYSTEM.CNF + the boot executable it names — both always sit directly
    /// at the disc's root on a real PS2 disc, so this only ever looks at
    /// `root.children`, never recurses.
    private static func locateBootExecutable(in root: ISO9660Entry, source: PlainISOSource) throws -> (entry: ISO9660Entry, revision: GameExecutableRevision) {
        guard let cnfEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("SYSTEM.CNF") == .orderedSame }) else {
            throw GameLauncherError.systemCNFNotFound
        }
        guard let cnfData = ISO9660Reader.readFile(cnfEntry, from: source), let cnfText = String(data: cnfData, encoding: .ascii) else {
            throw GameLauncherError.systemCNFUnreadable
        }
        let info = SystemCNFParser.parse(contents: cnfText)
        guard let serial = info.serial else { throw GameLauncherError.systemCNFUnreadable }
        guard let exeEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare(serial) == .orderedSame }) else {
            throw GameLauncherError.bootExecutableNotFound(serial)
        }
        guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
            throw GameLauncherError.bootExecutableNotFound(serial)
        }
        let revision = try revisionForSerial(serial, exeData: exeData)
        return (exeEntry, revision)
    }

    private static func revisionForSerial(_ serial: String, exeData: Data) throws -> GameExecutableRevision {
        let upper = serial.uppercased()
        if upper.hasPrefix("SLES") || upper.hasPrefix("SCES") { return .pal }
        if upper.hasPrefix("SLPS") || upper.hasPrefix("SCPS") || upper.hasPrefix("SLPM") || upper.hasPrefix("SCAJ") { return .ntscJ }
        if upper.hasPrefix("SLUS") || upper.hasPrefix("SCUS") {
            return ExecutablePatcher.detectNTSCURevision(exeData: exeData) ?? .ntscU
        }
        throw GameLauncherError.unrecognizedExecutableSerial(serial)
    }

    /// The disc's `.BH`/`.BD` archive pair — searched recursively (unlike
    /// the boot executable) since real Twinsanity discs nest it inside a
    /// subdirectory (`CRASH6\CRASH.BH`, confirmed against the real retail
    /// disc), not at the root.
    private static func locateArchivePair(in root: ISO9660Entry) throws -> (bh: ISO9660Entry, bd: ISO9660Entry) {
        func walk(_ node: ISO9660Entry) -> (bh: ISO9660Entry, bd: ISO9660Entry)? {
            if let bh = node.children.first(where: { !$0.isDirectory && $0.name.uppercased().hasSuffix(".BH") }) {
                let base = (bh.name as NSString).deletingPathExtension
                if let bd = node.children.first(where: { !$0.isDirectory && (($0.name as NSString).deletingPathExtension).caseInsensitiveCompare(base) == .orderedSame && $0.name.uppercased().hasSuffix(".BD") }) {
                    return (bh, bd)
                }
            }
            for child in node.children where child.isDirectory {
                if let found = walk(child) { return found }
            }
            return nil
        }
        guard let pair = walk(root) else { throw GameLauncherError.archiveIndexNotFound }
        return pair
    }
}
