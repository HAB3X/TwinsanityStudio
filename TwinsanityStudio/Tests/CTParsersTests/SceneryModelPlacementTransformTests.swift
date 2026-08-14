import XCTest
import simd
@testable import CTModels

/// Verifies `SceneryModelPlacement.worldTransform`'s decomposition against
/// hand-built matrices — independent of any GUI/visual check, which this
/// build can't automate.
///
/// `makeMatrix` builds the 4 on-disk rows as the algebraic inverse of
/// `worldTransform`'s own (corrected) column formula — real, verified
/// round-trip coverage, but round-tripping through inverse formulas of the
/// *same* relationship can't by itself catch a *systematic* error shared
/// by both directions (this file's own history: an earlier version of
/// both `worldTransform` and this exact helper independently made the
/// same row-vs-column transpose mistake, so encode/decode agreed with
/// each other while both disagreed with the real reference format — every
/// test here passed anyway). `testNinetyDegreeYRotationMatchesHandComputedRawBytes`
/// below exists specifically to close that gap: it builds its input from
/// literal numbers hand-derived directly from the reference tool's own
/// row-vector formula (`RMViewer.cs`/`SMViewer.cs`), with no shared helper
/// and no `simd_quatf`/`simd_float3x3` construction on the input side at
/// all — the one case in this file that couldn't fail the same way twice.
final class SceneryModelPlacementTransformTests: XCTestCase {
    /// Builds the 4 on-disk rows from a known rotation/scale/translation,
    /// using the inverse of `SceneryModelPlacement.worldTransform`'s
    /// (corrected) formula: `worldTransform` computes `col_j` from the
    /// j-th component of `row0`(negated)/`row1`/`row2` — inverting that,
    /// `row0.j = -col_j.x`, `row1.j = col_j.y`, `row2.j = col_j.z`.
    private func makeMatrix(rotation: simd_quatf, scale: SIMD3<Float>, translation: SIMD3<Float>) -> [SIMD4<Float>] {
        let basis = simd_float3x3(rotation)
        let col0 = basis.columns.0 * scale.x
        let col1 = basis.columns.1 * scale.y
        let col2 = basis.columns.2 * scale.z
        let row0 = SIMD4<Float>(-col0.x, -col1.x, -col2.x, 0)
        let row1 = SIMD4<Float>(col0.y, col1.y, col2.y, 0)
        let row2 = SIMD4<Float>(col0.z, col1.z, col2.z, 0)
        let row3 = SIMD4<Float>(translation.x, translation.y, translation.z, 1)
        return [row0, row1, row2, row3]
    }

    private func placement(matrix: [SIMD4<Float>]) -> SceneryModelPlacement {
        SceneryModelPlacement(modelID: 1, isSpecial: false, boundingBoxMin: .zero, boundingBoxMax: .zero, modelMatrix: matrix)
    }

    func testIdentityDecomposesToIdentity() throws {
        let matrix = makeMatrix(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3(1, 1, 1), translation: .zero)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)
        XCTAssertEqual(transform.position, .zero, accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(1, 1, 1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3(1, 0, 0)), SIMD3(1, 0, 0), accuracy: 0.0001)
    }

    func testTranslationOnlyPreservesPosition() throws {
        let expectedPosition = SIMD3<Float>(12.5, -4, 100)
        let matrix = makeMatrix(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: SIMD3(1, 1, 1), translation: expectedPosition)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)
        XCTAssertEqual(transform.position, expectedPosition, accuracy: 0.0001)
    }

    func testNonUniformScaleRecovered() throws {
        let expectedScale = SIMD3<Float>(2, 3, 4)
        let matrix = makeMatrix(rotation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), scale: expectedScale, translation: .zero)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)
        XCTAssertEqual(transform.scale, expectedScale, accuracy: 0.0001)
    }

    /// The direct real-world motivation: a beach tile rotated 90° about Y
    /// must decode to a rotation that actually rotates a forward vector,
    /// not identity. Compared by rotating test vectors rather than
    /// comparing quaternion components directly, since `q` and `-q`
    /// represent the same rotation.
    func testNinetyDegreeYRotationRecovered() throws {
        let expectedRotation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        let matrix = makeMatrix(rotation: expectedRotation, scale: SIMD3(1, 1, 1), translation: .zero)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)

        let probe = SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(transform.rotation.act(probe), expectedRotation.act(probe), accuracy: 0.0001)
        let probe2 = SIMD3<Float>(0, 0, 1)
        XCTAssertEqual(transform.rotation.act(probe2), expectedRotation.act(probe2), accuracy: 0.0001)
    }

    func testCombinedRotationScaleTranslation() throws {
        let expectedRotation = simd_quatf(angle: .pi / 3, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
        let expectedScale = SIMD3<Float>(1.5, 0.75, 2.25)
        let expectedPosition = SIMD3<Float>(-50, 10, 300)
        let matrix = makeMatrix(rotation: expectedRotation, scale: expectedScale, translation: expectedPosition)
        let transform = try XCTUnwrap(placement(matrix: matrix).worldTransform)

        XCTAssertEqual(transform.position, expectedPosition, accuracy: 0.0001)
        XCTAssertEqual(transform.scale, expectedScale, accuracy: 0.0005)
        let probe = SIMD3<Float>(0.4, -0.6, 0.8)
        XCTAssertEqual(transform.rotation.act(probe), expectedRotation.act(probe), accuracy: 0.001)
    }

    /// Fully independent of `makeMatrix` — see this file's own top-level
    /// doc comment for why. A 90° rotation about Y with uniform scale 2
    /// sends local +X to world (0,0,-2), +Y to (0,2,0), +Z to (2,0,0)
    /// (standard right-handed convention, verified by hand, not by
    /// `simd_quatf`). Plugging those three target vectors into the
    /// reference's own row-vector formula (`M11=-R0.X, M12=R1.X, M13=R2.X,
    /// ...`) and solving for `R0`/`R1`/`R2` by hand gives the literal
    /// on-disk row values below — this test's input never touches
    /// `worldTransform`'s own formula or its inverse.
    func testNinetyDegreeYRotationMatchesHandComputedRawBytes() throws {
        // Solved by hand from: col0=(0,0,-2) -> row0.x=0, row1.x=0, row2.x=-2
        //                      col1=(0,2,0)  -> row0.y=0, row1.y=2, row2.y=0
        //                      col2=(2,0,0)  -> row0.z=-2, row1.z=0, row2.z=0
        let row0 = SIMD4<Float>(0, 0, -2, 0)
        let row1 = SIMD4<Float>(0, 2, 0, 0)
        let row2 = SIMD4<Float>(-2, 0, 0, 0)
        let row3 = SIMD4<Float>(5, 6, 7, 1)
        let transform = try XCTUnwrap(placement(matrix: [row0, row1, row2, row3]).worldTransform)

        XCTAssertEqual(transform.position, SIMD3(5, 6, 7), accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(2, 2, 2), accuracy: 0.0001)
        // Local +X must land on world (0,0,-1) (direction only, scale
        // divided out by simd_quatf acting on a unit vector).
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, -1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 1, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 0, 1)), SIMD3<Float>(1, 0, 0), accuracy: 0.0001)
    }

    func testNilWhenMatrixTooShort() {
        let sparse = placement(matrix: [SIMD4<Float>(1, 0, 0, 0)])
        XCTAssertNil(sparse.worldTransform)
    }
}

private func XCTAssertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
}
