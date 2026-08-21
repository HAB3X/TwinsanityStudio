import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @EnvironmentObject private var wocWorkspace: WOCWorkspace
    @Environment(\.openWindow) private var openWindow
    /// "Persist Window Layout" (QoL sweep): `@SceneStorage` only supports a
    /// closed set of primitive types (Bool/Int/Double/String/URL/Data),
    /// and `NavigationSplitViewVisibility` isn't one of them — this stores
    /// a plain `Int` proxy instead and converts through `columnVisibility`
    /// below, but still gets the same "tied to this window's restoration
    /// state, comes back automatically" behavior `@SceneStorage` provides.
    @SceneStorage("columnVisibilityRaw") private var columnVisibilityRaw: Int = 0
    @State private var isTargetedForDrop = false
    @State private var isConsoleExpanded = false

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch columnVisibilityRaw {
                case 1: return .detailOnly
                case 2: return .doubleColumn
                default: return .all
                }
            },
            set: { newValue in
                if newValue == .detailOnly { columnVisibilityRaw = 1 }
                else if newValue == .doubleColumn { columnVisibilityRaw = 2 }
                else { columnVisibilityRaw = 0 }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: columnVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } content: {
                InspectorView(node: workspace.selectedNode)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 480)
            } detail: {
                ViewportPanel(node: workspace.selectedNode)
            }
            Divider()
            EngineConsoleView(isExpanded: $isConsoleExpanded)
        }
        // "Theme/Appearance" (Settings): a real, working in-app control
        // tint — see `WorkspaceViewModel.AccentColorChoice`'s doc comment
        // for why this isn't a claim about overriding the system-wide
        // macOS accent color.
        .tint(workspace.accentColorChoice.color)
        .navigationTitle("Twinsanity Studio")
        .toolbar {
            // "Complete UI Overhaul" (Part 1): the toolbar used to be seven
            // flat, always-visible buttons — Open, Open Memory Card, and
            // five separate hub/tool launchers all fighting for the same
            // row, several of them disabled most of the time. Grouping the
            // asset browsers under one "Library" menu keeps every one of
            // those actions reachable (same underlying `.sheet`/`Bool`
            // bindings, same `.disabled` conditions — nothing about how
            // they work changed) while cutting the toolbar's visual weight
            // roughly in half.
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    presentOpenPanel()
                } label: {
                    Label("Open…", systemImage: "folder.badge.plus")
                }
                .help("Open a .BH archive, .RM2/.SM2 file, or a folder to scan.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    workspace.gameLauncherContext = nil
                    workspace.isGameLauncherPresented = true
                } label: {
                    Label("Play in PCSX2", systemImage: "play.fill")
                }
                .help("Build and boot the full modded game in PCSX2.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button {
                        workspace.isModelsHubPresented = true
                    } label: {
                        Label("Models Hub", systemImage: "square.grid.3x3.fill")
                    }
                    .disabled(workspace.modelsHub.isEmpty && !workspace.isScanning)
                    Button {
                        workspace.isTexturesHubPresented = true
                    } label: {
                        Label("Textures Hub", systemImage: "photo.stack")
                    }
                    .disabled(workspace.texturesHub.isEmpty && !workspace.isScanning)
                    Button {
                        workspace.isLevelsHubPresented = true
                    } label: {
                        Label("Chunk Hub", systemImage: "map")
                    }
                    .disabled(workspace.levelsHub.isEmpty && !workspace.isScanning)
                    Button {
                        workspace.isSoundBanksHubPresented = true
                    } label: {
                        Label("Sound Banks", systemImage: "waveform")
                    }
                    .disabled(workspace.soundBanks.isEmpty && !workspace.isLoadingSoundBank)
                    Button {
                        workspace.isPTCSheetsHubPresented = true
                    } label: {
                        Label("Font & Particle Sheets", systemImage: "textformat")
                    }
                    .disabled(workspace.ptcSheets.isEmpty && workspace.fontSheets.isEmpty)
                    Divider()
                    Button {
                        workspace.isScrappedContentScannerPresented = true
                    } label: {
                        Label("Scrapped Content", systemImage: "questionmark.folder")
                    }
                    .disabled(workspace.orphanedContent.isEmpty && !workspace.isScanning)
                    Button {
                        workspace.isAssetDiffPresented = true
                    } label: {
                        Label("Asset Diff", systemImage: "rectangle.on.rectangle")
                    }
                    .disabled(workspace.modelsHub.count < 2)
                    Button {
                        workspace.isModCrateHubPresented = true
                    } label: {
                        Label("Mod Crate Hub", systemImage: "shippingbox")
                    }
                    Button {
                        workspace.isExecutablePatcherPresented = true
                    } label: {
                        Label("Executable Patcher…", systemImage: "shippingbox.and.arrow.backward")
                    }
                    Button {
                        workspace.isArchiveRepackagerPresented = true
                    } label: {
                        Label("Archive Repackager…", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button {
                        workspace.isImageMakerPresented = true
                    } label: {
                        Label("Image Maker…", systemImage: "opticaldiscdrive.fill")
                    }
                    Divider()
                    Button {
                        presentMemoryCardOpenPanel()
                    } label: {
                        Label("Open Memory Card…", systemImage: "externaldrive")
                    }
                    Button {
                        presentDiscImageOpenPanel()
                    } label: {
                        Label("Mount Disc Image…", systemImage: "opticaldiscdrive")
                    }
                    Button {
                        presentMonkeyBallOpenPanel()
                    } label: {
                        Label("Open as Monkey Ball…", systemImage: "circle.grid.2x2")
                    }
                    .help("Opens a .RM2/.SM2 as a Super Monkey Ball Adventure build — the same shared \"nu2\" engine container format, but with real, distinct Instance/Code/Graphics section layouts this build otherwise never reaches.")
                    Divider()
                    Button {
                        wocWorkspace.isLevelsHubPresented = true
                    } label: {
                        Label("Wrath of Cortex Levels", systemImage: "globe.americas.fill")
                    }
                    Button {
                        wocWorkspace.isSoundBrowserPresented = true
                    } label: {
                        Label("Wrath of Cortex Sounds", systemImage: "waveform")
                    }
                    .disabled(wocWorkspace.soundArchiveURL == nil)
                    Button {
                        wocWorkspace.isCharacterBrowserPresented = true
                    } label: {
                        Label("Wrath of Cortex Characters", systemImage: "person.fill")
                    }
                    .disabled(wocWorkspace.characterArchiveURL == nil)
                } label: {
                    Label("Library", systemImage: "books.vertical.fill")
                }
                .help("Browse decoded assets across every open file, or open a memory card.")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isConsoleExpanded.toggle() }
                } label: {
                    Label("Console", systemImage: "terminal")
                }
                .help("Toggle the Engine Console.")

                if let scanProgress = workspace.scanProgress, scanProgress.total > 0 {
                    // "Visual Loading Feedback" (performance mandate,
                    // Part 4): real fractional progress, not just a spinner
                    // — the determinate ProgressView + percentage text
                    // both track workspace.scanProgress directly, so they
                    // can never show a different number than what actually
                    // finished.
                    ProgressView(value: Double(scanProgress.completed), total: Double(scanProgress.total))
                        .controlSize(.small)
                        .frame(width: 80)
                    Text("\(Int(100 * Double(scanProgress.completed) / Double(scanProgress.total)))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        workspace.cancelScan()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel scanning — whatever's already been parsed stays loaded.")
                } else if workspace.isLoading || workspace.isScanning || workspace.isLoadingSoundBank || workspace.isSaving {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = workspace.lastError {
                StatusBanner(text: error, isError: true) { workspace.lastError = nil }
            } else if !workspace.statusMessage.isEmpty {
                // Informational status ("Scan complete — …") used to have
                // no dismiss button and no timeout, so it sat over the
                // bottom of the sidebar/viewport indefinitely — every
                // status update just replaced the text underneath it.
                // Dismissible now, and auto-clears on its own after a few
                // seconds so it doesn't have to be dismissed by hand every
                // time. `.task(id:)` restarts the timer whenever the
                // message text actually changes, so a fresh status message
                // gets its own full few seconds rather than inheriting
                // whatever was left on the previous one's clock.
                StatusBanner(text: workspace.statusMessage, isError: false) { workspace.statusMessage = "" }
                    .task(id: workspace.statusMessage) {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        workspace.statusMessage = ""
                    }
            }
        }
        .overlay {
            if isTargetedForDrop {
                DropOverlay()
            }
        }
        // The three GPU-heavy viewers open as real windows now, not
        // sheets — see `GPUViewerWindowHosts.swift`'s doc comment. Every
        // existing call site that sets `modelViewerAsset`/
        // `collisionViewerMesh`/`levelViewerContext` is unchanged; this is
        // the one place that reacts to those transitioning to non-nil and
        // actually opens the corresponding window.
        .onChange(of: workspace.modelViewerAsset?.id) { _, newValue in
            if newValue != nil { openWindow(id: GPUViewerWindowID.model) }
        }
        .onChange(of: workspace.collisionViewerMesh?.id) { _, newValue in
            if newValue != nil { openWindow(id: GPUViewerWindowID.collision) }
        }
        .onChange(of: workspace.levelViewerContext?.id) { _, newValue in
            if newValue != nil { openWindow(id: GPUViewerWindowID.level) }
        }
        .onChange(of: wocWorkspace.viewerAsset?.id) { _, newValue in
            if newValue != nil { openWindow(id: WOCViewerWindowID.viewer) }
        }
        // "Tear-Away Workspaces" (roadmap 9.5): the Hex Viewer and Mod
        // Crate Hub open as real windows too, not sheets — see
        // `TearAwayWindowHosts.swift`'s doc comment for why these two
        // specifically (no "closes when you pick something" navigation to
        // fight, unlike the asset-browsing hubs below).
        .onChange(of: workspace.hexViewerNode?.id) { _, newValue in
            if newValue != nil { openWindow(id: TearAwayWindowID.hexViewer) }
        }
        .onChange(of: workspace.isModCrateHubPresented) { _, isPresented in
            if isPresented { openWindow(id: TearAwayWindowID.modCrateHub) }
        }
        .sheet(isPresented: $workspace.isModelsHubPresented) {
            ModelsHubView()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.isTexturesHubPresented) {
            TexturesHubView()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.isLevelsHubPresented) {
            LevelsHubView()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $wocWorkspace.isLevelsHubPresented) {
            WOCLevelsHubView()
                .environmentObject(wocWorkspace)
        }
        .sheet(isPresented: $wocWorkspace.isSoundBrowserPresented) {
            if let soundArchiveURL = wocWorkspace.soundArchiveURL {
                WOCSoundBrowserView(archiveURL: soundArchiveURL)
            }
        }
        .sheet(isPresented: $wocWorkspace.isCharacterBrowserPresented) {
            if let characterArchiveURL = wocWorkspace.characterArchiveURL {
                WOCCharacterArchiveBrowserView(archiveURL: characterArchiveURL)
            }
        }
        .sheet(isPresented: $workspace.isPTCSheetsHubPresented) {
            PTCSheetsHubView()
        }
        .sheet(isPresented: $workspace.isSoundBanksHubPresented) {
            SoundBanksHubView()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.isScrappedContentScannerPresented) {
            ScrappedContentScannerView()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.isAssetDiffPresented) {
            AssetDiffView()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.isExecutablePatcherPresented) {
            ExecutablePatcherView()
        }
        .sheet(isPresented: $workspace.isImageMakerPresented) {
            ImageMakerView()
        }
        .sheet(isPresented: $workspace.isArchiveRepackagerPresented) {
            ArchiveRepackagerView()
        }
        .sheet(isPresented: $workspace.isGameLauncherPresented) {
            GameLauncherView()
        }
        .sheet(item: $workspace.agentLabNode) { node in
            AgentLabGraphView(sectionNode: node)
                .environmentObject(workspace)
        }
        .sheet(isPresented: Binding(
            get: { workspace.memoryCardAsset != nil },
            set: { if !$0 { workspace.memoryCardAsset = nil } }
        )) {
            if let asset = workspace.memoryCardAsset {
                MemoryCardInspectorWindow(asset: asset)
                    .environmentObject(workspace)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenRequested)) { _ in
            presentOpenPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenRecentRequested)) { notification in
            guard let url = notification.object as? URL else { return }
            workspace.open(url: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ctStudioCommandPaletteRequested)) { _ in
            workspace.isCommandPalettePresented = true
        }
        .sheet(isPresented: $workspace.isCommandPalettePresented) {
            CommandPaletteView()
                .environmentObject(workspace)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                }
            }
        }
        group.notify(queue: .main) {
            workspace.open(urls: urls)
        }
        return true
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a .BH archive, .RM2/.SM2 file, or a folder to scan."
        if panel.runModal() == .OK {
            workspace.open(urls: panel.urls)
        }
    }

    private func presentMemoryCardOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a PS2 memory card image (.mcr/.ps2/.mc2)."
        if panel.runModal() == .OK, let url = panel.urls.first {
            workspace.openMemoryCard(url: url)
        }
    }

    /// "Native ISO & BIN/CUE Disc Image Mounting" (Task 7) — a separate
    /// entry point from `presentOpenPanel()`, not a replacement for it:
    /// regular folder/file opening is untouched, this just adds a second,
    /// real way in for a whole disc image.
    private func presentDiscImageOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a disc image: .iso, or .bin/.cue (pick either file — its match is found automatically alongside it)."
        if panel.runModal() == .OK, let url = panel.urls.first {
            workspace.mountDiscImage(url: url)
        }
    }

    /// "MonkeyBall (MB) File-Kind Detection" — see `WorkspaceViewModel.
    /// openAsMonkeyBall`'s own doc comment for why this is a manual entry
    /// point rather than automatic detection.
    private func presentMonkeyBallOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["RM2", "SM2"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a Super Monkey Ball Adventure .RM2/.SM2 file."
        if panel.runModal() == .OK, let url = panel.urls.first {
            workspace.openAsMonkeyBall(url: url)
        }
    }
}

private struct StatusBanner: View {
    let text: String
    let isError: Bool
    var dismiss: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
            Text(text)
                .lineLimit(2)
            Spacer()
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(isError ? .red : .primary)
        .padding()
    }
}

private struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                .padding(24)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 40))
                Text("Drop .BH/.BD, .RM2/.SM2, or a folder")
                    .font(.headline)
            }
        }
        .allowsHitTesting(false)
    }
}
