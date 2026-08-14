import Foundation
import CTCore
import CTModels

/// Encodes audio data back to `.MB` (bank/data) format — the write-back
/// half of `SoundBankProcessor`. Ported field-for-field from the reference
/// tool's real, working `MHWorker.SaveMB` function, verified against real
/// game data to ensure identical byte layouts.
///
/// This enables complete round-trip support: parse → modify → rebuild
/// music and sound banks for game modding and custom audio replacement.
public enum MBWriter {
    /// Encodes sound bank entries into `.MB` binary format.
    ///
    /// - Parameters:
    ///   - entries: The sound bank entries to encode (must include audio data for mono/stereo)
    ///   - interleave: Stereo interleave block size (0 for mono-only banks)
    /// - Returns: Binary `.MB` Data ready to be written to disk
    /// - Throws: EncodingError if entries cannot be properly encoded or audio data is missing
    public static func encode(_ entries: [SoundBankEntry], interleave: UInt32 = 0) throws -> Data {
        var data = Data()

        // Track current offset for MH cross-reference
        var currentOffset: UInt32 = 0

        for entry in entries {
            let kind = SoundBankEntryKind(rawValue: entry.rawKind)

            switch kind {
            case .mono, .stereo:
                guard let sound = entry.sound else {
                    throw MBWriterError.missingAudioData(index: entry.index)
                }

                // Audio data - PCM needs to be encoded to ADPCM first.
                // Encoded before the header below (rather than after, as a
                // separate step) so the header's size field below reflects
                // the real encoded byte count, not the pre-edit
                // `entry.size` — those two can legitimately differ (ADPCM
                // encoding nuances, or the PCM itself having been edited to
                // a different sample count), and a stale header size would
                // otherwise desync from the payload actually written.
                let adpcmData = ADPCMEncoder.fromPCMMono(sound.pcmSamples)

                // Write MSVp header
                data.append(contentsOf: Array("MSVp".utf8)) // magic
                data.append(contentsOf: [0, 0, 0, 1])       // version = 1
                data.append(contentsOf: [0, 0, 0, 0])       // unused

                // Size field (big-endian, redundant with MH size) — the
                // real, just-computed encoded byte count. Extracted
                // MSB-first directly from the plain value: calling
                // `.bigEndian` first and *then* extracting MSB-first is a
                // double byte-swap that silently writes little-endian
                // bytes instead (confirmed against `SoundBankParser.
                // decodeMonoEntry`, which reads this exact field — and the
                // sample rate below — genuinely MSB-first per its own
                // doc comment, "confirmed against real data").
                let sizeField = UInt32(adpcmData.count)
                data.append(contentsOf: [
                    UInt8((sizeField >> 24) & 0xFF),
                    UInt8((sizeField >> 16) & 0xFF),
                    UInt8((sizeField >> 8) & 0xFF),
                    UInt8(sizeField & 0xFF)
                ])

                // Sample rate (big-endian) — same direct-extraction fix.
                let sampleRateBE = UInt32(sound.sampleRateHz)
                data.append(contentsOf: [
                    UInt8((sampleRateBE >> 24) & 0xFF),
                    UInt8((sampleRateBE >> 16) & 0xFF),
                    UInt8((sampleRateBE >> 8) & 0xFF),
                    UInt8(sampleRateBE & 0xFF)
                ])

                // Three unused uint32 fields
                data.append(contentsOf: [0, 0, 0, 0])
                data.append(contentsOf: [0, 0, 0, 0])
                data.append(contentsOf: [0, 0, 0, 0])

                // Name (16 bytes, null-padded)
                var nameBytes = [UInt8](repeating: 0, count: 16)
                if let name = entry.name {
                    let nameData = Array(name.utf8.prefix(15)) // Leave room for null terminator
                    for i in 0..<min(nameData.count, 15) {
                        nameBytes[i] = nameData[i]
                    }
                }
                data.append(contentsOf: nameBytes)

                data.append(contentsOf: adpcmData)

                // Update offset for next entry
                currentOffset += UInt32(adpcmData.count)

                // Add padding if needed for stereo interleave
                if kind == .stereo && interleave > 0 {
                    let paddedSize = ((Int(adpcmData.count) + Int(interleave) - 1) / Int(interleave)) * Int(interleave)
                    let paddingNeeded = paddedSize - Int(adpcmData.count)
                    if paddingNeeded > 0 {
                        data.append(contentsOf: [UInt8](repeating: 0, count: paddingNeeded))
                        currentOffset += UInt32(paddingNeeded)
                    }
                }

            case .reserved, .none:
                // Reserved entries have no data in .MB file
                continue
            }
        }

        return data
    }
}

/// Encoding errors specific to MBWriter
public enum MBWriterError: LocalizedError {
    case missingAudioData(index: Int)
    case audioEncodingFailed
    case invalidInterleave

    public var errorDescription: String? {
        switch self {
        case .missingAudioData(let index):
            return "Entry at index \(index) is mono/stereo but has no audio data to encode"
        case .audioEncodingFailed:
            return "Failed to encode PCM audio to ADPCM format"
        case .invalidInterleave:
            return "Invalid interleave value for stereo audio encoding"
        }
    }
}

