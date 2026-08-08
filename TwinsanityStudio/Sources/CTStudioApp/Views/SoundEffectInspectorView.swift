import SwiftUI
import AVFoundation
import CTModels

/// Wraps decoded mono 16-bit PCM into an in-memory WAV container — the
/// simplest way to hand it to `AVAudioPlayer`, which wants a recognized
/// container format rather than raw samples. Header layout matches the
/// reference tool's own `MHWorker.WriteHeader` (standard 44-byte
/// RIFF/WAVE/fmt /data layout, PCM format 1).
enum WAVEncoder {
    static func encode(pcm: [Int16], sampleRateHz: UInt16) -> Data {
        var data = Data()
        let dataByteCount = UInt32(pcm.count * 2)
        let byteRate = UInt32(sampleRateHz) * 1 * 2
        let blockAlign: UInt16 = 2

        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: UInt32(36) + dataByteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian: UInt32(16)) // fmt chunk size
        data.append(littleEndian: UInt16(1))  // PCM
        data.append(littleEndian: UInt16(1))  // mono
        data.append(littleEndian: UInt32(sampleRateHz))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: UInt16(16)) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataByteCount)
        for sample in pcm {
            data.append(littleEndian: UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
    mutating func append(littleEndian value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// "Sound Playback": decoded `SoundEffect` audio, with a waveform preview,
/// play/stop, and WAV export.
struct SoundEffectInspectorView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    let node: ChunkNode
    let sound: SoundEffectAsset

    @State private var player: AVAudioPlayer?
    @State private var playerDelegate: PlaybackEndDelegate?
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            waveform
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            Form {
                LabeledContent("Sample Rate", value: "\(sound.sampleRateHz) Hz")
                LabeledContent("Samples", value: "\(sound.pcmSamples.count)")
                LabeledContent("Duration", value: String(format: "%.2fs", sound.durationSeconds))
            }
            .formStyle(.grouped)

            HStack {
                Button {
                    togglePlayback()
                } label: {
                    Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(sound.pcmSamples.isEmpty)
                Button {
                    exportWAV()
                } label: {
                    Label("Export WAV…", systemImage: "square.and.arrow.up")
                }
                .disabled(sound.pcmSamples.isEmpty)
                Spacer()
            }

            if sound.pcmSamples.isEmpty {
                Label("Decoded to zero samples — either genuinely empty, or this record's FreqFac wasn't a recognized sample rate.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onDisappear { player?.stop() }
    }

    private var waveform: some View {
        Canvas { context, size in
            guard !sound.pcmSamples.isEmpty else { return }
            let midY = size.height / 2
            let bucketCount = max(1, Int(size.width))
            let samplesPerBucket = max(1, sound.pcmSamples.count / bucketCount)
            var path = Path()
            for bucket in 0..<bucketCount {
                let start = bucket * samplesPerBucket
                guard start < sound.pcmSamples.count else { break }
                let end = min(start + samplesPerBucket, sound.pcmSamples.count)
                var peak: Int16 = 0
                for i in start..<end {
                    peak = max(peak, abs(sound.pcmSamples[i] == Int16.min ? Int16.max : sound.pcmSamples[i]))
                }
                let amplitude = CGFloat(peak) / CGFloat(Int16.max) * midY
                let x = CGFloat(bucket)
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1)
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        // Belt-and-suspenders beyond the button's own `.disabled(sound.
        // pcmSamples.isEmpty)`: AVAudioPlayer's failure mode for genuinely
        // degenerate audio data isn't guaranteed to be a catchable Swift
        // `Error` (some AVFoundation validation failures surface as an
        // uncatchable Objective-C exception instead) — refusing to even
        // attempt construction for zero-sample audio removes that path
        // entirely rather than hoping `try?` catches it.
        guard !sound.pcmSamples.isEmpty else {
            workspace.lastError = "This sound decoded to zero samples — nothing to play."
            return
        }
        let wav = WAVEncoder.encode(pcm: sound.pcmSamples, sampleRateHz: sound.sampleRateHz)
        print("DIAG: Audio selected \"\(node.displayName)\" — \(sound.pcmSamples.count) samples @ \(sound.sampleRateHz) Hz, \(wav.count) byte WAV container")
        let newPlayer: AVAudioPlayer
        do {
            // `try?` here used to swallow the real reason construction
            // failed (unsupported format, corrupt container, ...) — surface
            // it for real instead of a generic "couldn't create a player."
            newPlayer = try AVAudioPlayer(data: wav)
        } catch {
            print("DIAG: AVAudioPlayer(data:) threw: \(error)")
            workspace.lastError = "Couldn't create an audio player for this sound: \(error.localizedDescription)"
            return
        }
        print("DIAG: Audio buffer loaded — format=\(newPlayer.format), duration=\(newPlayer.duration)s, channels=\(newPlayer.numberOfChannels)")
        let delegate = PlaybackEndDelegate { isPlaying = false }
        newPlayer.delegate = delegate
        playerDelegate = delegate
        player = newPlayer
        newPlayer.prepareToPlay()
        let started = newPlayer.play()
        print("DIAG: Audio play command sent — accepted=\(started)")
        if !started {
            workspace.lastError = "AVAudioPlayer.play() returned false — playback didn't start (check system output device/volume)."
        }
        isPlaying = started
    }

    private func exportWAV() {
        guard let directory = ExportPanel.chooseFolder(message: "Choose a folder to export this sound as a .wav file into.") else { return }
        let wav = WAVEncoder.encode(pcm: sound.pcmSamples, sampleRateHz: sound.sampleRateHz)
        let name = node.displayName.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "#", with: "")
        let url = directory.appendingPathComponent(name).appendingPathExtension("wav")
        do {
            try wav.write(to: url)
            workspace.statusMessage = "Exported \(url.lastPathComponent)."
        } catch {
            workspace.lastError = "Export failed: \(error)"
        }
    }
}

/// Flips the Play/Stop button back to "Play" when a clip finishes on its
/// own — without this, the button silently stayed stuck on "Stop" after
/// playback ended naturally instead of via the button itself.
final class PlaybackEndDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [onFinish] in onFinish() }
    }
}
