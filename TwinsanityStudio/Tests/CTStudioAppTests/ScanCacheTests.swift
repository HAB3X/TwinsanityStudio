import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Round-trips real, fully-decoded models (real vertex data, real decoded
/// texture pixels) from the actual game archive through `ScanCache`'s
/// binary property-list encoding, rather than trusting `Codable` synthesis
/// on faith — the whole point of this cache is serving byte-identical data
/// back out, and a subtle encode/decode mismatch (e.g. losing precision on
/// a float, or truncating a byte array) would be a silent correctness bug,
/// not a crash.
final class ScanCacheTests: XCTestCase {
    func testRoundTripsRealResolvedModelsThroughDisk() throws {
        let bhURL = URL(fileURLWithPath: "/Volumes/CRASH/CRASH6/CRASH.BH")
        guard FileManager.default.fileExists(atPath: bhURL.path) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        let entryName = "Levels/AltEarth/Hub/alttunl.rm2"
        let entry = try XCTUnwrap(index.entries.first { $0.name == entryName })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let fileRoot = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entryName)
        let assetIndex = AssetResolver.buildIndex(fileRoot: fileRoot)

        var models: [ResolvedModelAsset] = []
        for rigidModel in assetIndex.rigidModels.values {
            if let resolved = AssetResolver.resolveRigidModel(rigidModel, displayName: "\(entryName) — Object #\(rigidModel.id)", index: assetIndex) {
                models.append(resolved)
            }
        }
        XCTAssertFalse(models.isEmpty, "precondition: expected at least one resolvable RigidModel")

        let payload = ScanCachePayload(modelsHub: models, orphanedContent: [])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(payload)

        let decoded = try PropertyListDecoder().decode(ScanCachePayload.self, from: encoded)
        XCTAssertEqual(decoded.modelsHub.count, models.count)

        for (original, roundTripped) in zip(models, decoded.modelsHub) {
            XCTAssertEqual(original.recordID, roundTripped.recordID)
            XCTAssertEqual(original.displayName, roundTripped.displayName)
            XCTAssertEqual(original.mesh.submeshes.count, roundTripped.mesh.submeshes.count)
            XCTAssertEqual(original.mesh.totalVertexCount, roundTripped.mesh.totalVertexCount)
            for (originalSubmesh, roundTrippedSubmesh) in zip(original.mesh.submeshes, roundTripped.mesh.submeshes) {
                XCTAssertEqual(originalSubmesh.vertices, roundTrippedSubmesh.vertices, "vertex data must be byte-identical after a cache round-trip")
            }
            XCTAssertEqual(original.submeshMaterials.count, roundTripped.submeshMaterials.count)
            for (originalMaterial, roundTrippedMaterial) in zip(original.submeshMaterials, roundTripped.submeshMaterials) {
                XCTAssertEqual(originalMaterial.materialID, roundTrippedMaterial.materialID)
                XCTAssertEqual(originalMaterial.textureID, roundTrippedMaterial.textureID)
                XCTAssertEqual(originalMaterial.texture?.rgba, roundTrippedMaterial.texture?.rgba, "decoded texture pixels must be byte-identical after a cache round-trip")
                XCTAssertEqual(originalMaterial.texture?.width, roundTrippedMaterial.texture?.width)
                XCTAssertEqual(originalMaterial.texture?.height, roundTrippedMaterial.texture?.height)
            }
        }
    }

    func testSaveAndLoadFromRealDiskLocation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ScanCacheTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeArchive = tempDir.appendingPathComponent("fake.bd")
        try Data("archive content".utf8).write(to: fakeArchive)

        let texture = TextureAsset(id: 1, width: 2, height: 2, pixelFormat: .psmct32, rgba: [UInt8](repeating: 200, count: 16))
        let submesh = MeshSubmesh(vertices: [StaticVertex(position: SIMD3(0, 0, 0))], connectivity: [true])
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [submesh])
        let asset = ResolvedModelAsset(recordID: 1, displayName: "Fake", mesh: mesh, submeshMaterials: [ResolvedSubmeshMaterial(materialID: 1, textureID: 1, texture: texture)])

        XCTAssertNil(ScanCache.load(for: fakeArchive), "no cache should exist yet")
        ScanCache.save(ScanCachePayload(modelsHub: [asset], orphanedContent: []), for: fakeArchive)

        let loaded = try XCTUnwrap(ScanCache.load(for: fakeArchive))
        XCTAssertEqual(loaded.modelsHub.count, 1)
        XCTAssertEqual(loaded.modelsHub.first?.displayName, "Fake")

        // Changing the underlying file's mtime invalidates the cache key —
        // this is the mechanism that keeps a replaced/re-extracted archive
        // from silently serving stale cached models.
        try Data("different content, different size".utf8).write(to: fakeArchive)
        XCTAssertNil(ScanCache.load(for: fakeArchive), "cache should miss once the source file's identity (size/mtime) changes")
    }

    /// Regression for a real, reproduced incident: `MeshSubmesh.jointIndices`/
    /// `jointWeights` (populated only for skinned models) were left on the
    /// naive synthesized `Codable` for `[SIMD4<UInt16>]`/`[SIMD4<Float>]` —
    /// every other per-vertex field here was already flattened into `Data`
    /// (see this type's own doc comment), but these two were missed. At
    /// full-archive-scan scale that produced a real 2.3GB `ScanCache` file
    /// on disk, and loading it back through `PropertyListDecoder` hung the
    /// app for minutes on next launch — not a hypothetical, reproduced
    /// against the real disc image. This pins both correctness (the joint
    /// data round-trips exactly) and the actual regression (encoded size
    /// stays close to the flat byte count, not inflated by generic
    /// per-element container overhead).
    func testSkinnedSubmeshJointDataRoundTripsWithoutCodableBloat() throws {
        let vertexCount = 500
        let vertices = (0..<vertexCount).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) }
        let jointIndices = (0..<vertexCount).map { i -> SIMD4<UInt16> in
            let a = UInt16(i % 4)
            let b = UInt16((i + 1) % 4)
            let c = UInt16((i + 2) % 4)
            let d = UInt16((i + 3) % 4)
            return SIMD4<UInt16>(a, b, c, d)
        }
        let jointWeights = (0..<vertexCount).map { i -> SIMD4<Float> in
            let bump = Float(i) * 0.0001
            return SIMD4<Float>(0.4 + bump, 0.3, 0.2, 0.1)
        }
        let submesh = MeshSubmesh(
            vertices: vertices,
            connectivity: Array(repeating: true, count: vertexCount),
            jointIndices: jointIndices,
            jointWeights: jointWeights
        )
        let mesh = MeshAsset(id: 1, isSkinned: true, submeshes: [submesh])
        let asset = ResolvedModelAsset(recordID: 1, displayName: "Skinned", mesh: mesh, submeshMaterials: [])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(ScanCachePayload(modelsHub: [asset], orphanedContent: []))

        // The theoretical flat payload: 4 x UInt16 + 4 x Float per vertex,
        // plus positions/connectivity/etc. The naive array-of-struct
        // encoding this regresses to inflates well past 10x that — a loose
        // bound (not pinned to an exact byte count, which would be brittle
        // against unrelated plist-format overhead) that would have caught
        // the real bug: it produced roughly a 100x-plus blowup at archive
        // scale.
        let flatJointBytes = vertexCount * (4 * 2 + 4 * 4)
        XCTAssertLessThan(encoded.count, flatJointBytes * 10, "encoded size ballooned — the array-of-struct Codable bloat is back")

        let decoded = try PropertyListDecoder().decode(ScanCachePayload.self, from: encoded)
        let roundTrippedSubmesh = try XCTUnwrap(decoded.modelsHub.first?.mesh.submeshes.first)
        XCTAssertEqual(roundTrippedSubmesh.jointIndices, jointIndices)
        XCTAssertEqual(roundTrippedSubmesh.jointWeights, jointWeights)
    }
}
