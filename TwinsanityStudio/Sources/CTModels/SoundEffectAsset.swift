import Foundation

/// A decoded `SoundEffect` record (`SectionType.se`/`.seEng`/etc.) — mono,
/// 16-bit PCM already decoded from the on-disk PS-ADPCM data (see
/// `ADPCMDecoder`), ready to hand straight to `AVAudioPCMBuffer`.
public struct SoundEffectAsset: Sendable, Identifiable {
    public let id: UInt32
    public var sampleRateHz: UInt16
    public var pcmSamples: [Int16]
    /// Absolute file offset and byte length of this sound's real ADPCM
    /// bytes — *not* within this record's own `ChunkNode.byteSize` (a
    /// `SoundEffect` record is just a 22-byte header; the audio itself
    /// lives in the *enclosing section's* trailing "extra data" blob, see
    /// `RM2Parser`'s `.se`-family wiring). `nil` for a `SoundEffectAsset`
    /// resolved from a standalone `.MH`/`.MB` sound bank instead of a
    /// per-level record — that path has no enclosing chunk section for
    /// this offset to be relative to. Populated only by
    /// `SoundEffectParser.resolve`, so "Replace with Audio…" write-back
    /// knows exactly which bytes to patch without re-deriving this from
    /// the section's index table a second time.
    public var sourceAudioByteRange: (offset: Int, length: Int)?

    public init(id: UInt32, sampleRateHz: UInt16, pcmSamples: [Int16], sourceAudioByteRange: (offset: Int, length: Int)? = nil) {
        self.id = id
        self.sampleRateHz = sampleRateHz
        self.pcmSamples = pcmSamples
        self.sourceAudioByteRange = sourceAudioByteRange
    }

    public var durationSeconds: Double {
        sampleRateHz > 0 ? Double(pcmSamples.count) / Double(sampleRateHz) : 0
    }
}
