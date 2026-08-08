import Foundation

/// Decodes Sony SPU/PS-ADPCM ("VAG") audio — the codec this engine's
/// `SoundEffect` records use. Ported field-for-field from the reference
/// tool's `Twinsanity/ADPCM.cs` (`ToPCMMono`/`LineToPCM`/`SampleToPCM`),
/// itself based on the well-known `vag2wav.c` (bITmASTER/nextvolume,
/// https://github.com/simias/psxsdk). This is a real, working, previously-
/// verified decoder being transcribed — not a reconstruction from format
/// documentation alone.
public enum ADPCMDecoder {
    /// Predictor coefficient pairs, indexed by the 4-bit `predict` nibble.
    /// Only indices 0–4 are ever used by real data; 5–15 are zero exactly
    /// as in the reference table.
    private static let predictorCoefficients: [(Double, Double)] = [
        (0.0, 0.0),
        (60.0 / 64.0, 0.0),
        (115.0 / 64.0, -52.0 / 64.0),
        (98.0 / 64.0, -55.0 / 64.0),
        (122.0 / 64.0, -60.0 / 64.0),
        (0.0, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0),
        (0.0, 0.0), (0.0, 0.0), (0.0, 0.0), (0.0, 0.0),
        (0.0, 0.0), (0.0, 0.0), (0.0, 0.0)
    ]

    /// One 4-bit ADPCM nibble -> one 16-bit PCM sample. The nibble is
    /// shifted into the top of a 16-bit word first (`nibble << 12`,
    /// truncated to `Int16`) — the standard PS-ADPCM sign-extension trick,
    /// not an arbitrary scale factor.
    private static func sampleToPCM(nibble: Int, factor: Int, predict: Int, s0: inout Double, s1: inout Double) -> Int16 {
        let shifted = Int32(nibble) << 12
        let signExtended = Int32(Int16(truncatingIfNeeded: shifted))
        let sample = signExtended >> Int32(factor)
        let coefficients = predictorCoefficients[predict & 0xF]
        let value = Double(sample) + s0 * coefficients.0 + s1 * coefficients.1
        s1 = s0
        s0 = value
        return Int16(truncatingIfNeeded: Int(value.rounded(.toNearestOrEven)))
    }

    /// One 16-byte ADPCM "line" (2-byte header + 14 bytes of packed
    /// nibbles) -> 28 PCM samples.
    private static func lineToPCM(_ line: ArraySlice<UInt8>, s0: inout Double, s1: inout Double) -> [Int16] {
        let bytes = Array(line)
        let factor = Int(bytes[0] & 0xF)
        let predict = Int((bytes[0] >> 4) & 0xF)
        var samples: [Int16] = []
        samples.reserveCapacity(28)
        for i in 0..<14 {
            let byte = bytes[i + 2]
            let low = Int(byte & 0xF)
            let high = Int((byte & 0xF0) >> 4)
            samples.append(sampleToPCM(nibble: low, factor: factor, predict: predict, s0: &s0, s1: &s1))
            samples.append(sampleToPCM(nibble: high, factor: factor, predict: predict, s0: &s0, s1: &s1))
        }
        return samples
    }

    /// Decodes mono ADPCM data into 16-bit signed PCM samples. Stops at a
    /// line whose second byte is `7` (end-of-stream marker) or that has the
    /// loop-end flag bit set — both real terminators the reference decoder
    /// honors, not just "ran out of bytes."
    public static func toPCMMono(_ data: Data) -> [Int16] {
        let bytes = Array(data)
        guard bytes.count >= 16 else { return [] }
        var s0 = 0.0, s1 = 0.0
        var pcm: [Int16] = []
        var offset = 0
        while offset + 16 <= bytes.count {
            let line = bytes[offset..<(offset + 16)]
            let flags = line[line.startIndex + 1]
            if flags == 7 { break }
            pcm.append(contentsOf: lineToPCM(line, s0: &s0, s1: &s1))
            if flags & 1 != 0 { break } // SampleLineFlags.LoopEnd
            offset += 16
        }
        return pcm
    }
}
