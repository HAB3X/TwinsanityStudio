import SwiftUI
import AppKit

@main
struct CTStudioApp: App {
    @StateObject private var workspace = WorkspaceViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Twinsanity Studio") {
            ContentView()
                .environmentObject(workspace)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .ctStudioOpenRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .textEditing) {
                Button("Search Everything…") {
                    NotificationCenter.default.post(name: .ctStudioCommandPaletteRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let ctStudioOpenRequested = Notification.Name("CTStudioOpenRequested")
    static let ctStudioCommandPaletteRequested = Notification.Name("CTStudioCommandPaletteRequested")
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
