import Foundation

/// One `TwinsShader` entry within a `Material` — the PS2 GS render-state
/// block that, critically, ends with the texture ID this shader samples from
/// (`Twinsanity/TwinsShader.cs:147`). This is the actual link between a mesh
/// submesh's material and its texture; everything else in the original
/// 90+-byte render-state block (alpha blending mode, depth test, fog, LOD
/// params, ...) is real GS state but not needed to answer "which texture
/// does this submesh use," so only `shaderType`/`textureId` are modeled.
public struct TwinsShaderInfo: Sendable {
    public var shaderType: UInt32
    public var textureId: UInt32

    public init(shaderType: UInt32, textureId: UInt32) {
        self.shaderType = shaderType
        self.textureId = textureId
    }
}

/// A decoded `Material` record: a name plus one or more shaders, each
/// pointing at a texture. `primaryTextureID` is the first shader's texture —
/// the common case is exactly one shader per material.
public struct MaterialInfo: Sendable, Identifiable {
    public let id: UInt32
    public var name: String
    public var shaders: [TwinsShaderInfo]

    public init(id: UInt32, name: String, shaders: [TwinsShaderInfo]) {
        self.id = id
        self.name = name
        self.shaders = shaders
    }

    public var primaryTextureID: UInt32? { shaders.first?.textureId }
}
