import Foundation

/// A decoded `SoundEffect` record (`SectionType.se`/`.seEng`/etc.) — mono,
/// 16-bit PCM already decoded from the on-disk PS-ADPCM data (see
/// `ADPCMDecoder`), ready to hand straight to `AVAudioPCMBuffer`.
public struct SoundEffectAsset: Sendable, Identifiable {
    public let id: UInt32
    public var sampleRateHz: UInt16
    public var pcmSamples: [Int16]

    public init(id: UInt32, sampleRateHz: UInt16, pcmSamples: [Int16]) {
        self.id = id
        self.sampleRateHz = sampleRateHz
        self.pcmSamples = pcmSamples
    }

    public var durationSeconds: Double {
        sampleRateHz > 0 ? Double(pcmSamples.count) / Double(sampleRateHz) : 0
    }
}
