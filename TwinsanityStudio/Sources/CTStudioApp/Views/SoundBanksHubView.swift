import SwiftUI
import CTModels
import CTParsers

/// "Audio Bank Extractor & Player" (roadmap 2.4): browses every standalone
/// `.MH`/`.MB` sound bank opened this session (`MUSIC`, `ENGLISH`, ...) —
/// real, global streaming audio banks sitting next to the archive, separate
/// from the per-level `SoundEffect` records the Level Audio panel already
/// covers. A bank list on the left, that bank's real entries (named
/// dialogue lines like "DRC085"/"UKA126" where the `.MB` data carries a
/// name, "undefined"/empty placeholders otherwise) in the middle, and the
/// same waveform/playback/export UI as any other decoded sound on the
/// right.
///
/// "Parity Phase K": bank entries can now be replaced too, via
/// `MHWriter`/`MBWriter` — both existed as verified round-trip encoders
/// with no UI ever calling them (`SoundEffectInspectorView`'s own
/// "Replace with Audio…" only shows for chunk-tree `SoundEffect` records,
/// gated on a real `ChunkNode`, which a bank entry doesn't have). A single
/// `.MB` file packs every entry's audio tightly end-to-end, so — unlike a
/// per-level sound's same-size in-place patch — replacing one bank entry's
/// audio means re-laying out and rewriting the *whole* bank; `MBWriter`
/// already returns the corrected per-entry offsets `MHWriter` needs to
/// stay in sync with that new layout.
struct SoundBanksHubView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBankID: SoundBankAsset.ID?
    @State private var selectedEntryID: Int?
    @State private var searchText = ""
    @State private var isRepacking = false
    @State private var repackError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                bankList
                Divider()
                entryList
                Divider()
                detail
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            if selectedBankID == nil { selectedBankID = workspace.soundBanks.first?.id }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sound Banks").font(.title2.bold())
                Text("\(workspace.soundBanks.count) bank(s) loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.isLoadingSoundBank {
                ProgressView().controlSize(.small)
                Text("Parsing…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { dismiss() }
        }
        .padding()
    }

    private var bankList: some View {
        List(workspace.soundBanks, selection: $selectedBankID) { bank in
            VStack(alignment: .leading, spacing: 2) {
                Text(bank.sourceLabel).font(.callout.bold())
                Text("\(bank.entries.count) entries, \(bank.decodedCount) decoded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .tag(bank.id)
        }
        .frame(width: 200)
        .listStyle(.sidebar)
    }

    private var selectedBank: SoundBankAsset? {
        workspace.soundBanks.first { $0.id == selectedBankID }
    }

    @ViewBuilder
    private var entryList: some View {
        if let bank = selectedBank {
            VStack(spacing: 0) {
                TextField("Search entries…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(filteredEntries(in: bank), selection: $selectedEntryID) { entry in
                    HStack {
                        Image(systemName: icon(for: entry))
                            .foregroundStyle(color(for: entry))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name ?? "#\(entry.index)").lineLimit(1)
                            Text(subtitle(for: entry)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.index)
                }
            }
            .frame(width: 260)
        } else {
            ContentUnavailableView("No Bank Selected", systemImage: "waveform")
                .frame(width: 260)
        }
    }

    private func filteredEntries(in bank: SoundBankAsset) -> [SoundBankEntry] {
        guard !searchText.isEmpty else { return bank.entries }
        return bank.entries.filter { ($0.name ?? "#\($0.index)").localizedCaseInsensitiveContains(searchText) }
    }

    private func icon(for entry: SoundBankEntry) -> String {
        switch entry.kind {
        case .mono: return entry.sound != nil ? "waveform" : "waveform.slash"
        case .stereo: return "waveform.badge.exclamationmark"
        case .reserved: return "circle.dashed"
        case nil: return "questionmark.circle"
        }
    }

    private func color(for entry: SoundBankEntry) -> Color {
        switch entry.kind {
        case .mono: return entry.sound != nil ? .accentColor : .secondary
        case .stereo: return .orange
        case .reserved: return .secondary
        case nil: return .secondary
        }
    }

    private func subtitle(for entry: SoundBankEntry) -> String {
        switch entry.kind {
        case .mono: return entry.sound != nil ? "Mono · \(entry.sampleRateHz) Hz" : "Mono · undecoded"
        case .stereo: return "Stereo — not decoded yet"
        case .reserved: return "Empty"
        case nil: return "Unrecognized type \(entry.rawKind)"
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let bank = selectedBank, let index = selectedEntryID, let entry = bank.entries.first(where: { $0.index == index }) {
            if let sound = entry.sound {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SoundEffectInspectorView(node: nil, displayName: "\(bank.sourceLabel)_\(entry.name ?? "sound\(entry.index)")", sound: sound)
                        Divider()
                        HStack {
                            Button {
                                presentReplaceBankEntryPanel(bank: bank, entryIndex: index)
                            } label: {
                                Label(isRepacking ? "Repacking…" : "Replace with Audio… (repacks bank)", systemImage: "waveform.badge.plus")
                            }
                            .disabled(isRepacking)
                            Spacer()
                            if isRepacking { ProgressView().controlSize(.small) }
                        }
                        Text("Re-encodes a replacement audio file to this entry's own \(sound.sampleRateHz) Hz mono ADPCM, then rebuilds and saves the *whole* bank (.MH + .MB) as an edited copy — this format packs every entry's audio tightly end-to-end, so one entry changing size means every entry after it needs its offset corrected. The original bank files on disk are not modified.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let repackError {
                            Label(repackError, systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    subtitle(for: entry),
                    systemImage: icon(for: entry),
                    description: Text(entry.kind == .stereo
                        ? "This build doesn't have the stereo ADPCM demux ported yet — this slot's real metadata (name, size, sample rate) is shown, but audio isn't decoded."
                        : "This slot has no audio data.")
                )
            }
        } else {
            ContentUnavailableView("No Sound Selected", systemImage: "waveform")
        }
    }

    /// "Parity Phase K" — picks a replacement audio file, resamples it to
    /// `entryIndex`'s own sample rate (same helper `SoundEffectInspectorView.
    /// presentReplaceAudioPanel` uses), swaps it into a copy of `bank.entries`,
    /// then rebuilds the whole bank via `MBWriter`/`MHWriter` and saves both
    /// files to a chosen folder. The in-memory `workspace.soundBanks` isn't
    /// mutated — same "saves an edited copy, never modifies what's open"
    /// discipline as every other write path in this app.
    private func presentReplaceBankEntryPanel(bank: SoundBankAsset, entryIndex: Int) {
        guard let originalSound = bank.entries.first(where: { $0.index == entryIndex })?.sound else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a replacement audio file. It's resampled to this entry's exact \(originalSound.sampleRateHz) Hz mono — the on-disk sample rate can't change."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        repackError = nil
        isRepacking = true
        Task {
            do {
                let pcm = try SoundEffectInspectorView.loadMonoPCM(from: url, targetSampleRateHz: Double(originalSound.sampleRateHz))
                var updatedEntries = bank.entries
                guard let position = updatedEntries.firstIndex(where: { $0.index == entryIndex }) else {
                    isRepacking = false
                    return
                }
                updatedEntries[position].sound = SoundEffectAsset(id: originalSound.id, sampleRateHz: originalSound.sampleRateHz, pcmSamples: pcm)

                let (mbData, correctedEntries) = try MBWriter.encode(updatedEntries, interleave: bank.interleave)
                let mhData = try MHWriter.encode(SoundBankAsset(sourceLabel: bank.sourceLabel, interleave: bank.interleave, entries: correctedEntries), interleave: bank.interleave)

                guard let folder = ExportPanel.chooseFolder(message: "Choose a folder to save the edited \(bank.sourceLabel).MH and \(bank.sourceLabel).MB into. The original bank files are not modified.") else {
                    isRepacking = false
                    return
                }
                try await workspace.writeDataAsync(mhData, to: folder.appendingPathComponent("\(bank.sourceLabel).MH"))
                try await workspace.writeDataAsync(mbData, to: folder.appendingPathComponent("\(bank.sourceLabel).MB"))
                workspace.statusMessage = "Saved edited \(bank.sourceLabel).MH/.MB to \(folder.lastPathComponent) with entry #\(entryIndex) replaced. The original bank files were not modified."
            } catch {
                repackError = "\(error)"
            }
            isRepacking = false
        }
    }
}
