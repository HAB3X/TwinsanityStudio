import Foundation
import CTCore
import CTModels

/// Encodes a `TextureAsset` back to its on-disk pixel-data bytes — the
/// write-back half of `TextureParser`'s decode, needed for "Asset Swap &
/// Quick-Test: Recipe Book" (blueprint 6.4)'s sprite-sheet/texture-replace
/// feature (see `RecipeBookView`'s doc comment for why that was blocked
/// until this existed: nothing in `CTParsers`/`CTExport` wrote a texture
/// record back to its on-disk compressed form).
///
/// Only PSMCT32 is supported. It's the one GS format `TextureParser`
/// decodes as a flat, unswizzled byte passthrough (no GS block-swizzling,
/// no CLUT/palette) — `decodePSMCT32` is genuinely just "copy RGB, widen
/// GS's 7-bit alpha to 8-bit," so its inverse is an exact, verifiable
/// round trip. PSMT8 (indexed + GS-block-swizzled via `EzSwizzle`, plus a
/// palette that would need real color quantization to re-populate from an
/// arbitrary replacement image) and every other GS format aren't attempted
/// here — re-swizzling and re-quantizing are real, separate pieces of work
/// this session doesn't build guessed-at.
public enum TextureWriter {
    public enum TextureWriteError: Error, LocalizedError {
        case unsupportedFormat(TexturePixelFormat)
        case sizeMismatch(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "Writing \(format.rawValue.uppercased()) textures back to disk isn't supported yet — only PSMCT32 has a known, verified encode."
            case .sizeMismatch(let expected, let actual):
                return "Expected \(expected) byte(s) of pixel data, got \(actual) — the replacement image must resample to the original texture's exact dimensions."
            }
        }
    }

    /// Replays `TextureParser.parse`'s exact fixed-field read sequence (texSize
    /// through the 96-byte VIF block — every field it reads but doesn't retain
    /// on `TextureAsset`) purely to find where the header ends and pixel data
    /// begins, and returns that cursor position. Deliberately not a hardcoded
    /// constant: this format's own `texSize` field excludes its own 4 bytes
    /// (so "pixel data starts at byte 224" — `pixelDataLength = texSize - 224`
    /// in `TextureParser` — is relative to *that* convention, not to this
    /// record's true byte 0), and re-deriving the real offset by walking the
    /// same fields the parser does can't drift out of sync with it the way a
    /// second hardcoded number could.
    private static func headerLength(of originalRecordBytes: Data) throws -> Int {
        var cursor = BinaryCursor(data: originalRecordBytes)
        _ = try cursor.readInt32() // texSize
        _ = try cursor.readInt32() // unkInt
        _ = try cursor.readInt16() // wLog2
        _ = try cursor.readInt16() // hLog2
        _ = try cursor.readUInt8() // m
        _ = try cursor.readUInt8() // format
        _ = try cursor.readUInt8() // destinationFormat
        _ = try cursor.readUInt8() // texColComponent
        _ = try cursor.readUInt8() // unkByte
        _ = try cursor.readUInt8() // textureFun
        _ = try cursor.readBytes(2) // unkBytes
        _ = try cursor.readInt32() // textureBasePointer
        for _ in 0..<6 { _ = try cursor.readInt32() } // mipLevelsTBP
        _ = try cursor.readInt32() // textureBufferWidth
        for _ in 0..<6 { _ = try cursor.readInt32() } // mipLevelsTBW
        _ = try cursor.readInt32() // clutBufferBasePointer
        _ = try cursor.readBytes(8) // unkBytes2
        _ = try cursor.readInt32() // reserved: vifCodeBlock index
        _ = try cursor.readInt32() // reserved: unknown pointer
        _ = try cursor.readBytes(2) // unkBytes3
        _ = try cursor.readBytes(2) // reserved
        _ = try cursor.readBytes(32) // unusedMetadata
        _ = try cursor.readBytes(96) // vifBlock
        return cursor.position
    }

    /// Inverse of `TextureParser.decodePSMCT32`: RGBA8 -> raw GS PSMCT32
    /// bytes. The decode widens GS's 7-bit alpha (0...128) to 8-bit
    /// (`<< 1`); this narrows it back (`>> 1`) — an exact round trip for
    /// every alpha value the decode can itself produce.
    public static func encodePSMCT32(rgba: [UInt8]) -> Data {
        var out = [UInt8](repeating: 0, count: rgba.count)
        var i = 0
        while i + 3 < rgba.count {
            out[i] = rgba[i]
            out[i + 1] = rgba[i + 1]
            out[i + 2] = rgba[i + 2]
            out[i + 3] = UInt8(clamping: Int(rgba[i + 3]) >> 1)
            i += 4
        }
        return Data(out)
    }

    /// Re-encodes `asset`'s current base-level `rgba` (mips aren't written
    /// back) into a full replacement for the original on-disk record:
    /// `originalRecordBytes`'s first `headerLength` bytes are copied
    /// verbatim, everything after is replaced with freshly encoded pixel
    /// data. Fails closed — rather than silently truncating/padding — if
    /// `asset` isn't PSMCT32, or if the encoded pixel data isn't exactly
    /// the same length as what it's replacing, so this can never change a
    /// record's total size (this codebase's write paths never do).
    public static func replacingPixelData(of asset: TextureAsset, inOriginalRecordBytes originalRecordBytes: Data) throws -> Data {
        guard asset.pixelFormat == .psmct32 else {
            throw TextureWriteError.unsupportedFormat(asset.pixelFormat)
        }
        let headerLength = try headerLength(of: originalRecordBytes)
        guard originalRecordBytes.count >= headerLength else {
            throw TextureWriteError.sizeMismatch(expected: headerLength, actual: originalRecordBytes.count)
        }
        let expectedPixelLength = originalRecordBytes.count - headerLength
        let encoded = encodePSMCT32(rgba: asset.rgba)
        guard encoded.count == expectedPixelLength else {
            throw TextureWriteError.sizeMismatch(expected: expectedPixelLength, actual: encoded.count)
        }
        return originalRecordBytes.prefix(headerLength) + encoded
    }
}
