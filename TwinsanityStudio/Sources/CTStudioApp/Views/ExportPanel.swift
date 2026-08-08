import AppKit

/// Shared "choose a folder to export into" prompt — every export action
/// (texture PNG, complete-asset bundle, group export) needs the identical
/// folder-picker, so this keeps that one `NSOpenPanel` configuration in one
/// place instead of re-declaring it at each call site.
enum ExportPanel {
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = "Export"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
