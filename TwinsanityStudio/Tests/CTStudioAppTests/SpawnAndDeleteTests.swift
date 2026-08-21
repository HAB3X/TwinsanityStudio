import XCTest
import simd
@testable import CTCore
@testable import CTModels
@testable import CTParsers
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

    // MARK: - AI Path (Level Viewer live session)

    /// `AIPathRecord` has no spatial position of its own (see its own doc
    /// comment) and isn't a `GPULevelObject`, so it can't ride
    /// `spawnTrigger`/`spawnCamera`'s index-based create/select/delete --
    /// this exercises its own separate `addAIPath`/`removeAIPath`/
    /// `restoreAIPath` pair.
    func testAddAIPathAddsARealPendingPath() throws {
        let renderer = try makeRenderer()
        let id = renderer.addAIPath()
        XCTAssertEqual(renderer.newAIPaths.map(\.id), [id])
        XCTAssertEqual(renderer.newAIPaths.first?.args, [0, 1, 0, 0, 0], "default args should be a plausible start/end waypoint pair")
    }

    func testAddAIPathUsesItsOwnIndependentSyntheticIDNamespace() throws {
        let renderer = try makeRenderer()
        let trigger = try XCTUnwrap(renderer.spawnTrigger())
        let pathID = renderer.addAIPath()
        // Trigger IDs and AIPath IDs are independent namespaces -- both
        // legitimately start at 1, so this only checks each is tracked in
        // its own place, not that the numeric values themselves differ.
        XCTAssertNotNil(renderer.newTriggerInfo(at: trigger))
        XCTAssertTrue(renderer.newAIPaths.contains { $0.id == pathID })
    }

    func testDuplicateAIPathAddsASecondPathWithTheSameArgs() throws {
        let renderer = try makeRenderer()
        let original = renderer.addAIPath(args: [2, 5, 9, 0, 1])
        let duplicate = renderer.addAIPath(args: [2, 5, 9, 0, 1])
        XCTAssertNotEqual(original, duplicate, "a duplicate must get its own real, distinct ID")
        XCTAssertEqual(renderer.newAIPaths.count, 2)
        XCTAssertEqual(renderer.newAIPaths.map(\.args), [[2, 5, 9, 0, 1], [2, 5, 9, 0, 1]])
    }

    func testRemoveAIPathDropsASessionAddedPathEntirely() throws {
        let renderer = try makeRenderer()
        let id = renderer.addAIPath()
        renderer.removeAIPath(id: id)
        XCTAssertTrue(renderer.newAIPaths.isEmpty, "a session-added path that's removed again shouldn't be tracked as removed real data -- it just never existed")
        XCTAssertTrue(renderer.pendingRemovedAIPathIDs.isEmpty)
    }

    func testRemoveAIPathMarksARealIDAsRemovedWithoutTouchingNewAIPaths() throws {
        let renderer = try makeRenderer()
        renderer.removeAIPath(id: 42) // a real, on-disk ID this session never added
        XCTAssertEqual(renderer.pendingRemovedAIPathIDs, [42])
        XCTAssertTrue(renderer.newAIPaths.isEmpty)
    }

    func testRestoreAIPathUndoesRemovalOfARealID() throws {
        let renderer = try makeRenderer()
        renderer.removeAIPath(id: 7)
        XCTAssertEqual(renderer.pendingRemovedAIPathIDs, [7])
        renderer.restoreAIPath(id: 7)
        XCTAssertTrue(renderer.pendingRemovedAIPathIDs.isEmpty)
    }

    /// `explicitID` is what keeps undo/redo symmetric (`LevelViewerWindow
    /// .registerAIPathAddUndo`'s redo step re-adds under the *original*
    /// ID rather than minting a new one) -- verified directly here rather
    /// than only through the UI-level undo wiring.
    func testAddAIPathWithExplicitIDReusesThatIDInsteadOfMintingANewOne() throws {
        let renderer = try makeRenderer()
        let firstID = renderer.addAIPath() // consumes the synthetic counter once
        renderer.removeAIPath(id: firstID)
        let redoneID = renderer.addAIPath(args: [1, 2, 3, 4, 5], explicitID: firstID)
        XCTAssertEqual(redoneID, firstID)
        XCTAssertEqual(renderer.newAIPaths.first?.args, [1, 2, 3, 4, 5])
    }

    /// `pendingNewAIPaths`' encoded bytes must be exactly what
    /// `AINavigationParser.parseAIPath` reads back -- the same real
    /// encode/decode round-trip every other pending-record test in this
    /// file checks for Trigger/Camera.
    func testPendingNewAIPathsEncodeAndReparseToTheSameArgs() throws {
        let renderer = try makeRenderer()
        let id = renderer.addAIPath(args: [3, 8, 100, 65535, 0])
        let pending = try XCTUnwrap(renderer.pendingNewAIPaths.first { $0.id == id })
        var cursor = BinaryCursor(data: pending.encoded)
        let reparsed = try AINavigationParser.parseAIPath(&cursor, recordID: id)
        XCTAssertEqual(reparsed.args, [3, 8, 100, 65535, 0])
        XCTAssertEqual(cursor.position, pending.encoded.count, "writeAIPath's 10 bytes must be exactly what parseAIPath consumes, nothing more")
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

    /// "Coordinate-System Overhaul": end-to-end proof that a Trigger/Camera
    /// placed at a given *world* (viewport-displayed) position survives a
    /// real save → re-parse round trip and lands back at that same world
    /// position — not just that `pendingNewTrigger`/`pendingNewCamera`
    /// returns *some* raw bytes. Goes through the exact same
    /// `WorldPlacementWriter`/`WorldPlacementParser` pair a real save uses,
    /// then re-applies the renderer's own display-space mirror
    /// (`ModelViewerRenderer.mirroredWorldPosition`) to the freshly-decoded
    /// raw position, the same conversion `upload(...)` would apply when the
    /// saved file is reopened.
    func testSpawnedTriggerSurvivesSaveReparseRoundTripAtTheSameWorldPosition() throws {
        let renderer = try makeRenderer()
        let worldPosition = SIMD3<Float>(12, -4, 30)
        _ = try XCTUnwrap(renderer.spawnTrigger(at: worldPosition))
        let encoded = try XCTUnwrap(renderer.pendingNewTriggers.first?.encoded)

        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parseTrigger(&cursor, recordID: 999)
        let rawPosition = SIMD3<Float>(decoded.position.x, decoded.position.y, decoded.position.z)
        let redisplayedPosition = ModelViewerRenderer.mirroredWorldPosition(rawPosition)

        XCTAssertLessThan(simd_distance(redisplayedPosition, worldPosition), 0.0001)
    }

    /// "Keyboard nudging" (QoL): arrow-key movement should snap to the same
    /// grid a gizmo drag would, and be a no-op with nothing selected
    /// (matches every other selection-scoped mutator in this renderer).
    func testNudgeSelectedPositionMovesByGridStepAlongTheGivenAxis() throws {
        let renderer = try makeRenderer()
        renderer.gridSize = 2.0
        renderer.snapToGrid = true
        let index = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10, 0, 10)))

        renderer.nudgeSelectedPosition(worldDirection: SIMD3(1, 0, 0))
        XCTAssertEqual(renderer.newTriggerInfo(at: index), SIMD3<Float>(12, 0, 10))

        renderer.nudgeSelectedPosition(worldDirection: SIMD3(0, 1, 0))
        XCTAssertEqual(renderer.newTriggerInfo(at: index), SIMD3<Float>(12, 2, 10))

        renderer.nudgeSelectedPosition(worldDirection: SIMD3(0, 0, -1))
        XCTAssertEqual(renderer.newTriggerInfo(at: index), SIMD3<Float>(12, 2, 8))
    }

    func testNudgeSelectedPositionUsesSmallFixedStepWithSnapOff() throws {
        let renderer = try makeRenderer()
        renderer.snapToGrid = false
        _ = try XCTUnwrap(renderer.spawnTrigger(at: .zero))
        renderer.nudgeSelectedPosition(worldDirection: SIMD3(1, 0, 0))
        let index = try XCTUnwrap(renderer.selectedObjectIndex)
        let position = try XCTUnwrap(renderer.newTriggerInfo(at: index))
        XCTAssertLessThan(simd_distance(position, SIMD3<Float>(0.25, 0, 0)), 0.0001)
    }

    func testNudgeSelectedPositionIsNoOpWithNothingSelected() throws {
        let renderer = try makeRenderer()
        renderer.nudgeSelectedPosition(worldDirection: SIMD3(1, 0, 0)) // must not crash
        XCTAssertNil(renderer.selectedObjectIndex)
    }

    /// "Vertex Magnet-Snapping": dragging a piece close to another
    /// placement's position on the same axis should snap into exact
    /// alignment with it, catching spacing a grid snap alone can't (a
    /// neighbor placed at a non-grid-aligned coordinate).
    func testMagnetSnappedPositionAlignsWithANearbyNeighborOnTheDraggedAxis() throws {
        let renderer = try makeRenderer()
        let neighborIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10.37, 0, 0)))
        let draggedIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))
        XCTAssertNotEqual(neighborIndex, draggedIndex)

        // Close to the neighbor's X (within magnetSnapThreshold) but not
        // exactly on it -- should snap to the neighbor's real X value.
        let candidate = SIMD3<Float>(10.5, 3, 7)
        let snapped = renderer.magnetSnappedPosition(candidate, excluding: draggedIndex, axis: .x)
        XCTAssertEqual(snapped.x, 10.37, accuracy: 0.0001)
        // Only the dragged axis snaps -- Y/Z pass through unchanged.
        XCTAssertEqual(snapped.y, 3, accuracy: 0.0001)
        XCTAssertEqual(snapped.z, 7, accuracy: 0.0001)
    }

    func testMagnetSnappedPositionPassesThroughUnchangedWhenNoNeighborIsClose() throws {
        let renderer = try makeRenderer()
        let neighborIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(100, 0, 0)))
        let draggedIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))
        XCTAssertNotEqual(neighborIndex, draggedIndex)

        let candidate = SIMD3<Float>(5, 0, 0)
        let snapped = renderer.magnetSnappedPosition(candidate, excluding: draggedIndex, axis: .x)
        XCTAssertEqual(snapped, candidate, "far outside magnetSnapThreshold -- should not snap")
    }

    func testMagnetSnappedPositionPicksTheClosestNeighborWhenMultipleAreInRange() throws {
        let renderer = try makeRenderer()
        _ = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10.0, 0, 0)))
        _ = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(10.2, 0, 0)))
        let draggedIndex = try XCTUnwrap(renderer.spawnTrigger(at: SIMD3<Float>(0, 0, 0)))

        let candidate = SIMD3<Float>(10.25, 0, 0)
        let snapped = renderer.magnetSnappedPosition(candidate, excluding: draggedIndex, axis: .x)
        XCTAssertEqual(snapped.x, 10.2, accuracy: 0.0001, "should snap to whichever in-range neighbor is nearest, not just the first one found")
    }

    func testSpawnedCameraSurvivesSaveReparseRoundTripAtTheSameWorldPosition() throws {
        let renderer = try makeRenderer()
        let worldPosition = SIMD3<Float>(-8, 2, 15)
        _ = try XCTUnwrap(renderer.spawnCamera(at: worldPosition))
        let encoded = try XCTUnwrap(renderer.pendingNewCameras.first?.encoded)

        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parseCamera(&cursor, recordID: 999, isDemo: false)
        let rawPosition = SIMD3<Float>(decoded.position.x, decoded.position.y, decoded.position.z)
        let redisplayedPosition = ModelViewerRenderer.mirroredWorldPosition(rawPosition)

        XCTAssertLessThan(simd_distance(redisplayedPosition, worldPosition), 0.0001)
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
