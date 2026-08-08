import XCTest
import Combine
@testable import CTCore
@testable import CTModels
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
}
