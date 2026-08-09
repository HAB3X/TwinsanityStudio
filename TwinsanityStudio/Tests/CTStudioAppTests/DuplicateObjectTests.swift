import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Unrestricted Chunk Free-Edit Mode" — duplication through the real
/// spawn+write-back pipeline, not a purely visual copy.
@MainActor
final class DuplicateObjectTests: XCTestCase {
    private func makeRenderer() throws -> LevelViewerRenderer {
        try XCTUnwrap(LevelViewerRenderer(placements: []))
    }

    func testDuplicatingAFreshlyPlacedActorSpawnsARealSecondInstance() throws {
        let renderer = try makeRenderer()
        guard let originalIndex = renderer.spawnInstance(objectID: 42, at: SIMD3<Float>(5, 0, 5)) else {
            return XCTFail("spawnInstance failed — asset resolution unavailable in this test environment")
        }
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        let countBefore = renderer.objectCount
        guard let duplicateIndex = renderer.duplicateSelectedObject() else {
            return XCTFail("duplicateSelectedObject returned nil for a real, duplicable actor")
        }
        XCTAssertEqual(renderer.objectCount, countBefore + 1)
        XCTAssertNotEqual(duplicateIndex, originalIndex)

        // Real write-back: the duplicate must carry its own real objectID,
        // ready for the exact same insertion pipeline a fresh Forge
        // Palette placement uses.
        let duplicateInfo = try XCTUnwrap(renderer.newInstanceInfo(at: duplicateIndex))
        XCTAssertEqual(duplicateInfo.objectID, 42)
        // Offset, not stacked exactly on top of the original — a
        // duplicate landing pixel-identical to its source would be
        // impossible to tell apart or grab with the gizmo.
        XCTAssertNotEqual(duplicateInfo.worldPosition, SIMD3<Float>(5, 0, 5))
    }

    func testDuplicatingAnAIWaypointPreservesItsRealNodeType() throws {
        let renderer = try makeRenderer()
        guard let originalIndex = renderer.spawnAIWaypoint(at: SIMD3<Float>(1, 2, 3), rawNodeType: 2) else {
            return XCTFail("spawnAIWaypoint failed")
        }
        renderer.select(index: originalIndex)
        XCTAssertTrue(renderer.canDuplicate(at: originalIndex))

        guard let duplicateIndex = renderer.duplicateSelectedObject() else {
            return XCTFail("duplicateSelectedObject returned nil for a real, duplicable AI waypoint")
        }
        let duplicateInfo = try XCTUnwrap(renderer.newAIWaypointInfo(at: duplicateIndex))
        XCTAssertEqual(duplicateInfo.rawNodeType, 2, "the real node type must carry over, not reset to a default")
    }

    func testDuplicateWithNoSelectionIsANoOp() throws {
        let renderer = try makeRenderer()
        XCTAssertNil(renderer.duplicateSelectedObject())
    }
}
