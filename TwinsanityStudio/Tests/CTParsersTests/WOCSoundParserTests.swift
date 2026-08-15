import XCTest
@testable import CTParsers

final class WOCSoundParserTests: XCTestCase {
    private var sfxURL: URL { URL(fileURLWithPath: "/Volumes/CRASH/SFX.DAT") }

    private func requireDisc() throws {
        guard FileManager.default.fileExists(atPath: sfxURL.path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
    }

    /// Golden-value regression: hand-verified against the real disc via an
    /// independent Python re-implementation (not reused from the agent's
    /// script) before being pinned here -- record count, sector-aligned
    /// offset chain for all 781 consecutive pairs, and the outer table's
    /// `size` matching each entry's own VAG header exactly.
    func testRealArchiveTableGoldenValues() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        XCTAssertEqual(entries.count, 782)
        XCTAssertEqual(entries[0].offset, 2048)
        XCTAssertEqual(entries[0].size, 4016)
        XCTAssertEqual(entries[1].offset, 6144)

        for i in 1..<entries.count {
            let expected = ((entries[i - 1].offset + entries[i - 1].size + 2047) / 2048) * 2048
            XCTAssertEqual(entries[i].offset, expected, "sector-alignment chain broke at index \(i)")
        }
    }

    /// Decodes a handful of real entries spread across the archive and
    /// checks for real-waveform statistics (RMS energy present, no NaNs,
    /// plausible sample rates) rather than a golden byte match -- ADPCM
    /// decode output is high-volume and not hand-verifiable byte-by-byte,
    /// but a silent/garbage decode would fail these checks.
    func testRealEntriesDecodeToPlausibleAudio() throws {
        try requireDisc()
        let entries = try WOCSoundParser.parseTable(fileURL: sfxURL)
        for index in [0, 1, 100, 500, 781] {
            let entry = entries[index]
            let clip = try WOCSoundParser.decode(entry, fileURL: sfxURL)
            XCTAssertTrue(clip.sampleRate == 11025 || clip.sampleRate == 22050, "unexpected sample rate \(clip.sampleRate) at index \(index)")
            XCTAssertFalse(clip.samples.isEmpty)

            let sumSquares = clip.samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = (sumSquares / Double(clip.samples.count)).squareRoot()
            XCTAssertGreaterThan(rms, 50, "entry \(index) decoded to near-silence (rms \(rms)) -- likely a decode bug")
        }
    }
}
