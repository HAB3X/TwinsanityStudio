import Foundation

/// GS pixel-storage format (`Texture.TexturePixelFormat` in the original tool),
/// plus the Xbox DXT variants which live in a parallel `TextureX` record.
public enum TexturePixelFormat: String, Sendable, CaseIterable {
    case psmct32, psmct24, psmct16, psmct16s
    case psmt8, psmt4, psmt8h, psmt4hl, psmt4hh
    case psmz32, psmz24, psmz16, psmz16s
    case dxt1, dxt3, dxt5
    case rawRGBA
    case unknown

    /// The original tool only fully decodes PSMCT32 and PSMT8 (everything else
    /// falls through to a raw byte passthrough); DXT1/3/5 are Xbox-only and are
    /// fully decoded there. This mirrors that support matrix.
    public var isFullyDecoded: Bool {
        switch self {
        case .psmct32, .psmt8, .dxt1, .dxt3, .dxt5, .rawRGBA: return true
        default: return false
        }
    }
}

/// A fully decoded texture, ready for `CGImage`/`NSImage` presentation. `rgba`
/// is tightly packed, top-row-first, straight (non-premultiplied) alpha,
/// `width * height * 4` bytes.
public struct TextureAsset: Sendable, Identifiable {
    public let id: UInt32
    public var width: Int
    public var height: Int
    public var pixelFormat: TexturePixelFormat
    public var rgba: [UInt8]
    /// Successively half-sized mip levels, same pixel layout as `rgba`.
    public var mips: [[UInt8]]

    public init(id: UInt32, width: Int, height: Int, pixelFormat: TexturePixelFormat, rgba: [UInt8], mips: [[UInt8]] = []) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.rgba = rgba
        self.mips = mips
    }
}
