import XCTest
import Metal
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
