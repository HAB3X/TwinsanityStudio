import XCTest
import simd
@testable import CTModels
@testable import CTStudioApp

/// "Forge Palette placeholder cube" investigation: spawning already went
/// through the real resolver chain — the actual gap was that the palette
/// lists every object ID in the whole game with no way to tell, before
/// placing one, whether the *currently open level's* own data (plus the
/// shared Default.rm2 fallback) has geometry for it. `canResolveObjectID`
/// exposes that check to the UI without touching the GPU.
final class ForgePaletteResolutionTests: XCTestCase {
    private func makeMesh(id: UInt32) -> MeshAsset {
        let submesh = MeshSubmesh(
            vertices: [StaticVertex(position: .zero), StaticVertex(position: .zero), StaticVertex(position: .zero)],
            connectivity: [true, true, true],
            materialID: nil
        )
        return MeshAsset(id: id, isSkinned: false, submeshes: [submesh])
    }

    func testResolvableObjectIDReportsTrue() throws {
        var index = GraphicsAssetIndex()
        index.gameObjects[3] = GameObjectInfo(id: 3, name: "BASICCRATE", ogiIDs: [500])
        index.skeletons[500] = SkeletonAsset(id: 500, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 12)])
        index.models[40] = makeMesh(id: 40)
        index.rigidModels[12] = RigidModelInfo(id: 12, header: 257, materialIDs: [], meshID: 40)

        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], assetIndex: index))
        XCTAssertTrue(renderer.canResolveObjectID(3), "a GameObject with a real OGI->RigidModel->Model chain should resolve")
    }

    /// The exact real-world case this fix targets: an object ID that's a
    /// real, named entry in `DefaultObjectID.names` but has no `GameObject`
    /// record at all in the currently open level's own data (e.g. an
    /// enemy that only appears in a different level) — must report false,
    /// not silently succeed via a stale/optimistic default.
    func testUnresolvableObjectIDReportsFalse() throws {
        var index = GraphicsAssetIndex()
        index.gameObjects[3] = GameObjectInfo(id: 3, name: "BASICCRATE", ogiIDs: [500])
        index.skeletons[500] = SkeletonAsset(id: 500, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 12)])
        index.models[40] = makeMesh(id: 40)
        index.rigidModels[12] = RigidModelInfo(id: 12, header: 257, materialIDs: [], meshID: 40)

        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], assetIndex: index))
        XCTAssertFalse(renderer.canResolveObjectID(9999), "an object ID with no GameObject entry in this level's index must not resolve")
    }

    /// The shared `Default.rm2` fallback still counts as resolvable — a
    /// commonly-used object doesn't need its own per-level GameObject
    /// entry to place correctly.
    func testObjectIDResolvableOnlyThroughDefaultFallbackReportsTrue() throws {
        var defaultIndex = GraphicsAssetIndex()
        defaultIndex.gameObjects[7] = GameObjectInfo(id: 7, name: "WUMPAFRUIT", ogiIDs: [900])
        defaultIndex.skeletons[900] = SkeletonAsset(id: 900, joints: [], exitPoints: [], skinTransforms: [], skinID: 0, blendSkinID: 0, modelLinks: [ModelLink(jointIndex: 0, modelID: 77)])
        defaultIndex.models[80] = makeMesh(id: 80)
        defaultIndex.rigidModels[77] = RigidModelInfo(id: 77, header: 257, materialIDs: [], meshID: 80)

        let renderer = try XCTUnwrap(LevelViewerRenderer(placements: [], assetIndex: GraphicsAssetIndex(), defaultAssetIndex: defaultIndex))
        XCTAssertTrue(renderer.canResolveObjectID(7), "an object absent from this level's own index but present in the Default.rm2 fallback should still resolve")
    }
}
