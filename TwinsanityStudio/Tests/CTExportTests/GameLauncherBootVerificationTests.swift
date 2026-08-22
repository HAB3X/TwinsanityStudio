import XCTest
import CTExport
import CTParsers
import CTModels

/// "Real Edited-Chunk Boot Verification" — the one thing neither
/// `ImageMakerBootVerificationTests` (boots an *unmodified* rebuild-from-
/// folder disc — its own doc comment is explicit about that) nor
/// `GameLauncherTests` (only ever reads the patched bytes back in memory,
/// never hands them to a real emulator) actually covers: does a genuinely
/// *edited* disc image — built via the real `GameLauncher.building` write-
/// back pipeline this app's own "Save Rebuilt ISO…", Quick Launch, and
/// quit-time autosave features all use — actually boot in a real PCSX2, and
/// is there real, external evidence (not just "PCSX2 didn't crash") that
/// the *edited* starting chunk is what got loaded, as opposed to PCSX2
/// having silently ignored the patch and booted the unmodified retail
/// default (which, unpatched, boots the main menu — not any level at all,
/// so a level actually being the target here is already a real distinction)?
///
/// The signal: `ExecutablePatcher.writingStartingChunkPath` patches 23 real
/// bytes inside the boot executable itself (not a side config file), so a
/// disc genuinely carrying the edit has a boot executable whose bytes
/// differ from retail. PCSX2's own "Game CRC" log line — the exact line
/// `ImageMakerBootVerificationTests` pins to the known-good *unmodified*
/// retail PAL value `1510E1D1` — is computed from those same executable
/// bytes. A real PCSX2 boot that reports a Game CRC other than `1510E1D1`
/// is external proof, from PCSX2 itself, that it loaded our edited
/// executable rather than the unmodified retail one. That's combined with
/// an independent pre-flight readback (before PCSX2 ever sees the file, via
/// the same real `ISO9660Reader`/`ExecutablePatcher.readStartingChunkPath`
/// a genuine consumer would use) confirming the disc image actually handed
/// to PCSX2 carries the patched "levels\earth\hub\beach" field — not just
/// that `GameLauncher.building` claimed to apply it.
///
/// Targets "beach" specifically: a real level, deliberately different from
/// this disc's own unmodified default boot target, and short enough to fit
/// the PAL build's real 23-byte starting-chunk field (the same field length
/// `GameLauncherTests.testBuildingWithStartingChunkOverridePatchesTheRealBootExecutable`
/// already confirms "beach" fits against the NTSC-U build).
///
/// Skips cleanly if the real retail PAL disc image or real PCSX2 binary
/// isn't present on the machine running this — same convention as
/// `ImageMakerBootVerificationTests`/`RealDiscDiagnosticTests`; this is
/// inherently a local, interactive-adjacent verification PCSX2 can't run in
/// CI.
final class GameLauncherBootVerificationTests: XCTestCase {
    private static let pcsx2Binary = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/Reference Files/PCSX2-v2.6.3.app/Contents/MacOS/PCSX2")
    private static let retailISOURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/Crash Twinsanity (Europe, Australia) (En,Fr,De,Es,It).iso")
    /// The real, known-good Crash Twinsanity PAL executable hash for the
    /// *unmodified* retail boot ELF — the same value
    /// `ImageMakerBootVerificationTests` pins its own success signal to.
    /// If a boot of our edited image ever reported this exact CRC, that
    /// would mean PCSX2 silently loaded the unpatched executable instead of
    /// the one this test actually built.
    private static let retailBootCRC = "1510E1D1"

