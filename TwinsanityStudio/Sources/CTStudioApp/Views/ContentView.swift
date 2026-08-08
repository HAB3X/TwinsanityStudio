import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isTargetedForDrop = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } content: {
            InspectorView(node: workspace.selectedNode)
                .navigationSplitViewColumnWidth(min: 360, ideal: 480)
        } detail: {
            ViewportPanel(node: workspace.selectedNode)
        }
        .navigationTitle("Twinsanity Studio")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    presentOpenPanel()
                } label: {
                    Label("Open…", systemImage: "folder.badge.plus")
                }
                Button {
                    workspace.isModelsHubPresented = true
                } label: {
                    Label("Models Hub", systemImage: "square.grid.3x3.fill")
                }
                .disabled(workspace.modelsHub.isEmpty && !workspace.isScanning)
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
                if workspace.isLoading || workspace.isScanning {
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
        .sheet(item: $workspace.modelViewerAsset) { asset in
            ModelViewerWindow(asset: asset)
                .environmentObject(workspace)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { workspace.modelViewerAsset = nil }
                    }
                }
        }
        .sheet(item: $workspace.collisionViewerMesh) { mesh in
            CollisionViewerWindow(mesh: mesh)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { workspace.collisionViewerMesh = nil }
                    }
                }
        }
        .sheet(item: $workspace.levelViewerContext) { context in
            LevelViewerWindow(context: context)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { workspace.levelViewerContext = nil }
                    }
                }
        }
        .sheet(isPresented: $workspace.isModelsHubPresented) {
            ModelsHubView()
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
        .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
            handleDrop(providers: providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ctStudioOpenRequested)) { _ in
            presentOpenPanel()
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
