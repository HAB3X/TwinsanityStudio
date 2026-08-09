import XCTest
import Combine
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// End-to-end tests of the actual user-facing flow this session's changes
/// target: load an archive, and — without any further manual action — the
/// Models Hub should populate automatically. Skips gracefully when the disc
/// image isn't mounted at the well-known path.
@MainActor
final class WorkspaceViewModelIntegrationTests: XCTestCase {
    func testLoadingArchiveAutoScansAndPopulatesModelsHub() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        // Force a real scan rather than risk a cache hit from a previous
        // test/run in the same process — a cache hit skips straight past
        // the `isScanning` true/false transition and the tree-expansion
        // work this test is actually exercising.
        ScanCache.clearAll()

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        // Loading the index itself is synchronous; scanning is not.
        XCTAssertEqual(workspace.rootNodes.count, 1)
        XCTAssertTrue(workspace.isScanning, "expected the auto-scan to have started immediately on load")

        let expectation = expectation(description: "background scan completes")
        let observation = workspace.$isScanning.dropFirst().sink { scanning in
            if !scanning { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 300)
        observation.cancel()

        XCTAssertFalse(workspace.modelsHub.isEmpty, "Models Hub should be populated automatically after the scan, with no manual Scan Archive click")
        XCTAssertTrue(workspace.modelsHub.contains { $0.isFullyTextured }, "expected at least some models to resolve with textures")

        // Selecting a hub entry should be enough to hand straight to the
        // Model Viewer sheet, with zero further parsing/resolution needed.
        let firstModel = try XCTUnwrap(workspace.modelsHub.first)
        workspace.modelViewerAsset = firstModel
        XCTAssertEqual(workspace.modelViewerAsset?.id, firstModel.id)
    }

    func testOpenModelViewerFromTreeNodeAfterScan() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        // See the matching comment in `testLoadingArchiveAutoScansAndPopulatesModelsHub`.
        ScanCache.clearAll()

        let workspace = WorkspaceViewModel()
        workspace.open(url: bhURL)

        let expectation = expectation(description: "background scan completes")
        let observation = workspace.$isScanning.dropFirst().sink { scanning in
            if !scanning { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 300)
        observation.cancel()

        // Drill down to a real RigidModel node the way the sidebar would,
        // then exercise the same openModelViewer(for:) path the "Open in
        // Model Viewer" button calls.
        guard let archiveRoot = workspace.rootNodes.first,
              let fileEntry = archiveRoot.children.first(where: { $0.displayName == "Levels/AltEarth/Hub/alttunl.rm2" }),
              let graphics = fileEntry.children.first(where: { $0.sectionType == .graphics }),
              let rigidModelSection = graphics.children.first(where: { $0.sectionType == .rigidModel }),
              let rigidModelLeaf = rigidModelSection.children.first
        else {
            return XCTFail("couldn't find the expected RigidModel node after scanning")
        }

        workspace.openModelViewer(for: rigidModelLeaf)
        XCTAssertNotNil(workspace.modelViewerAsset, "openModelViewer should have resolved and set modelViewerAsset; lastError=\(workspace.lastError ?? "nil")")
    }

    /// Regression test for "Fatal Crash on File Selection": opening a
    /// *folder* containing several loose `.RM2` files — one of them
    /// deliberately corrupted — used to run every file's full parse
    /// synchronously on the main actor in a plain `for` loop, with no
    /// async boundary between them. On a large/broad folder pick that's a
    /// long unresponsive freeze indistinguishable from a crash to the
    /// user, even though each individual parse was already safely wrapped
    /// in a `do`/`catch`. This extracts real level files out of the disc
    /// archive into loose files on disk (a real folder-open scenario, not
    /// a synthetic one) plus one genuinely malformed file, and asserts the
    /// whole batch completes, the valid files load, and the corrupted one
    /// is reported through `lastError` rather than crashing the process or
    /// silently vanishing.
    func testOpeningFolderWithLooseLevelFilesHandlesCorruptFileGracefully() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }

        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        let entryNames = ["Levels/AltEarth/Hub/alttunl.rm2", "Levels/Earth/Hub/hubd.rm2", "Levels/Ice/IceClimb/ukafight.rm2"]
        let entries = entryNames.compactMap { name in index.entries.first { $0.name == name } }
        try XCTSkipIf(entries.isEmpty, "None of the expected sample level files were found in this disc image")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FolderOpenTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for entry in entries {
            let data = try BDArchiveParser.readEntryData(entry, index: index)
            let fileName = (entry.name as NSString).lastPathComponent
            try data.write(to: tempDir.appendingPathComponent(fileName))
        }
        // Deliberately malformed: a real .RM2 extension, but not remotely a
        // valid chunk file — this is exactly the "corrupt or truncated
        // archive" case `BinaryCursor`'s own doc comment says must surface
        // as a catchable error, not a crash.
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]).write(to: tempDir.appendingPathComponent("corrupted.rm2"))

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempDir)

        let expectation = expectation(description: "folder load completes")
        let observation = workspace.$isLoading.dropFirst().sink { loading in
            if !loading { expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 60)
        observation.cancel()

        XCTAssertEqual(workspace.rootNodes.count, entries.count, "expected exactly the valid loose files to load, corrupted.rm2 excluded")
        XCTAssertNotNil(workspace.lastError, "the corrupted file's parse failure should have been reported, not silently swallowed")
        XCTAssertTrue(workspace.lastError?.contains("corrupted.rm2") ?? false, "lastError should name the file that failed: \(workspace.lastError ?? "nil")")
    }
}