    func testGameLauncherEditedStartingChunkBootsInRealPCSX2WithDifferentCRC() throws {
        guard FileManager.default.fileExists(atPath: Self.pcsx2Binary.path) else {
            throw XCTSkip("Real PCSX2 binary not present on this machine.")
        }
        guard FileManager.default.fileExists(atPath: Self.retailISOURL.path) else {
            throw XCTSkip("Real retail PAL ISO not present on this machine.")
        }

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("GameLauncherBootVerificationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let plan = GameLaunchPlan(startingChunkBaseName: "beach")
        let built = try GameLauncher.building(isoURL: Self.retailISOURL, plan: plan, scratchDirectory: scratchDir)
        XCTAssertEqual(built.count % 2048, 0, "a real disc image is always a whole number of 2048-byte sectors")

        // Pre-flight, independent readback — before PCSX2 ever sees this
        // file — confirming the exact bytes we're about to hand it really
        // do carry the edit, not just that `building` claimed to apply it.
        let source = PlainISOSource(data: built)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let exeEntry = root.children.first(where: { !$0.isDirectory && $0.name.caseInsensitiveCompare("SLES_525.68") == .orderedSame }) else {
            return XCTFail("built image is missing its own real PAL boot executable — not a PCSX2 problem, a builder problem")
        }
        guard let exeData = ISO9660Reader.readFile(exeEntry, from: source) else {
            return XCTFail("couldn't read the boot executable back from the built image")
        }
        let readBackPath = ExecutablePatcher.readStartingChunkPath(revision: .pal, from: exeData)
        XCTAssertEqual(readBackPath?.lowercased(), "levels\\earth\\hub\\beach",
                        "the built image's own boot executable must carry the edited starting chunk before we ever hand it to PCSX2")

        let outputISO = scratchDir.appendingPathComponent("gamelauncher_boot_test.iso")
        try built.write(to: outputISO)

        let logURL = scratchDir.appendingPathComponent("pcsx2_boot_test.log")
        try? FileManager.default.removeItem(at: logURL)

        let process = Process()
        process.executableURL = Self.pcsx2Binary
        process.arguments = ["-batch", "-nogui", "-logfile", logURL.path, "-earlyconsolelog", "--", outputISO.path]
        // Without an explicit stdout/stderr file handle, `Process` launched
        // from inside `swift test` leaves PCSX2's console-log thread unable
        // to ever flush `-logfile` to disk — the exact same issue
        // `ImageMakerBootVerificationTests` documents and works around.
        let stdoutURL = scratchDir.appendingPathComponent("pcsx2_stdout_test.log")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        process.standardOutput = stdoutHandle
        process.standardError = stdoutHandle

        try process.run()

        // Same timeout budget as `ImageMakerBootVerificationTests` — this
        // is a boot smoke test, not a full playthrough, and the edit here
        // is 23 bytes inside the same executable region PCSX2 loads
        // identically regardless of the patch, so boot timing shouldn't
        // differ from the unmodified case that test's own timeout was
        // tuned against.
        Thread.sleep(forTimeInterval: 15)
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? stdoutHandle.close()

        guard let logData = try? Data(contentsOf: logURL), let logText = String(data: logData, encoding: .utf8), !logText.isEmpty else {
            return XCTFail("PCSX2 produced no readable log at \(logURL.path) — can't verify anything about this boot")
        }

        // Record the real log content regardless of outcome.
        print("=== PCSX2 boot log for edited (\"beach\" starting chunk) image (\(logText.count) chars) ===")
        print(logText)
        print("=== end PCSX2 boot log ===")

        XCTAssertTrue(logText.contains("(SYSTEM.CNF) Detected PS2 Disc = cdrom0:\\SLES_525.68;1"),
                       "PCSX2 must genuinely resolve the boot path through our built ISO's own directory structure")
        XCTAssertTrue(logText.contains("RegisterLibraryEntries:  cdvdman"),
                       "the IOP kernel must have started registering modules — real post-ELF-load execution, not just a file read")
        XCTAssertTrue(logText.contains("Add ") && logText.contains("seconds play time to SLES-52568"),
                       "PCSX2 must report real accumulated play time — proof the edited disc actually ran, not just loaded")

        guard let crcRange = logText.range(of: "Game CRC = ") else {
            return XCTFail("PCSX2's log never reported a Game CRC for this boot — can't confirm which executable it actually loaded")
        }
        let afterPrefix = logText[crcRange.upperBound...]
        let crcToken = String(afterPrefix.prefix { $0.isHexDigit }).uppercased()
        XCTAssertEqual(crcToken.count, 8, "expected an 8-hex-digit Game CRC in the real log, got \"\(crcToken)\"")

        // The decisive, real, external signal: our starting-chunk patch
        // lives inside the boot executable's own bytes, and PCSX2's Game
        // CRC is computed from those same bytes. The unmodified retail
        // PAL boot executable's CRC would only appear here if PCSX2 had
        // somehow booted the unpatched executable instead of the one this
        // test actually built with the "beach" starting-chunk edit baked
        // in — i.e. this assertion is exactly what would fail if the
        // write-back pipeline silently produced a no-op disc.
        XCTAssertNotEqual(crcToken, Self.retailBootCRC,
                           "PCSX2 reported the unmodified retail Game CRC — it booted the wrong (unedited) executable, not the one this test built with the \"beach\" starting-chunk patch")
    }
}
