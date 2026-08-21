import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// `TwinsPTCParser` — `.ptc`/`.psm`/`.psf` files, standalone font/particle
/// texture-atlas containers entirely outside the `.RM2`/`.SM2` chunk tree.
/// Ported from `Twinsanity/Items/TwinsPTC.cs`/`TwinsPSM.cs`/`TwinsPSF.cs`.
final class TwinsPTCParserTests: XCTestCase {
    /// A minimal, real, decodable `Texture` record — the same 224-byte
    /// header shape `TextureParserTests.synthesizeHeader` builds (every
    /// field present, in `Texture.Load`'s exact on-disk order), with one
    /// solid 1×1 PSMCT32 pixel. Kept minimal here since this file is
    /// testing the `.ptc`/`.psm`/`.psf` *container* format, not texture
    /// decoding itself — `TextureParserTests` already owns verifying the
    /// header/pixel-decode logic in depth.
    private func makeTinyTexture() -> Data {
        var w = BinaryWriter()
        let pixelData: [UInt8] = [0xFF, 0x00, 0x00, 0x80] // one opaque-ish red pixel
        w.writeInt32(Int32(224 + pixelData.count)) // texSize
        w.writeInt32(0) // unkInt
        w.writeInt16(0) // w (log2 of 1)
        w.writeInt16(0) // h (log2 of 1)
        w.writeUInt8(1) // m (mipCount + 1)
        w.writeUInt8(0) // format: PSMCT32
        w.writeUInt8(0) // destinationFormat
        w.writeUInt8(1) // texColComponent (RGBA)
        w.writeUInt8(0) // unkByte
        w.writeUInt8(0) // textureFun
        w.writeBytes([0, 0]) // unkBytes
        w.writeInt32(0) // textureBasePointer
        for _ in 0..<6 { w.writeInt32(0) } // mipTBP
        w.writeInt32(1) // textureBufferWidth
        for _ in 0..<6 { w.writeInt32(0) } // mipTBW
        w.writeInt32(0) // clutBufferBasePointer
        w.writeBytes([UInt8](repeating: 0, count: 8)) // unkBytes2
        w.writeInt32(0); w.writeInt32(0) // reserved
        w.writeBytes([0, 0]) // unkBytes3
        w.writeBytes([0, 0]) // reserved
        w.writeBytes([UInt8](repeating: 0, count: 32)) // unusedMetadata
        var vifBlock = [UInt8](repeating: 0, count: 96)
        withUnsafeBytes(of: Int32(1).littleEndian) { vifBlock.replaceSubrange(48..<52, with: $0) } // rrw = 1
        withUnsafeBytes(of: Int32(1).littleEndian) { vifBlock.replaceSubrange(52..<56, with: $0) } // rrh = 1
        w.writeBytes(vifBlock)
        w.writeBytes(pixelData)
        return w.data
    }

    /// A minimal, real, decodable `Material` record with zero shaders —
    /// `MaterialParserTests`' own field order (`Header`(8)/`Unknown`(4)/
    /// name/`shaderCount`).
    private func makeTinyMaterial() -> Data {
        var w = BinaryWriter()
        w.writeUInt64(2) // Header
        w.writeInt32(2) // Unknown
        let name = "Mat"
        w.writeInt32(Int32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeInt32(0) // shader count
        return w.data
    }

    /// Builds a real `TwinsPTC` entry's bytes by parsing a minimal texture/
    /// material fixture once (via the real parsers, not hand-rolled bytes)
    /// and using the real byte length each decoded to — avoids needing to
    /// hand-derive the exact Texture/Material byte layout in this test
    /// file too; `TextureParserTests`/`MaterialParserTests` already own
    /// verifying those formats themselves.
    private func makeEntryBytes(texID: UInt32, matID: UInt32) throws -> Data {
        var w = BinaryWriter()
        w.writeUInt32(texID)
        w.writeUInt32(matID)
        w.writeBytes(makeTinyTexture())
        w.writeBytes(makeTinyMaterial())
        return w.data
    }

    func testParseEntryDecodesTexIDMatIDAndEmbeddedRecords() throws {
        let data = try makeEntryBytes(texID: 10, matID: 20)
        var cursor = BinaryCursor(data: data)
        let entry = try TwinsPTCParser.parseEntry(&cursor)
        XCTAssertEqual(entry.texID, 10)
        XCTAssertEqual(entry.matID, 20)
        XCTAssertEqual(entry.texture.width, 1)
        XCTAssertEqual(entry.texture.height, 1)
        XCTAssertEqual(entry.material.name, "Mat")
        XCTAssertEqual(cursor.position, data.count, "parseEntry must consume exactly the embedded Texture+Material bytes, nothing more")
    }

    func testParsePTCFileIsExactlyOneEntry() throws {
        let data = try makeEntryBytes(texID: 1, matID: 2)
        let entry = try TwinsPTCParser.parsePTCFile(data)
        XCTAssertEqual(entry.texID, 1)
        XCTAssertEqual(entry.matID, 2)
    }

    func testParsePSMReadsEntriesUntilEndOfFileWithNoCountPrefix() throws {
        var data = try makeEntryBytes(texID: 1, matID: 1)
        data.append(try makeEntryBytes(texID: 2, matID: 2))
        data.append(try makeEntryBytes(texID: 3, matID: 3))

        let sheet = try TwinsPTCParser.parsePSM(data, sourceLabel: "TEST")
        XCTAssertEqual(sheet.sourceLabel, "TEST")
        XCTAssertEqual(sheet.entries.count, 3)
        XCTAssertEqual(sheet.entries.map(\.texID), [1, 2, 3])
    }

    func testParsePSFDecodesPagesThenVectorsAndUnkInt() throws {
        var w = BinaryWriter()
        w.writeInt32(2) // page count
        w.writeBytes(try makeEntryBytes(texID: 100, matID: 200))
        w.writeBytes(try makeEntryBytes(texID: 101, matID: 201))
        w.writeInt32(2) // vector count
        w.writeInt32(0xABCD) // UnkInt
        w.writeVector4(SIMD4<Float>(1, 2, 3, 4))
        w.writeVector4(SIMD4<Float>(5, 6, 7, 8))

        let font = try TwinsPTCParser.parsePSF(w.data, sourceLabel: "FONT")
        XCTAssertEqual(font.fontPages.count, 2)
        XCTAssertEqual(font.fontPages.map(\.texID), [100, 101])
        XCTAssertEqual(font.vectors, [SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8)])
        XCTAssertEqual(font.unkInt, 0xABCD)
    }

    func testParsePSFWithZeroPagesAndVectors() throws {
        var w = BinaryWriter()
        w.writeInt32(0)
        w.writeInt32(0)
        w.writeInt32(0)
        let font = try TwinsPTCParser.parsePSF(w.data, sourceLabel: "EMPTY")
        XCTAssertTrue(font.fontPages.isEmpty)
        XCTAssertTrue(font.vectors.isEmpty)
    }
}
