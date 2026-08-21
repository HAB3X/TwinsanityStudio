import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CTExport

/// "Direct Boot/Launch" — builds a real, patched copy of a real bootable
/// PS2 disc image and boots it straight in PCSX2. Two entry points share
/// this one view: the toolbar's global "Play in PCSX2…" (`workspace.
/// gameLauncherContext == nil` — boots the disc image exactly as it is)
/// and a Level Viewer's "Quick Launch" (`gameLauncherContext` set to a real
/// plan built from that level's own current pending edits — see
/// `WorkspaceViewModel.GameLauncherContext`'s own doc comment). Every byte
/// this doesn't need to change is copied straight through from the disc
/// image the user points at (`GameLauncher.building`'s own doc comment) —
/// nothing here builds a disc from scratch.
struct GameLauncherView: View {
    @EnvironmentObject private var workspace: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isBuilding = false
    @State private var isSaving = false
    @State private var statusMessage = ""
    @State private var errorMessage: String?
    @State private var isIntegrityFailure = false
    @State private var diagnostics: [String] = []

    private var context: WorkspaceViewModel.GameLauncherContext? { workspace.gameLauncherContext }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(context != nil ? "Quick Launch" : "Play in PCSX2").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            Text("Patches a real, already-bootable PS2 disc image and boots it in PCSX2. Every byte this doesn't need to change is copied straight through from the disc image below. The original file is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                LabeledContent("Disc Image (.iso)") {
                    HStack {
                        Text(workspace.discImageURL?.path ?? "Not chosen")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { chooseDiscImage() }
                    }
                }
                LabeledContent("PCSX2") {
                    HStack {
                        Text(workspace.pcsx2AppURL?.path ?? "Not chosen")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("Choose…") { choosePCSX2() }
                    }
                }
            }
            .formStyle(.grouped)

            if let context {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Boots straight into \(context.startingChunkBaseName)", systemImage: "bolt.fill")
                        .font(.headline)
                    Text(context.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Boots the disc image above exactly as it is. No in-session edits are folded in automatically. To test a specific level's edits, use that level's own \"Quick Launch\" button in the Level Viewer instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: isIntegrityFailure ? "xmark.octagon" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !diagnostics.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Verification log").font(.caption.bold())
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 60, maxHeight: 140)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                Spacer()
                Button(isSaving ? "Saving…" : "Save Rebuilt ISO…") { rebuildAndSave() }
                    .disabled(isBuilding || isSaving || workspace.discImageURL == nil)
                Button(isBuilding ? "Building…" : (context != nil ? "Build & Quick Launch" : "Build & Launch")) { buildAndLaunch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBuilding || isSaving || workspace.discImageURL == nil || workspace.pcsx2AppURL == nil)
            }
        }
        .padding()
        .frame(minWidth: 560)
        .onDisappear { workspace.gameLauncherContext = nil }
    }

    private func chooseDiscImage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let isoType = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [isoType]
        }
        panel.message = "Choose a real, already-bootable PS2 disc image (.iso). A raw .bin/.cue pair isn't supported for launching."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.discImageURL = url
        errorMessage = nil
    }

    private func choosePCSX2() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose PCSX2.app (or its bundled executable inside Contents/MacOS)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.pcsx2AppURL = url
        errorMessage = nil
    }

    private func buildAndLaunch() {
        guard let discImageURL = workspace.discImageURL, let pcsx2AppURL = workspace.pcsx2AppURL else { return }
        let plan = GameLaunchPlan(
            startingChunkBaseName: context?.startingChunkBaseName,
            archiveReplacements: context?.archiveReplacements ?? [:]
        )
        errorMessage = nil
        isIntegrityFailure = false
        diagnostics = []
        isBuilding = true
        statusMessage = "Building…"
        Task.detached(priority: .userInitiated) {
            do {
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioLaunch", isDirectory: true)
                // `GameLauncher.building` only creates `scratch` itself when
                // `plan` actually needs it (a starting-chunk override or
                // archive replacements) — the global "Play in PCSX2" case
                // has neither and returns the image untouched, so this
                // write's own destination folder needs to exist regardless
                // of whether building itself ever touched it.
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let built = try GameLauncher.building(isoURL: discImageURL, plan: plan, scratchDirectory: scratch)
                let outputURL = scratch.appendingPathComponent(plan.startingChunkBaseName != nil ? "quicklaunch.iso" : "launch.iso")
                try built.write(to: outputURL)
                try GameLauncher.launching(pcsx2AppURL: pcsx2AppURL, isoURL: outputURL)
                await MainActor.run {
                    isBuilding = false
                    statusMessage = "Launched PCSX2 with \(outputURL.lastPathComponent)."
                }
            } catch {
                await MainActor.run {
                    isBuilding = false
                    isIntegrityFailure = (error as? GameLauncherError).map { if case .integrityCheckFailed = $0 { return true } else { return false } } ?? false
                    errorMessage = "\(error)"
                }
            }
        }
    }

    /// Rebuilds `plan` on top of the chosen disc image, independently
    /// re-verifies the result (`GameLauncher.rebuildingAndVerifying`), and —
    /// only once that verification actually passes — lets the user pick a
    /// permanent destination for it. Unlike `buildAndLaunch`, this never
    /// touches PCSX2 and never writes into a throwaway scratch directory the
    /// caller doesn't control the lifetime of.
    private func rebuildAndSave() {
        guard let discImageURL = workspace.discImageURL else { return }
        let plan = GameLaunchPlan(
            startingChunkBaseName: context?.startingChunkBaseName,
            archiveReplacements: context?.archiveReplacements ?? [:]
        )
        errorMessage = nil
        isIntegrityFailure = false
        diagnostics = []
        isSaving = true
        statusMessage = "Rebuilding and verifying…"
        Task.detached(priority: .userInitiated) {
            do {
                let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TwinsanityStudioRebuild", isDirectory: true)
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let result = try GameLauncher.rebuildingAndVerifying(isoURL: discImageURL, plan: plan, scratchDirectory: scratch)
                await MainActor.run {
                    diagnostics = result.diagnostics
                }
                let suggestedName = discImageURL.deletingPathExtension().lastPathComponent + "-rebuilt.iso"
                let destination: URL? = await MainActor.run {
                    ExportPanel.chooseSaveLocation(suggestedName: suggestedName, message: "Choose where to save the rebuilt, verified disc image.")
                }
                guard let destination else {
                    await MainActor.run {
                        isSaving = false
                        statusMessage = "Save canceled."
                    }
                    return
                }
                try result.data.write(to: destination)
                await MainActor.run {
                    isSaving = false
                    statusMessage = "Saved verified rebuilt image to \(destination.lastPathComponent)."
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    isIntegrityFailure = (error as? GameLauncherError).map { if case .integrityCheckFailed = $0 { return true } else { return false } } ?? false
                    errorMessage = "\(error)"
                }
            }
        }
    }
}
