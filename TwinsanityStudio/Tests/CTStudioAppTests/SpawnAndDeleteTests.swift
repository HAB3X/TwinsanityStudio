import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Add Trigger"/"Add Camera" (closing the parity gap the original
/// editor's `Menu_AddNew` has for these record types) and real delete
/// (closing the parity gap the original editor's `ItemController`'s
/// universal Remove has) — both new this session, both exercised through
/// the same real spawn/remove pipeline the Forge Palette already trusts.
@MainActor
final class SpawnAndDeleteTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    func testSpawnTriggerAddsARealSelectableTrigger() throws {
        let renderer = try makeRenderer()
        let countBefore = renderer.objectCount
        let index = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(3, 0, 4)))
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertEqual(renderer.selectedObjectIndex, index, "spawning should select the new object immediately, matching spawnInstance/spawnAIWaypoint")
        let worldPosition = try XCTUnwrap(renderer.newTriggerInfo(at: index))
        XCTAssertEqual(worldPosition, SIMD3<Float>(3, 0, 4))
    }

    func testSpawnCameraAddsARealSelectableCamera() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(1, 2, 3)))
        XCTAssertEqual(renderer.selectedObjectIndex, index)
        let worldPosition = try XCTUnwrap(renderer.newCameraInfo(at: index))
        XCTAssertEqual(worldPosition, SIMD3<Float>(1, 2, 3))
    }

    func testSpawnTriggerAndCameraUseIndependentSyntheticIDNamespaces() throws {
        // Spawning several of each shouldn't collide with each other or
        // with AI-waypoint/Instance synthetic IDs — each record type keeps
        // its own counter (see nextSyntheticTriggerID/nextSyntheticCameraID's
        // own doc comment).
        let renderer = try makeRenderer()
        let trigger1 = try XCTUnwrap(renderer.spawnTrigger())
        let trigger2 = try XCTUnwrap(renderer.spawnTrigger())
        let camera1 = try XCTUnwrap(renderer.spawnCamera())
        XCTAssertNotEqual(trigger1, trigger2)
        XCTAssertNotNil(renderer.newTriggerInfo(at: trigger1))
        XCTAssertNotNil(renderer.newTriggerInfo(at: trigger2))
        XCTAssertNotNil(renderer.newCameraInfo(at: camera1))
        XCTAssertNil(renderer.newCameraInfo(at: trigger1), "a Trigger object must not also read back as a Camera")
    }

    func testPendingNewTriggersAndCamerasEncodeForSave() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(5, 5, 5)))
        _ = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(6, 6, 6)))
        XCTAssertEqual(renderer.pendingNewTriggers.count, 1)
        XCTAssertEqual(renderer.pendingNewCameras.count, 1)
        // Real, decodable bytes — not placeholder data. Round-trip
        // correctness itself is covered by WorldPlacementParserTests;
        // this just confirms the renderer actually calls through to the
        // real encoder with the live object's current position.
        XCTAssertGreaterThan(renderer.pendingNewTriggers[0].encoded.count, 0)
        XCTAssertGreaterThan(renderer.pendingNewCameras[0].encoded.count, 0)
    }

    func testDeletingASessionPlacedTriggerRemovesItWithoutTrackingForRemoval() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnTrigger())
        XCTAssertTrue(renderer.canDelete(at: index))
        let countBefore = renderer.objectCount
        let snapshot = try XCTUnwrap(renderer.deleteObject(at: index))
        XCTAssertEqual(renderer.objectCount, countBefore - 1)
        // A same-session placement being deleted was never a real on-disk
        // record, so it must not appear in the "remove this real record"
        // list a save would act on.
        XCTAssertTrue(renderer.pendingRemovedTriggerIDs.isEmpty)
        // Undo must bring it back exactly.
        renderer.restoreObject(snapshot, at: index)
        XCTAssertEqual(renderer.objectCount, countBefore)
    }

    func testCanDeleteIsFalseForSceneryAndOutOfRangeIndex() throws {
        let renderer = try makeRenderer()
        XCTAssertFalse(renderer.canDelete(at: 0))
        XCTAssertFalse(renderer.canDelete(at: -1))
        XCTAssertFalse(renderer.canDelete(at: 999))
    }

    func testDeleteWithNoSelectionOrInvalidIndexReturnsNil() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.deleteObject(at: 0))
        _ = try XCTUnwrap(renderer.spawnTrigger())
        XCTAssertNil(renderer.deleteObject(at: 999))
    }

    func testRestoringADeletedObjectReselectsIt() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(9, 9, 9)))
        let snapshot = try XCTUnwrap(renderer.deleteObject(at: index))
        XCTAssertNil(renderer.selectedObjectIndex)
        renderer.restoreObject(snapshot, at: index)
        XCTAssertEqual(renderer.selectedObjectIndex, index)
        XCTAssertEqual(renderer.newCameraInfo(at: index), SIMD3<Float>(9, 9, 9))
    }

    /// "Hover highlight" (Phase 3): a fresh renderer's default orbit looks
    /// straight at `boundsCenter` (world origin here, since there's no
    /// scenery to derive bounds from) — an object spawned there projects
    /// to dead-center of any viewport, giving a deterministic screen point
    /// to drive `hoverObject`/`pickObject` from without needing to expose
    /// the renderer's private view/projection math to the test.
    func testHoverObjectMatchesPickObjectAndProducesADrawableOutline() throws {
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(0, 0, 0)))
        renderer.select(index: nil)
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        XCTAssertEqual(renderer.pickObject(at: center, viewSize: viewSize), index, "hover and click picking must agree on the same object")
        XCTAssertFalse(renderer.hasHoverOutline)
        XCTAssertEqual(renderer.hoverObject(at: center, viewSize: viewSize), index)
        XCTAssertTrue(renderer.hasHoverOutline, "hovering an unselected object should produce a drawable outline")
    }

    func testHoverOutlineClearsWhenTheHoveredObjectBecomesSelected() throws {
        // The gizmo is already a selection indicator — drawing a second
        // outline around the same object would be redundant.
        let renderer = try makeRenderer()
        let index = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(0, 0, 0)))
        renderer.select(index: nil)
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        _ = renderer.hoverObject(at: center, viewSize: viewSize)
        XCTAssertTrue(renderer.hasHoverOutline)
        renderer.select(index: index)
        XCTAssertFalse(renderer.hasHoverOutline)
    }

    func testHoverOutlineClearsWhenCursorMovesAwayFromEveryObject() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnCamera(at: SIMD3<Float>(0, 0, 0)))
        renderer.select(index: nil)
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        XCTAssertNotNil(renderer.hoverObject(at: center, viewSize: viewSize))
        XCTAssertTrue(renderer.hasHoverOutline)
        XCTAssertNil(renderer.hoverObject(at: CGPoint(x: 2, y: 2), viewSize: viewSize), "the far corner shouldn't be within picking range of the origin-projected object")
        XCTAssertFalse(renderer.hasHoverOutline)
    }
}
