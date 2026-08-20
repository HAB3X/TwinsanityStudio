import XCTest
import simd
@testable import CTStudioApp
@testable import CTParsers

/// `WOCViewerRenderer.applyTransform` -- applies a placed object's real,
/// confirmed row-major transform to a mesh vertex (row-vector multiply,
/// translation in row 3), replacing an earlier version that only ever
/// added translation. These tests verify the math directly against real
/// disc data rather than trusting it in isolation.
final class WOCViewerRendererTests: XCTestCase {
    /// At the local-space origin, applying the transform must reduce to
    /// exactly the instance's own translation -- the two are read from
    /// the same real bytes (`WOCObjectInstance.matrix` rows 12-14 vs.
    /// `worldPosition`), so this is a real consistency check, not just a
    /// unit test of arithmetic in isolation.
    func testOriginMapsToWorldPositionOnRealInstances() throws {
        let path = "/Volumes/CRASH/LEVELS/A/AIRSHIP/AIRSHIP.GSC"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let asset = try WOCLevelLoader.load(gscURL: URL(fileURLWithPath: path), name: "AIRSHIP")
        XCTAssertFalse(asset.objects.isEmpty, "expected real placed objects")

        for object in asset.objects {
            let mapped = WOCViewerRenderer.applyTransform(.zero, object.matrix)
            XCTAssertEqual(mapped.x, object.worldPosition.x, accuracy: 0.001)
            XCTAssertEqual(mapped.y, object.worldPosition.y, accuracy: 0.001)
            XCTAssertEqual(mapped.z, object.worldPosition.z, accuracy: 0.001)
        }
    }

    /// A known matrix (identity + a translation) should behave exactly
    /// like plain vector addition -- pins down the row/column convention
    /// against a hand-computed case, not just self-consistency.
    func testIdentityRotationIsPlainTranslation() {
        let m: WOCObjectInstance.MatrixTuple = (
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            5, 6, 7, 1
        )
        let result = WOCViewerRenderer.applyTransform(SIMD3(1, 2, 3), m)
        XCTAssertEqual(result, SIMD3(6, 8, 10))
    }

    /// A 90-degree rotation about Y (row-major, row-vector convention)
    /// should map the +X axis to -Z (or +Z depending on handedness) --
    /// pins the rotation direction down concretely rather than leaving it
    /// unverified beyond "doesn't crash".
    func testNinetyDegreeYRotationRotatesXAxis() {
        // Row-major rotation about Y by 90 degrees, row-vector convention:
        // row0 = (cos, 0, -sin, 0), row1 = (0,1,0,0), row2 = (sin, 0, cos, 0)
        let m: WOCObjectInstance.MatrixTuple = (
            0, 0, -1, 0,
            0, 1, 0, 0,
            1, 0, 0, 0,
            0, 0, 0, 1
        )
        let result = WOCViewerRenderer.applyTransform(SIMD3(1, 0, 0), m)
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
        XCTAssertEqual(result.z, -1, accuracy: 0.0001)
    }
}
