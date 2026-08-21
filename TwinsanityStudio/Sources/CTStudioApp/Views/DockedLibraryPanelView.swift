import SwiftUI

/// "Embedded Library Panel" (Complete UI Overhaul, Part 2): the first real,
/// working step away from every asset browser opening as a separate
/// `.sheet()` — this docks the Textures Hub and Chunk Hub directly in the
/// main workspace's `detail` column (see `ContentView.body`'s `detail:`
/// closure) instead of requiring a popup. The original `.sheet()` entry
/// points for both (`workspace.isTexturesHubPresented`/
/// `workspace.isLevelsHubPresented`) are left completely untouched — this is
/// a second, additive way in, not a replacement, so nothing regresses if the
/// docked version turns out to have an issue.
///
/// Deliberately scoped to the two catalog "Hub" browsers only, not the
/// Model/Collision/Level viewers themselves: those three are real `Window`
/// scenes on purpose (see `GPUViewerWindowHosts.swift`'s doc comment) — they
/// used to be sheets and got moved *out* of the sheet/embedded-view world
/// specifically to dodge a real, observed Metal/`CAMetalLayer` compositing
/// bug. Embedding them back into this split view would risk reintroducing
/// exactly that bug, so they stay as windows; only the lightweight,
/// non-GPU-rendering catalog browsers move.
///
/// Also hosts the "Wrath of Cortex" root-folder settings as a third tab —
/// consolidating what was previously only reachable by opening
/// `WOCLevelsHubView`'s sheet just to see or change the root folder. That
/// sheet (and its "Choose Folder…" button) still exists unchanged; this is
/// a second, always-reachable place to see/change the same
/// `WOCWorkspace.rootURL`.
struct DockedLibraryPanelView: View {
    @Environment(WorkspaceViewModel.self) private var workspace
    @Environment(WOCWorkspace.self) private var wocWorkspace
    @Binding var panel: DockedLibraryPanel?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { panel ?? .textures },
                set: { panel = $0 }
            )) {
                ForEach(DockedLibraryPanel.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(10)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch panel ?? .textures {
        case .textures:
            TexturesHubView(onClose: { panel = nil })
                .environment(workspace)
        case .chunks:
            LevelsHubView(onClose: { panel = nil })
                .environment(workspace)
        case .wocSettings:
            WOCSettingsPanel(onClose: { panel = nil })
        }
    }
}

enum DockedLibraryPanel: String, CaseIterable, Identifiable {
    case textures = "Textures"
    case chunks = "Chunks"
    case wocSettings = "WoC Settings"

    var id: String { rawValue }
}

/// The "isolated WoC settings" surface consolidated into the same embedded
/// panel — previously the only way to see or change `WOCWorkspace.rootURL`
/// was to open `WOCLevelsHubView`'s sheet (Library ▸ Wrath of Cortex Levels)
/// just to reach its "Choose Folder…" button. That sheet still works exactly
/// as before; this is a second, always-visible place for the same setting,
/// living alongside the other two embedded panels rather than in its own
/// separate popup.
private struct WOCSettingsPanel: View {
    @Environment(WOCWorkspace.self) private var wocWorkspace
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wrath of Cortex").font(.title2.bold())
                Spacer()
                Button("Close") { onClose() }
            }
            .padding()
            Divider()
            Form {
                Section {
                    LabeledContent("Root Folder", value: wocWorkspace.rootURL?.path ?? "Not selected")
                    Button("Choose Folder…") { wocWorkspace.chooseRoot() }
                } header: {
                    Text("Disc Location")
                } footer: {
                    Text("Select the mounted WoC disc (or its LEVELS folder). Used by the Wrath of Cortex Levels, Sounds, and Characters browsers.")
                }
                Section("Status") {
                    if wocWorkspace.isScanning {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Scanning…")
                        }
                    } else {
                        LabeledContent("Levels Found", value: "\(wocWorkspace.levels.count)")
                    }
                    LabeledContent("Sound Archive", value: wocWorkspace.soundArchiveURL != nil ? "Found" : "Not found")
                    LabeledContent("Character Archive", value: wocWorkspace.characterArchiveURL != nil ? "Found" : "Not found")
                }
            }
            .formStyle(.grouped)
        }
    }
}
