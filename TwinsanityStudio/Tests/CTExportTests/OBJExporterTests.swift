import XCTest
import CTModels
@testable import CTExport

final class OBJExporterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExportWritesVerticesAndFaces() throws {
        let vertices = [
            StaticVertex(position: SIMD3(0, 0, 0)),
            StaticVertex(position: SIMD3(1, 0, 0)),
            StaticVertex(position: SIMD3(0, 1, 0))
        ]
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [
            MeshSubmesh(vertices: vertices, connectivity: [true, true, true])
        ])

        let url = tempDir.appendingPathComponent("mesh.obj")
        try OBJExporter.export(mesh, to: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("v 0.000000 0.000000 0.000000"))
        XCTAssertTrue(contents.contains("v 1.000000 0.000000 0.000000"))
        XCTAssertTrue(contents.contains("f 1/1/1 2/2/2 3/3/3"))
    }

    func testEmptyMeshThrows() {
        let mesh = MeshAsset(id: 1, isSkinned: false, submeshes: [])
        XCTAssertThrowsError(try OBJExporter.export(mesh, to: tempDir.appendingPathComponent("empty.obj")))
    }

    func testMultipleSubmeshesUseGloballyIncreasingIndices() throws {
        let sub1 = MeshSubmesh(
            vertices: (0..<3).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) },
            connectivity: [true, true, true]
        )
        let sub2 = MeshSubmesh(
            vertices: (0..<3).map { StaticVertex(position: SIMD3(Float($0), 1, 0)) },
            connectivity: [true, true, true]
        )
        let mesh = MeshAsset(id: 2, isSkinned: false, submeshes: [sub1, sub2])
        let url = tempDir.appendingPathComponent("multi.obj")
        try OBJExporter.export(mesh, to: url)
        let contents = try String(contentsOf: url, encoding: .utf8)

        // Second submesh's face indices must be offset past the first submesh's 3 vertices.
        XCTAssertTrue(contents.contains("f 4/4/4 5/5/5 6/6/6"))
    }
}
