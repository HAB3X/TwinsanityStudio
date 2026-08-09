import XCTest
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

final class ModelViewerRendererTests: XCTestCase {
    private func makeTestAsset() -> ResolvedModelAsset {
        let vertices = [
            StaticVertex(position: SIMD3(0, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0)),
            StaticVertex(position: SIMD3(1, 0, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            StaticVertex(position: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1))
        ]
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true], materialID: 1)
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        let material = ResolvedSubmeshMaterial(materialID: 1, textureID: 1, texture: texture)
        return ResolvedModelAsset(recordID: 1, displayName: "Test Triangle", mesh: mesh, submeshMaterials: [material])
    }

    /// The most important regression test in this file: if the embedded MSL
    /// shader source fails to compile at runtime (typo, unsupported
    /// feature), `ModelViewerRenderer.init` returns `nil` — which is exactly
    /// what a user sees as "the Model Viewer shows a blank screen," with no
    /// error surfaced anywhere. This pins that the pipeline actually builds.
    func testRendererInitializesAndCompilesShaderSuccessfully() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = ModelViewerRenderer(asset: asset)
        XCTAssertNotNil(renderer, "ModelViewerRenderer failed to initialize — likely a shader compile error swallowed by the init? guard chain")
    }

    /// The Euler-degrees<->quaternion conversion behind the Level Viewer's
    /// rotate gizmo and rotation nudge fields (`LevelViewerRenderer.
    /// setSelectedRotation`/`selectedRotationDegrees`) is new, non-trivial
    /// math (XYZ Euler decomposition from a rotation matrix) with a real
    /// failure mode — a wrong axis order or sign flip wouldn't crash, it'd
    /// just silently show the wrong angle in the UI. Round-tripping through
    /// the actual renderer (not a standalone math check) exercises the
    /// exact path the UI uses.
    func testRotationRoundTripsThroughEulerDegrees() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), asset)]))
        renderer.select(index: 0)

        // Deliberately away from 90°-multiple angles, where gimbal lock
        // makes the decomposition genuinely ambiguous (multiple valid
        // Euler triples for the same rotation) rather than just "a hard
        // case this implementation gets slightly wrong."
        let input = SIMD3<Float>(30, 45, 60)
        renderer.setSelectedRotation(eulerDegrees: input)
        let output = try XCTUnwrap(renderer.selectedRotationDegrees)

        XCTAssertEqual(output.x, input.x, accuracy: 0.01)
        XCTAssertEqual(output.y, input.y, accuracy: 0.01)
        XCTAssertEqual(output.z, input.z, accuracy: 0.01)
    }

    func testScaleClampsAwayFromZeroAndNegative() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), asset)]))
        renderer.select(index: 0)

        // A zero/negative scale collapses or flips the mesh in a way
        // that's visually indistinguishable from "nothing renders" — the
        // exact class of bug the blank-viewport investigation spent a long
        // time chasing down elsewhere in this renderer, so this is a real
        // regression to guard, not a hypothetical one.
        renderer.setSelectedScale(to: SIMD3(-5, 0, 2))
        let scale = try XCTUnwrap(renderer.selectedScale)
        XCTAssertGreaterThan(scale.x, 0)
        XCTAssertGreaterThan(scale.y, 0)
        XCTAssertEqual(scale.z, 2, accuracy: 0.01)
    }

    func testRendererHandlesEmptyMeshWithoutCrashing() {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [])
        let asset = ResolvedModelAsset(recordID: 1, displayName: "Empty", mesh: mesh, submeshMaterials: [])
        let renderer = ModelViewerRenderer(asset: asset)
        XCTAssertNotNil(renderer)
    }

    /// Renders a *real* resolved model from the actual game archive to an
    /// offscreen texture, so the Metal pipeline's actual pixel output is
    /// verified directly rather than inferred from code review. Skips
    /// gracefully (not a failure) when the disc image isn't mounted at the
    /// well-known path — useful locally, inert in any other environment.
    func testRenderRealModelToOffscreenSnapshot() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }

        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let entryName = "Levels/AltEarth/Hub/alttunl.rm2"
        let entry = try XCTUnwrap(index.entries.first { $0.name == entryName })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let fileRoot = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entryName)
        let assetIndex = AssetResolver.buildIndex(fileRoot: fileRoot)
        let rigidModel = try XCTUnwrap(assetIndex.rigidModels[2_623_336_433])
        let resolved = try XCTUnwrap(AssetResolver.resolveRigidModel(rigidModel, displayName: "alttunl rigidModel", index: assetIndex))

        XCTAssertGreaterThan(resolved.mesh.totalVertexCount, 0, "precondition: real mesh should have vertices")
        XCTAssertTrue(resolved.isFullyTextured, "precondition: this specific rigidModel is known to fully resolve textures")

        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: resolved))
        XCTAssertTrue(renderer.hasGeometry, "renderer uploaded zero submeshes despite a non-empty resolved mesh")
        XCTAssertEqual(renderer.submeshCount, resolved.mesh.submeshes.count)

        guard let image = renderer.renderOffscreen(width: 512, height: 512) else {
            return XCTFail("renderOffscreen returned nil")
        }

        // Fail loudly (not just "looks blank") if the frame is a single flat
        // color — that's exactly the "nothing shows up" symptom, distinct
        // from "not blank but wrong."
        let uniqueColorCount = Self.countApproxUniqueColors(image)
        print("DIAG: rendered frame has ~\(uniqueColorCount) distinct sampled colors")
        XCTAssertGreaterThan(uniqueColorCount, 1, "rendered frame appears to be a single flat color — nothing is actually being drawn")

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("model_viewer_snapshot.png")
        if let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print("DIAG: wrote snapshot to \(outputURL.path)")
        }
    }

    /// Same formula as `ModelViewerRenderer.perspectiveMatrix` (`fileprivate`,
    /// so not directly callable from this test target) — duplicated here
    /// deliberately rather than widening that access, since what's under
    /// test is `Frustum`'s own plane-extraction math, not this helper.
    private func testPerspectiveMatrix(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        )
    }

    /// `Frustum` (Part 1, "Seamless Full-Map Rendering") is the new lever
    /// for skipping draw calls on a massive level — a wrong plane (e.g. an
    /// OpenGL-convention near plane under Metal's `[0,1]` NDC z, which
    /// would put it in the wrong place entirely) wouldn't crash, it'd just
    /// silently pop objects in/out of view, exactly the "dropped frames /
    /// broken rendering" failure this feature exists to prevent. A
    /// symmetric 90°-vertical-FOV, aspect-1, near=1/far=100 projection with
    /// an identity view (camera at the world origin looking down -Z) makes
    /// the frustum's shape easy to reason about by hand: at view-space
    /// depth 10, the half-extent in both X and Y is `10 * tan(45°) == 10`.
    func testFrustumCullsPointsOutsideEachPlane() {
        let viewProjection = testPerspectiveMatrix(fovYRadians: .pi / 2, aspect: 1, near: 1, far: 100)
        let frustum = ModelViewerRenderer.Frustum(viewProjection: viewProjection)

        XCTAssertTrue(frustum.intersects(center: SIMD3(0, 0, -10), radius: 1), "center of the view cone must be visible")
        XCTAssertFalse(frustum.intersects(center: SIMD3(50, 0, -10), radius: 1), "far outside the left/right planes must be culled")
        XCTAssertFalse(frustum.intersects(center: SIMD3(0, 50, -10), radius: 1), "far outside the top/bottom planes must be culled")
        XCTAssertFalse(frustum.intersects(center: SIMD3(0, 0, 10), radius: 1), "behind the camera (past the near plane) must be culled")
        XCTAssertFalse(frustum.intersects(center: SIMD3(0, 0, -150), radius: 1), "past the far plane must be culled")
        XCTAssertTrue(frustum.intersects(center: SIMD3(50, 0, -10), radius: 100), "a sphere large enough to bridge back into view must not be culled")
    }

    // MARK: - Collision Mask Alignment

    /// `collisionBoxEdges` must span the real axis-aligned extent of the
    /// input points regardless of their order — 12 edges, min/max on every
    /// axis actually reached.
    func testCollisionBoxEdgesSpansRealExtent() {
        let corners: [SIMD4<Float>] = [
            SIMD4(-1, -2, -3, 1), SIMD4(1, -2, -3, 1), SIMD4(1, 2, -3, 1), SIMD4(-1, 2, -3, 1),
            SIMD4(-1, -2, 3, 1), SIMD4(1, -2, 3, 1), SIMD4(1, 2, 3, 1), SIMD4(-1, 2, 3, 1)
        ]
        let edges = ModelViewerRenderer.collisionBoxEdges(corners: corners)
        XCTAssertEqual(edges.count, 12)
        let allPoints = edges.flatMap { [$0.0, $0.1] }
        XCTAssertEqual(allPoints.map(\.x).min(), -1)
        XCTAssertEqual(allPoints.map(\.x).max(), 1)
        XCTAssertEqual(allPoints.map(\.y).min(), -2)
        XCTAssertEqual(allPoints.map(\.y).max(), 2)
        XCTAssertEqual(allPoints.map(\.z).min(), -3)
        XCTAssertEqual(allPoints.map(\.z).max(), 3)
    }

    func testCollisionBoxEdgesEmptyForNoCorners() {
        XCTAssertTrue(ModelViewerRenderer.collisionBoxEdges(corners: []).isEmpty)
    }

    // MARK: - The Forge Palette (Part 4C)

    /// `spawnInstance` is the backend half of "select an entity, click into
    /// the map, spawn a brand-new instance" — this pins that it actually
    /// adds a selectable object and records enough to reconstruct a real
    /// `Instance` record from later (`pendingNewInstances`).
    func testSpawnInstanceAddsSelectableObjectWithPendingRecord() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), asset)]))
        let before = renderer.objectCount

        let newIndex = try XCTUnwrap(renderer.spawnInstance(objectID: 42, at: SIMD3<Float>(5, 1, -3)))

        XCTAssertEqual(renderer.objectCount, before + 1)
        XCTAssertEqual(renderer.selectedObjectIndex, newIndex)
        let pending = renderer.pendingNewInstances
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].objectID, 42)
        XCTAssertEqual(pending[0].position, SIMD3<Float>(5, 1, -3))
    }

    /// The undo-reachable half: removing a just-placed object must both
    /// shrink the scene and drop it from `pendingNewInstances` — otherwise
    /// "Save" would write a record for something that's no longer even in
    /// the viewport.
    func testRemoveObjectClearsSelectionAndPendingRecord() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), asset)]))
        let before = renderer.objectCount
        let index = try XCTUnwrap(renderer.spawnInstance(objectID: 7, at: .zero))

        renderer.removeObject(at: index)

        XCTAssertEqual(renderer.objectCount, before)
        XCTAssertNil(renderer.selectedObjectIndex)
        XCTAssertTrue(renderer.pendingNewInstances.isEmpty)
    }

    /// A screen-center click's ray passes exactly through the orbit
    /// target (that's what "orbit target" means for a look-at camera) — so
    /// with a single placement at the world origin (making both the
    /// orbit target *and* the ground plane sit at `(0, 0, 0)`), a
    /// center-screen click must resolve to exactly the origin. This is the
    /// simplification `worldPositionOnGroundPlane`'s own doc comment
    /// describes (a plane intersection, not a real terrain raycast) —
    /// verified numerically rather than trusted by inspection, since a
    /// sign error in the unprojection would silently place every object at
    /// the wrong depth.
    func testWorldPositionOnGroundPlaneHitsOrbitTargetAtScreenCenter() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available in this environment")
        }
        let asset = makeTestAsset()
        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [(SIMD3<Float>(0, 0, 0), asset)]))
        let viewSize = CGSize(width: 800, height: 600)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)

        let hit = try XCTUnwrap(renderer.worldPositionOnGroundPlane(at: center, viewSize: viewSize, planeY: 0))

        XCTAssertEqual(hit.x, 0, accuracy: 0.01)
        XCTAssertEqual(hit.y, 0, accuracy: 0.01)
        XCTAssertEqual(hit.z, 0, accuracy: 0.01)
    }

    /// Samples a grid of pixels and counts roughly-distinct colors — cheap
    /// proxy for "did anything actually render" without needing exact pixel
    /// matching.
    private static func countApproxUniqueColors(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytesPerPixel = 4
        let bytesPerRow = image.bytesPerRow
        var seen = Set<UInt32>()
        let step = 8
        var y = 0
        while y < image.height {
            var x = 0
            while x < image.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 3 < data.count else { x += step; continue }
                let r = UInt32(data[offset]), g = UInt32(data[offset + 1]), b = UInt32(data[offset + 2])
                // Bucket to tolerate small lighting gradients while still catching "truly flat."
                let bucket = ((r / 16) << 8) | ((g / 16) << 4) | (b / 16)
                seen.insert(bucket)
                x += step
            }
            y += step
        }
        return seen.count
    }
}
