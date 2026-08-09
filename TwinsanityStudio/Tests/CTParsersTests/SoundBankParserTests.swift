import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class SoundBankParserTests: XCTestCase {
    /// One mono entry, one reserved entry — matches the real `MHWorker.
    /// LoadMH`/`LoadBuffer` layout exactly, including the `MSVp` header
    /// this session verified against real `ENGLISH.MH`/`.MB` bytes.
    func testParsesMonoAndReservedEntries() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(2) // soundCount
        mh.writeUInt32(65536) // interleave

        // Entry 0: mono, real ADPCM data at .MB offset 0.
        mh.writeUInt32(0) // type: mono
        mh.writeUInt32(16) // size: one ADPCM line
        mh.writeUInt32(0) // offset
        mh.writeUInt32(32000) // sampleRateHz (MH copy)
        mh.writeUInt32(0) // skip

        // Entry 1: reserved (empty).
        mh.writeUInt32(2)
        mh.writeUInt32(0)
        mh.writeUInt32(0)
        mh.writeUInt32(0)
        mh.writeUInt32(0)

        var mb = BinaryWriter()
        mb.writeASCIIString("MSVp") // magic
        mb.writeBytes([0, 0, 0, 32]) // version
        mb.writeUInt32(0) // unused
        mb.writeBytes([0, 0, 0, 16]) // size-48, big-endian (unused by the parser)
        mb.writeBytes([0, 0, 0x7d, 0]) // sampleRateHz = 32000, big-endian
        mb.writeUInt32(0); mb.writeUInt32(0); mb.writeUInt32(0) // 3 unused uint32s
        mb.writeASCIIString("TestSound") // name, padded below
        mb.writeBytes([UInt8](repeating: 0, count: 16 - "TestSound".utf8.count))
        // One real ADPCM line: factor=0, predict=0, low nibble=1 -> first sample 4096, then end-of-stream flag.
        var adpcmLine = [UInt8](repeating: 0, count: 16)
        adpcmLine[2] = 0x01
        mb.writeBytes(adpcmLine)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: mb.data, sourceLabel: "TEST")

        XCTAssertEqual(bank.interleave, 65536)
        XCTAssertEqual(bank.entries.count, 2)

        let mono = bank.entries[0]
        XCTAssertEqual(mono.kind, .mono)
        XCTAssertEqual(mono.name, "TestSound")
        XCTAssertEqual(mono.sampleRateHz, 32000)
        XCTAssertEqual(mono.sound?.pcmSamples.first, 4096)

        let reserved = bank.entries[1]
        XCTAssertEqual(reserved.kind, .reserved)
        XCTAssertNil(reserved.sound)
        XCTAssertNil(reserved.name)
    }

    /// A stereo entry is reported honestly (kind + metadata) without a
    /// fabricated decode — this build doesn't have the stereo ADPCM demux
    /// ported yet.
    func testStereoEntryReportsMetadataWithoutFabricatingAudio() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(1)
        mh.writeUInt32(65536)
        mh.writeUInt32(1) // type: stereo
        mh.writeUInt32(32)
        mh.writeUInt32(0)
        mh.writeUInt32(44100)
        mh.writeUInt32(0)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: Data(), sourceLabel: "TEST")
        let entry = try XCTUnwrap(bank.entries.first)
        XCTAssertEqual(entry.kind, .stereo)
        XCTAssertNil(entry.sound)
        XCTAssertEqual(entry.sampleRateHz, 44100)
    }

    /// An offset that doesn't fit inside the `.MB` data (a real possibility
    /// this format allows for) must not crash the parse — the entry just
    /// comes back with no name/sound.
    func testOutOfBoundsOffsetDoesNotCrashOrFabricate() throws {
        var mh = BinaryWriter()
        mh.writeUInt32(1)
        mh.writeUInt32(65536)
        mh.writeUInt32(0) // mono
        mh.writeUInt32(16)
        mh.writeUInt32(1_000_000) // offset way past the tiny .MB below
        mh.writeUInt32(32000)
        mh.writeUInt32(0)

        let bank = try SoundBankParser.parse(mhData: mh.data, mbData: Data([0, 1, 2, 3]), sourceLabel: "TEST")
        let entry = try XCTUnwrap(bank.entries.first)
        XCTAssertNil(entry.sound)
        XCTAssertNil(entry.name)
    }
}
