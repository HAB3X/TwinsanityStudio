import Foundation
import XCTest
import CTCore
import CTModels
import CTParsers

/// Tests for MHWriter and MBWriter functionality
final class SoundBankWriterTests: XCTestCase {

    func testMHWriterEncoding() throws {
        // Create a simple sound bank asset with one mono entry
        let entry = SoundBankEntry(
            index: 0,
            rawKind: SoundBankEntryKind.mono.rawValue,
            size: 100, // arbitrary size
            offset: 0, // will be set by parser, but for header we just need to write it
            sampleRateHz: 44100,
            skip: 0,
            name: "TEST",
            sound: SoundEffectAsset(
                id: 0,
                sampleRateHz: UInt16(44100),
                pcmSamples: [Int16](repeating: 0, count: 50) // 50 samples -> 100 bytes PCM
            )
        )

        let asset = SoundBankAsset(sourceLabel: "TEST_BANK", interleave: 0, entries: [entry])

        // Encode to MH format
        let mhData = try MHWriter.encode(asset)

        // Verify we got data back
        XCTAssertGreaterThan(mhData.count, 0)

        // Basic structure check: first 8 bytes should be count (1) and interleave (0)
        var cursor = BinaryCursor(data: mhData)
        let count = try cursor.readUInt32()
        let interleave = try cursor.readUInt32()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(interleave, 0)

        // Check the entry fields
        let rawKind = try cursor.readUInt32()
        let size = try cursor.readUInt32()
        let offset = try cursor.readUInt32()
        let sampleRate = try cursor.readUInt32()
        let skip = try cursor.readUInt32()

        XCTAssertEqual(rawKind, SoundBankEntryKind.mono.rawValue)
        XCTAssertEqual(size, 100)
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(sampleRate, 44100)
        XCTAssertEqual(skip, 0)
    }

    func testMBWriterEncoding() throws {
        // Create a simple mono entry with PCM data
        let pcmSamples = [Int16](repeating: 1000, count: 50) // 50 samples
        let sound = SoundEffectAsset(
            id: 0,
            sampleRateHz: UInt16(22050),
            pcmSamples: pcmSamples
        )

        // We'll need to determine the encoded ADPCM size - for simplicity, we can use a known size
        // In a real test we would encode and measure, but for now we'll use a placeholder
        let entrySize: UInt32 = 48 + 70 // MSVp header (48) + estimated ADPCM size

        let entry = SoundBankEntry(
            index: 0,
            rawKind: SoundBankEntryKind.mono.rawValue,
            size: entrySize,
            offset: 0,
            sampleRateHz: 22050,
            skip: 0,
            name: "TEST_MONO",
            sound: sound
        )

        let entries = [entry]

        // Encode to MB format
        let mbData = try MBWriter.encode(entries, interleave: 0)

        // Verify we got data back
        XCTAssertGreaterThan(mbData.count, 0)

        // Check for MSVp magic
        XCTAssertTrue(mbData.prefix(4).elementsEqual(Array("MSVp".utf8)), "Missing MSVp magic")

        // Version should be 1
        XCTAssertEqual(mbData[4], 0)
        XCTAssertEqual(mbData[5], 0)
        XCTAssertEqual(mbData[6], 0)
        XCTAssertEqual(mbData[7], 1)
    }

    func testDataExtensions() {
        // Test that our Data extensions work correctly
        var testData = Data()

        testData.append(littleEndian: UInt16(0x1234))
        testData.append(littleEndian: UInt32(0x12345678))

        XCTAssertEqual(testData.count, 6)
        XCTAssertEqual(testData[0], 0x34)   // Little endian: low byte first
        XCTAssertEqual(testData[1], 0x12)
        XCTAssertEqual(testData[2], 0x78)
        XCTAssertEqual(testData[3], 0x56)
        XCTAssertEqual(testData[4], 0x34)
        XCTAssertEqual(testData[5], 0x12)
    }
}