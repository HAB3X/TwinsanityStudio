import SwiftUI
import CTModels

/// "Audio Bank Extractor & Player" (roadmap 2.4): browses every standalone
/// `.MH`/`.MB` sound bank opened this session (`MUSIC`, `ENGLISH`, ...) —
/// real, global streaming audio banks sitting next to the archive, separate
/// from the per-level `SoundEffect` records the Level Audio panel already
/// covers. A bank list on the left, that bank's real entries (named
/// dialogue lines like "DRC085"/"UKA126" where the `.MB` data carries a
/// name, "undefined"/empty placeholders otherwise) in the middle, and the
/// same waveform/playback/export UI as any other decoded sound on the
/// right.
struct SoundBanksHubView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBankID: SoundBankAsset.ID?
    @State private var selectedEntryID: Int?
    @State private var searchText = ""

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
                    SoundEffectInspectorView(node: nil, displayName: "\(bank.sourceLabel)_\(entry.name ?? "sound\(entry.index)")", sound: sound)
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
}
