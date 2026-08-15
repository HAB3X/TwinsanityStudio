import SwiftUI
import AVFoundation
import CTParsers

/// Browses real, decoded clips from WoC's centralized `SFX.DAT` archive
/// (see `WOCSoundParser`'s doc comment for the confirmed container/codec
/// format). The archive has no per-clip names -- every entry is a real
/// clip, addressed only by its index into the archive's own table -- so
/// this is a flat, index-ordered list rather than a named/categorized
/// browser.
struct WOCSoundBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let archiveURL: URL

    @State private var entries: [WOCSoundParser.Entry] = []
    @State private var isLoadingTable = true
    @State private var loadError: String?

    @State private var decodingIndex: Int?
    @State private var playingIndex: Int?
    @State private var decodeError: String?
    @State private var player: AVAudioPlayer?
    @State private var playerDelegate: PlaybackEndDelegate?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WoC Sound Browser")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()

            if isLoadingTable {
                ProgressView("Reading SFX.DAT's table…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("Couldn't Read Archive", systemImage: "exclamationmark.triangle", description: Text(loadError))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                statusBar
                Divider()
                List(entries) { entry in
                    row(for: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
        .task { await loadTable() }
        .onDisappear { player?.stop() }
    }

    private var statusBar: some View {
        Text("\(entries.count) real clips decoded from PS-ADPCM (\"VAGp\") audio, centralized in one archive shared by every level -- no per-level sound files exist.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(for entry: WOCSoundParser.Entry) -> some View {
        HStack {
            Text("#\(entry.index)")
                .font(.body.monospaced())
                .frame(width: 56, alignment: .leading)
            Text(byteCountFormatted(entry.size))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer()
            if decodingIndex == entry.index {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    toggle(entry)
                } label: {
                    Image(systemName: playingIndex == entry.index ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
    }

    private func byteCountFormatted(_ bytes: UInt32) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func loadTable() async {
        do {
            let parsed = try await Task.detached {
                try WOCSoundParser.parseTable(fileURL: archiveURL)
            }.value
            entries = parsed
        } catch {
            loadError = "\(error)"
        }
        isLoadingTable = false
    }

    private func toggle(_ entry: WOCSoundParser.Entry) {
        if playingIndex == entry.index {
            player?.stop()
            playingIndex = nil
            return
        }
        player?.stop()
        playingIndex = nil
        decodeError = nil
        decodingIndex = entry.index
        Task {
            do {
                let clip = try await Task.detached {
                    try WOCSoundParser.decode(entry, fileURL: archiveURL)
                }.value
                decodingIndex = nil
                guard !clip.samples.isEmpty else {
                    decodeError = "Entry #\(entry.index) decoded to zero samples."
                    return
                }
                let wav = WAVEncoder.encode(pcm: clip.samples, sampleRateHz: UInt16(clamping: clip.sampleRate))
                let newPlayer = try AVAudioPlayer(data: wav)
                let delegate = PlaybackEndDelegate { playingIndex = nil }
                newPlayer.delegate = delegate
                playerDelegate = delegate
                player = newPlayer
                newPlayer.prepareToPlay()
                if newPlayer.play() {
                    playingIndex = entry.index
                }
            } catch {
                decodingIndex = nil
                decodeError = "Couldn't decode entry #\(entry.index): \(error)"
            }
        }
    }
}
