import SwiftUI
import AppKit

@main
struct CTStudioApp: App {
    @StateObject private var workspace = WorkspaceViewModel()
    /// Separate from `workspace` deliberately — see `WOCWorkspace`'s doc
    /// comment. `@State`, not `@StateObject`: `WOCWorkspace` is `@Observable`
    /// (a plain reference type SwiftUI tracks by property access, not the
    /// legacy `ObservableObject` protocol `@StateObject` is for), so `@State`
    /// is the correct wrapper to own its lifetime across view updates.
    @State private var wocWorkspace = WOCWorkspace()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Twinsanity Studio") {
            ContentView()
                .environmentObject(workspace)
                .environment(wocWorkspace)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .ctStudioOpenRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                // "Recent Files" (QoL sweep): a real macOS-style Open Recent
                // submenu, rebuilt from `workspace.recentFileURLs` — which
                // stays current since `Menu`'s content closure re-evaluates
                // whenever the `@Published` array it reads changes.
                Menu("Open Recent") {
                    if workspace.recentFileURLs.isEmpty {
                        Text("No Recent Files")
                    } else {
                        ForEach(workspace.recentFileURLs, id: \.path) { url in
                            Button(url.lastPathComponent) {
                                NotificationCenter.default.post(name: .ctStudioOpenRecentRequested, object: url)
                            }
                        }
                        Divider()
                        Button("Clear Menu") { workspace.clearRecentFiles() }
                    }
                }
            }
            CommandGroup(after: .textEditing) {
                Button("Search Everything…") {
                    NotificationCenter.default.post(name: .ctStudioCommandPaletteRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        // Real windows, not sheets, for the three GPU-heavy viewers — see
        // `GPUViewerWindowHosts.swift`'s doc comment for why. `Window`
        // (singular, not `WindowGroup`) gives "one instance, brought
        // forward on repeat `openWindow` calls" semantics, matching what a
        // sheet already did.
        Window("Model Viewer", id: GPUViewerWindowID.model) {
            ModelViewerWindowHost()
                .environmentObject(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("Collision Viewer", id: GPUViewerWindowID.collision) {
            CollisionViewerWindowHost()
                .environmentObject(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("Chunk Viewer", id: GPUViewerWindowID.level) {
            LevelViewerWindowHost()
                .environmentObject(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("WoC Level Viewer", id: WOCViewerWindowID.viewer) {
            WOCViewerWindowHost()
                .environment(wocWorkspace)
                .tint(workspace.accentColorChoice.color)
        }

        // "Tear-Away Workspaces" (roadmap 9.5) — see
        // `TearAwayWindowHosts.swift`'s doc comment.
        Window("Hex Viewer", id: TearAwayWindowID.hexViewer) {
            HexViewerWindowHost()
                .environmentObject(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("Mod Crate Hub", id: TearAwayWindowID.modCrateHub) {
            ModCrateHubWindowHost()
                .environmentObject(workspace)
                .tint(workspace.accentColorChoice.color)
        }

        // "New Settings Window": `Settings { }` is SwiftUI's dedicated
        // macOS Preferences scene — it wires the standard app-menu
        // "Settings…" item and ⌘, automatically, no manual command needed.
        Settings {
            SettingsView()
                .environmentObject(workspace)
                .tint(workspace.accentColorChoice.color)
        }
    }
}

extension Notification.Name {
    static let ctStudioOpenRequested = Notification.Name("CTStudioOpenRequested")
    static let ctStudioCommandPaletteRequested = Notification.Name("CTStudioCommandPaletteRequested")
    /// `object` is the `URL` to reopen — see `CTStudioApp`'s "Open Recent" submenu.
    static let ctStudioOpenRecentRequested = Notification.Name("CTStudioOpenRecentRequested")
}

/// Plain SPM executable targets (as opposed to a proper `.app` bundle
/// launched through Launch Services) don't automatically get window focus
/// stolen from whichever app launched them — including Xcode itself when run
/// via ⌘R. Without this, the window genuinely opens, it just sits behind
/// Xcode until you manually ⌘Tab to it, which reads as "nothing happened."
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
