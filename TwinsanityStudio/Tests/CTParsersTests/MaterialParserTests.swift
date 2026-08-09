import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class MaterialParserTests: XCTestCase {
    /// Builds one `TwinsShader` block exactly matching `TwinsShader.Read`'s
    /// non-Demo, non-SMBA field order (`TwinsShader.cs:74-149`) for
    /// `shaderType == 0` (no variable-length parameter prefix).
    private func synthesizeShader(shaderType: UInt32, textureId: UInt32) -> Data {
        var w = BinaryWriter()
        w.writeUInt32(shaderType)
        // No variable params for shaderType 0.
        w.writeBytes([UInt8](repeating: 0, count: 17)) // 17 single-byte fields
        w.writeUInt8(0) // UsePresetAlphaRegSettings
        w.writeBytes([UInt8](repeating: 0, count: 6))
        w.writeBytes([UInt8](repeating: 0, count: 3)) // AlphaCorrectionValue, UnkFlag1, UnkFlag2
        w.writeUInt8(0) // ZValueDrawingMask
        w.writeBytes([0, 0]) // UnkFlag3, BlobFlag (Demo == false)
        w.writeUInt16(0) // LodParamK
        w.writeUInt16(0) // LodParamL
        w.writeBytes([UInt8](repeating: 0, count: 48)) // 3 x TwinsVector4
        w.writeUInt32(textureId)
        w.writeUInt32(shaderType) // trailing repeated ShaderType
        return w.data
    }

    func testParsesNameAndSingleShaderTextureID() throws {
        var w = BinaryWriter()
        w.writeUInt64(2) // Header
        w.writeInt32(2)  // Unknown
        let name = "Crash_Body"
        w.writeInt32(Int32(name.utf8.count))
        w.writeASCIIString(name)
        w.writeInt32(1) // shader count
        w.writeBytes(synthesizeShader(shaderType: 0, textureId: 42))

        var cursor = BinaryCursor(data: w.data)
        let material = try MaterialParser.parse(&cursor, recordID: 7)

        XCTAssertEqual(material.name, "Crash_Body")
        XCTAssertEqual(material.shaders.count, 1)
        XCTAssertEqual(material.primaryTextureID, 42)
    }

    func testParsesMultipleShadersInOrder() throws {
        var w = BinaryWriter()
        w.writeUInt64(2)
        w.writeInt32(2)
        w.writeInt32(0) // empty name
        w.writeInt32(2) // shader count
        w.writeBytes(synthesizeShader(shaderType: 0, textureId: 10))
        w.writeBytes(synthesizeShader(shaderType: 0, textureId: 20))

        var cursor = BinaryCursor(data: w.data)
        let material = try MaterialParser.parse(&cursor, recordID: 1)

        XCTAssertEqual(material.shaders.map(\.textureId), [10, 20])
        XCTAssertEqual(material.primaryTextureID, 10) // first shader wins
    }

    func testShaderType23HasExtraParamBytes() throws {
        // ShaderType 23 reads an extra uint32 + 2 floats before the common fields.
        var shader = BinaryWriter()
        shader.writeUInt32(23)
        shader.writeUInt32(0)   // IntParam
        shader.writeFloat32(0) // FloatParam[0]
        shader.writeFloat32(0) // FloatParam[1]
        shader.writeBytes([UInt8](repeating: 0, count: 17))
        shader.writeUInt8(0)
        shader.writeBytes([UInt8](repeating: 0, count: 6))
        shader.writeBytes([UInt8](repeating: 0, count: 3))
        shader.writeUInt8(0)
        shader.writeBytes([0, 0])
        shader.writeUInt16(0)
        shader.writeUInt16(0)
        shader.writeBytes([UInt8](repeating: 0, count: 48))
        shader.writeUInt32(99) // textureId
        shader.writeUInt32(23)

        var w = BinaryWriter()
        w.writeUInt64(2)
        w.writeInt32(2)
        w.writeInt32(0)
        w.writeInt32(1)
        w.writeBytes(shader.data)

        var cursor = BinaryCursor(data: w.data)
        let material = try MaterialParser.parse(&cursor, recordID: 3)
        XCTAssertEqual(material.primaryTextureID, 99)
    }

    /// A corrupt/crafted record could declare a huge shader count with no
    /// real shader data behind it — should throw the normal, catchable
    /// error from running out of real bytes, not attempt a huge blind
    /// `reserveCapacity` allocation before a single shader is read.
    func testHugeDeclaredShaderCountThrowsInsteadOfOverAllocating() {
        var w = BinaryWriter()
        w.writeUInt64(2)
        w.writeInt32(2)
        w.writeInt32(0) // empty name
        w.writeInt32(Int32.max) // shader count — declared ~2 billion, no data behind it

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try MaterialParser.parse(&cursor, recordID: 1)) { error in
            XCTAssertTrue(error is BinaryCursorError)
        }
    }
}
