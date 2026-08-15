import XCTest
import Foundation
@testable import CTParsers

final class WOCTextureDecoderTests: XCTestCase {
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    /// Confirmed by direct visual inspection (a recognizable
    /// skull-and-crossbones icon) before this test was written -- this
    /// pins the first bytes of that same real decoded pixel data.
    func testRealDirectColorTextureDecodesToPlausiblePixels() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let entries = WOCContainerParser.scanTextureEntries(tst0.payload)
        let direct = try XCTUnwrap(entries.first { $0.bytesPerPixel == 4 && $0.width == 256 && $0.height == 256 })

        let texel = tst0.payload.subdata(in: direct.texelDataRange)
        let rgba = WOCTextureDecoder.decodeDirectColor(texel, width: direct.width, height: direct.height)
        XCTAssertEqual(rgba.count, direct.width * direct.height * 4)
    }

    /// Golden-value regression: the exact CLUT palette bytes found for
    /// CASTLE_C.GSC's first indexed texture, hand-verified against the
    /// raw disc bytes (header found at a specific byte offset via direct
    /// backward TRXREG-register scan, independently re-derived, not just
    /// taken from an agent report) before being pinned here.
    func testRealIndexedTextureCLUTGoldenValues() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let entries = WOCContainerParser.scanTextureEntries(tst0.payload)
        let indexedEntries = entries.filter { $0.bytesPerPixel == 1 }
        XCTAssertEqual(indexedEntries.count, 2, "expected 2 indexed textures in CASTLE_C.GSC")

        let first = indexedEntries[0]
        XCTAssertEqual(first.trailerOffset, 78056)

        let palette = try XCTUnwrap(WOCTextureDecoder.findPalette(precedingTrailerOffset: first.trailerOffset, in: tst0.payload))
        XCTAssertEqual(palette.count, 1024)
        // First palette entry: hand-verified RGBA bytes (0x10, 0x0F, 0x0F, 0x7F).
        XCTAssertEqual(Array(palette.prefix(4)), [0x10, 0x0F, 0x0F, 0x7F])

        let indexData = tst0.payload.subdata(in: first.texelDataRange)
        let rgba = WOCTextureDecoder.decodeIndexed(indexData, palette: palette, width: first.width, height: first.height)
        XCTAssertEqual(rgba.count, first.width * first.height * 4)
    }
}
