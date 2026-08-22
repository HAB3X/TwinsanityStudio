import SwiftUI
import AppKit

@main
struct CTStudioApp: App {
    @State private var workspace = WorkspaceViewModel()
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
                .environment(workspace)
                .environment(wocWorkspace)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    // "Remember + auto-remount the last mounted disc" and
                    // the quit-time unsaved-Level-Viewer-edits prompt both
                    // need a live `workspace` reference — the disc restore
                    // right here, the prompt via `appDelegate.workspace`
                    // (see `AppDelegate.applicationShouldTerminate`).
                    // `autoRemountLastDiscImageIfAvailable` guards itself
                    // against running more than once per process (see its
                    // own doc comment), so this is safe even if `.onAppear`
                    // ever fires again for a second `WindowGroup` window.
                    appDelegate.workspace = workspace
                    workspace.autoRemountLastDiscImageIfAvailable()
                }
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
                .environment(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("Collision Viewer", id: GPUViewerWindowID.collision) {
            CollisionViewerWindowHost()
                .environment(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("Chunk Viewer", id: GPUViewerWindowID.level) {
            LevelViewerWindowHost()
                .environment(workspace)
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
                .environment(workspace)
                .tint(workspace.accentColorChoice.color)
        }
        Window("Mod Crate Hub", id: TearAwayWindowID.modCrateHub) {
            ModCrateHubWindowHost()
                .environment(workspace)
                .tint(workspace.accentColorChoice.color)
        }

        // "New Settings Window": `Settings { }` is SwiftUI's dedicated
        // macOS Preferences scene — it wires the standard app-menu
        // "Settings…" item and ⌘, automatically, no manual command needed.
        Settings {
            SettingsView()
                .environment(workspace)
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
    /// Set by `CTStudioApp`'s own `.onAppear` right after both exist — a
    /// plain back-reference for `applicationShouldTerminate` below, never
    /// ownership (`workspace` is owned by the `App` struct's `@State`).
    weak var workspace: WorkspaceViewModel?
    /// Set once the quit sequence below has genuinely finished (saved,
    /// explicitly discarded, or decided there's nothing to save) so the
    /// termination this triggers doesn't loop back into the same prompt a
    /// second time.
    private var readyToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// "Prompt before losing unsaved Level Viewer edits" — a real, honest,
    /// but deliberately *narrow* safety net: it only ever asks about
    /// `WorkspaceViewModel.hasPendingLevelViewerEdits`, itself scoped to
    /// exactly one source of pending edits in this whole app
    /// (`LevelViewerRenderer`'s pending position/rotation/instance/waypoint
    /// state — see that property's own doc comment for the full list of
    /// *other* editors this deliberately does not also cover). Standard
    /// macOS three-way unsaved-changes alert, `.terminateLater` while the
    /// actual save — independently re-verified before it ever overwrites
    /// the real mounted disc image — runs asynchronously.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !readyToTerminate, let workspace, workspace.hasPendingLevelViewerEdits else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "You have unsaved Level Viewer changes"
        alert.informativeText = "This session has pending position/rotation/instance/waypoint edits in the Level Viewer that haven't been saved back into the mounted disc image"
            + (workspace.discImageURL.map { " (\($0.lastPathComponent))" } ?? "")
            + ". Quitting now will lose them."
        alert.addButton(withTitle: "Save & Quit")
        alert.addButton(withTitle: "Discard & Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor [weak self] in
                await self?.saveAndTerminate(workspace: workspace)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Runs the real save (`WorkspaceViewModel.savingPendingLevelViewerEditsToMountedDisc`,
    /// which independently re-verifies the rebuilt image before ever
    /// overwriting the real mounted `.iso` — same discipline as
    /// `GameLauncher.rebuildingAndVerifying`) and resolves the `.terminateLater`
    /// from `applicationShouldTerminate` above once it's genuinely done.
    /// Never silently corrupts the disc image (a failed verification leaves
    /// it untouched) and never silently blocks quitting forever (every
    /// failure branch still offers a real way to finish quitting).
    @MainActor
    private func saveAndTerminate(workspace: WorkspaceViewModel) async {
        let outcome = await workspace.savingPendingLevelViewerEditsToMountedDisc()
        switch outcome {
        case .noPendingEdits, .saved:
            readyToTerminate = true
            NSApp.reply(toApplicationShouldTerminate: true)

        case .noDiscImageConfigured:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "No disc image chosen"
            alert.informativeText = "There's no disc image configured to save into (the Game Launcher's \"Disc Image\" field). Quit without saving to lose these edits, or cancel and set one first."
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                readyToTerminate = true
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.reply(toApplicationShouldTerminate: false)
            }

        case .verificationFailed(let reason):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Couldn't verify the rebuilt disc image"
            alert.informativeText = "The patched image failed its own independent re-verification, so nothing was written to your real disc image: \(reason)"
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                await saveAndTerminate(workspace: workspace)
            case .alertSecondButtonReturn:
                readyToTerminate = true
                NSApp.reply(toApplicationShouldTerminate: true)
            default:
                NSApp.reply(toApplicationShouldTerminate: false)
            }

        case .writeFailed(let verifiedData, _, let reason):
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Verified, but couldn't write back to the disc image"
            alert.informativeText = "The rebuilt image passed its own independent re-verification, but writing it back into the mounted disc image failed: \(reason). You can save the verified result to a different file instead, and copy it back into place yourself."
            alert.addButton(withTitle: "Save Copy Elsewhere…")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let destination = ExportPanel.chooseSaveLocation(suggestedName: "rebuilt.iso", message: "Choose where to save the verified, rebuilt disc image.") {
                    do {
                        try verifiedData.write(to: destination)
                        readyToTerminate = true
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } catch {
                        // Couldn't even write the fallback copy — don't loop
                        // forever; let the user decide what to do next from
                        // a normal, un-terminated app instead.
                        NSApp.reply(toApplicationShouldTerminate: false)
                    }
                } else {
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            case .alertSecondButtonReturn:
                readyToTerminate = true
                NSApp.reply(toApplicationShouldTerminate: true)
            default:
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }
}
