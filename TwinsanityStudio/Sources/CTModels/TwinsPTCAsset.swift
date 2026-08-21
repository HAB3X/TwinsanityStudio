import Foundation
import simd

/// A decoded `TwinsPTC` entry — a texture+material pair embedded *inline*
/// (not by chunk-tree ID reference) inside a `.ptc`/`.psm`/`.psf` file.
/// Ported from `Twinsanity/Items/TwinsPTC.cs`'s real `Load`/`Save`: `TexID`/
/// `MatID` are real on-disk IDs for this pair, followed immediately by a
/// full `Texture` record and a full `Material` record — the exact same
/// on-disk shape `TextureParser`/`MaterialParser` already decode for
/// chunk-tree records, just not addressed by a section index table here.
public struct TwinsPTCEntry: Sendable, Identifiable {
    public var id: UInt32 { texID }
    public var texID: UInt32
    public var matID: UInt32
    public var texture: TextureAsset
    public var material: MaterialInfo

    public init(texID: UInt32, matID: UInt32, texture: TextureAsset, material: MaterialInfo) {
        self.texID = texID
        self.matID = matID
        self.texture = texture
        self.material = material
    }
}

/// A decoded `.psm` file (`Twinsanity/Items/TwinsPSM.cs`) — a flat sequence
/// of `TwinsPTCEntry` packed back-to-back with no count prefix at all;
/// `Load` just keeps reading entries until the stream position reaches the
/// file's own byte length. The reference's `PSMWorker` browses/edits these
/// as a texture-atlas sheet (its own "8-segment 512×512" UI framing is
/// about how it *displays* a `.psm`'s entries, not part of this on-disk
/// shape).
public struct TwinsPSMAsset: Sendable, Identifiable {
    public var id: String { sourceLabel }
    public var sourceLabel: String
    public var entries: [TwinsPTCEntry]

    public init(sourceLabel: String, entries: [TwinsPTCEntry]) {
        self.sourceLabel = sourceLabel
        self.entries = entries
    }
}

/// A decoded `.psf` file (`Twinsanity/Items/TwinsPSF.cs`) — a real font
/// container: a count-prefixed list of `TwinsPTCEntry` "font pages" (the
/// rendered glyph-sheet textures), then a separate count-prefixed list of
/// real `Vector4`s (per-glyph metrics — advance width/UV rect, unconfirmed
/// exact meaning; kept for round-tripping, not interpreted), plus one
/// genuinely undocumented `int32`.
public struct TwinsPSFAsset: Sendable, Identifiable {
    public var id: String { sourceLabel }
    public var sourceLabel: String
    public var fontPages: [TwinsPTCEntry]
    public var vectors: [SIMD4<Float>]
    public var unkInt: Int32

    public init(sourceLabel: String, fontPages: [TwinsPTCEntry], vectors: [SIMD4<Float>], unkInt: Int32) {
        self.sourceLabel = sourceLabel
        self.fontPages = fontPages
        self.vectors = vectors
        self.unkInt = unkInt
    }
}
