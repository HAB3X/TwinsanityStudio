import SwiftUI

@main
struct CTStudioApp: App {
    @StateObject private var workspace = WorkspaceViewModel()

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
        }
    }
}

extension Notification.Name {
    static let ctStudioOpenRequested = Notification.Name("CTStudioOpenRequested")
}
