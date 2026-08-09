import Foundation
import CTCore
import CTModels

/// Decodes a `Material` record: a name plus one or more `TwinsShader` blocks,
/// each ending in the texture ID it samples. Ported field-for-field from
/// `Twinsanity/Items/Graphics/Material.cs` and `Twinsanity/TwinsShader.cs`.
///
/// `Material.Load` always calls `TwinsShader.Read(reader, 0, Demo: false, SMBA: isMB)`
/// — the `Demo` flag is hardcoded false at that call site regardless of the
/// enclosing file's actual format (Demo files route through a distinct
/// `MaterialDemo` record type instead), and MonkeyBall (`SMBA`) is out of
/// scope for this package — so this parser always reads the non-Demo,
/// non-SMBA shader layout, matching every real Crash Twinsanity Material.
public enum MaterialParser {
    public static func parse(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> MaterialInfo {
        _ = try cursor.readUInt64() // Header, always 2
        _ = try cursor.readInt32()  // Unknown, always 2
        let nameLen = Int(try cursor.readInt32())
        let name = try cursor.readASCIIString(length: nameLen)
        let shaderCount = try cursor.readInt32()

        var shaders: [TwinsShaderInfo] = []
        shaders.reserveCapacity(cursor.safeReserveCount(shaderCount, elementSize: 94)) // smallest real TwinsShader block
        for _ in 0..<max(0, shaderCount) {
            shaders.append(try readShader(&cursor))
        }
        return MaterialInfo(id: recordID, name: name, shaders: shaders)
    }

    /// Reads one `TwinsShader` block (`TwinsShader.cs:74-149`) and returns
    /// just `shaderType`/`textureId` — the ~90 bytes of PS2 GS render state
    /// in between (alpha blending, depth test, fog, LOD params, ...) are
    /// consumed to stay correctly positioned for the *next* shader, but
    /// aren't modeled since nothing here needs them yet.
    private static func readShader(_ cursor: inout BinaryCursor) throws -> TwinsShaderInfo {
        let shaderType = try cursor.readUInt32()

        // Variable-length parameter block, keyed by shader type.
        switch shaderType {
        case 23:
            _ = try cursor.readUInt32()  // IntParam
            _ = try cursor.readFloat32() // FloatParam[0]
            _ = try cursor.readFloat32() // FloatParam[1]
        case 26:
            _ = try cursor.readUInt32()
            for _ in 0..<4 { _ = try cursor.readFloat32() }
        case 16, 17:
            _ = try cursor.readFloat32()
        default:
            break
        }

        // 17 single-byte render-state fields.
        _ = try cursor.readBytes(17)
        // UsePresetAlphaRegSettings (bool)
        _ = try cursor.readBool()
        // SpecOfColA, SpecOfColB, SpecOfAlphaC, SpecOfColD, FixedAlphaValue, TextureFilter
        _ = try cursor.readBytes(6)
        // AlphaCorrectionValue, UnkFlag1, UnkFlag2 (3 bools)
        _ = try cursor.readBytes(3)
        // ZValueDrawingMask
        _ = try cursor.readUInt8()
        // Demo == false at every real call site: UnkFlag3, BlobFlag (2 bools)
        _ = try cursor.readBytes(2)
        // LodParamK, LodParamL
        _ = try cursor.readUInt16()
        _ = try cursor.readUInt16()
        // UnkVector1, UnkVector2, UnkVector3 (16 bytes each)
        _ = try cursor.readBytes(48)
        // SMBA == false: no extra padding here.

        let textureId = try cursor.readUInt32()
        _ = try cursor.readUInt32() // trailing repeated ShaderType

        return TwinsShaderInfo(shaderType: shaderType, textureId: textureId)
    }
}
