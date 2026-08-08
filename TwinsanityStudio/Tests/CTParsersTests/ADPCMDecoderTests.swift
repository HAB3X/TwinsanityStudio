import XCTest
@testable import CTParsers

final class ADPCMDecoderTests: XCTestCase {
    func testSilentLineDecodesToZeroPCM() {
        // factor=0, predict=0, all nibbles zero -> every sample is exactly 0.
        var line = [UInt8](repeating: 0, count: 16)
        line[1] = 0 // not the end-of-stream/loop-end marker
        let pcm = ADPCMDecoder.toPCMMono(Data(line))

        XCTAssertEqual(pcm.count, 28)
        XCTAssertTrue(pcm.allSatisfy { $0 == 0 })
    }

    func testEndOfStreamFlagStopsDecodingImmediately() {
        var line = [UInt8](repeating: 0xFF, count: 16)
        line[1] = 7 // end-of-stream marker
        let pcm = ADPCMDecoder.toPCMMono(Data(line))
        XCTAssertTrue(pcm.isEmpty)
    }

    func testLoopEndFlagStopsAfterOneLine() {
        var line1 = [UInt8](repeating: 0, count: 16)
        line1[1] = 1 // LoopEnd bit set
        var line2 = [UInt8](repeating: 0, count: 16)
        line2[1] = 0
        let pcm = ADPCMDecoder.toPCMMono(Data(line1 + line2))
        // Only the first (loop-end) line should be decoded.
        XCTAssertEqual(pcm.count, 28)
    }

    func testShorterThanOneLineDecodesToNothing() {
        let pcm = ADPCMDecoder.toPCMMono(Data([0, 0, 0]))
        XCTAssertTrue(pcm.isEmpty)
    }

    /// A single nibble of 1 with factor=0, predict=0 (no history) should
    /// decode to exactly `1 << 12 = 4096` — the standard PS-ADPCM
    /// nibble-to-top-of-word sign-extension, with no predictor contribution
    /// on the very first sample (history starts at zero).
    func testFirstSampleMatchesRawNibbleShift() {
        var line = [UInt8](repeating: 0, count: 16)
        line[0] = 0 // factor=0, predict=0
        line[1] = 0
        line[2] = 0x01 // low nibble = 1 -> first decoded sample
        let pcm = ADPCMDecoder.toPCMMono(Data(line))
        XCTAssertEqual(pcm.first, 4096)
    }
}
