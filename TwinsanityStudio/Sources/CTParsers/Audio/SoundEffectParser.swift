import Foundation
import CTCore
import CTModels

/// Decodes a `SoundEffect` record — ported from
/// `Twinsanity/Items/Code/SoundEffect.cs`. Unlike every other leaf record
/// type this package decodes, a `SoundEffect`'s actual audio bytes aren't
/// inside its own 22-byte record: `soundOffset`/`soundSize` index into the
/// *enclosing section's* trailing "extra data" region (everything past the
/// last indexed sub-item — see `RM2Parser`'s dedicated `.se`-family
/// wiring), so decoding happens in two steps: read the small header record,
/// then resolve it against that shared blob.
public enum SoundEffectParser {
    public struct RawRecord: Sendable {
        public var recordID: UInt32
        public var freqFac: UInt8
        public var soundSize: UInt32
        public var soundOffset: UInt32
    }

    /// The 22-byte `SoundEffect` header: `Head`(4) + `UnkFlag`(1) +
    /// `FreqFac`(1) + `Param1..4`(2 each) + `SoundSize`(4) + `SoundOffset`(4).
    public static func parseHeader(_ cursor: inout BinaryCursor, recordID: UInt32) throws -> RawRecord {
        _ = try cursor.readUInt32() // Head
        _ = try cursor.readUInt8()  // UnkFlag
        let freqFac = try cursor.readUInt8()
        _ = try cursor.readUInt16() // Param1
        _ = try cursor.readUInt16() // Param2
        _ = try cursor.readUInt16() // Param3
        _ = try cursor.readUInt16() // Param4
        let soundSize = try cursor.readUInt32()
        let soundOffset = try cursor.readUInt32()
        return RawRecord(recordID: recordID, freqFac: freqFac, soundSize: soundSize, soundOffset: soundOffset)
    }

    /// `FreqFac` -> real sample rate, ported from `SoundEffect.GetFreq`.
    /// Any value not in this table is one the reference tool itself
    /// rejects (`throw new ArgumentException`) rather than approximates —
    /// mirrored here by returning `nil` instead of guessing a rate.
    public static func sampleRate(forFreqFac freqFac: UInt8) -> UInt16? {
        switch freqFac {
        case 0x2: return 8000
        case 0x3: return 10000
        case 0x4: return 11025
        case 0x5: return 16000
        case 0x6: return 18000
        case 0x7: return 22050
        case 0xA: return 32000
        case 0xE: return 44100
        case 0x10: return 48000
        default: return nil
        }
    }

    /// Slices this record's ADPCM bytes out of the enclosing section's
    /// extra-data blob and decodes them.
    public static func resolve(_ record: RawRecord, extraData: Data) -> SoundEffectAsset? {
        guard let freq = sampleRate(forFreqFac: record.freqFac) else { return nil }
        let start = Int(record.soundOffset)
        let length = Int(record.soundSize)
        guard start >= 0, length >= 0, start + length <= extraData.count else { return nil }
        let soundBytes = extraData.subdata(in: (extraData.startIndex + start)..<(extraData.startIndex + start + length))
        let pcm = ADPCMDecoder.toPCMMono(soundBytes)
        return SoundEffectAsset(id: record.recordID, sampleRateHz: freq, pcmSamples: pcm)
    }
}
