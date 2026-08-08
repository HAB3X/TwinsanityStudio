import XCTest
import CTModels

final class MeshGeometryTests: XCTestCase {
    /// Pins the triangle-strip winding exactly as ported from
    /// `Model.ToPLY` (`Twinsanity/Items/Graphics/Model.cs:339-345`): index
    /// `i`'s connectivity flag gates a triangle `(i±swap, i±swap, i+2)`,
    /// swapping the first two indices on odd `i`.
    func testTriangleIndicesMatchReferenceWindingOrder() {
        let vertices = (0..<5).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) }
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [true, true, true, false, false])
        let triangles = submesh.triangleIndices()

        // i=0 (even): (0, 1, 2). i=1 (odd): swap -> (2, 1, 3). i=2 (even): (2, 3, 4).
        XCTAssertEqual(triangles.count, 3)
        XCTAssertEqual(triangles[0].0, 0); XCTAssertEqual(triangles[0].1, 1); XCTAssertEqual(triangles[0].2, 2)
        XCTAssertEqual(triangles[1].0, 2); XCTAssertEqual(triangles[1].1, 1); XCTAssertEqual(triangles[1].2, 3)
        XCTAssertEqual(triangles[2].0, 2); XCTAssertEqual(triangles[2].1, 3); XCTAssertEqual(triangles[2].2, 4)
    }

    func testDisconnectedVerticesProduceNoTriangles() {
        let vertices = (0..<4).map { StaticVertex(position: SIMD3(Float($0), 0, 0)) }
        let submesh = MeshSubmesh(vertices: vertices, connectivity: [false, false, false, false])
        XCTAssertTrue(submesh.triangleIndices().isEmpty)
    }

    func testFewerThanThreeVerticesProducesNoTriangles() {
        let submesh = MeshSubmesh(vertices: [StaticVertex(position: .zero), StaticVertex(position: .zero)], connectivity: [true, true])
        XCTAssertTrue(submesh.triangleIndices().isEmpty)
    }
}
