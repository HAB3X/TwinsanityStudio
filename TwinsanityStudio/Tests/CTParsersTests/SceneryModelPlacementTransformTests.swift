import XCTest
import simd
@testable import CTModels

/// Verifies `SceneryModelPlacement.worldTransform`'s decomposition against
/// hand-built matrices — independent of any GUI/visual check, which this
/// build can't automate.
///
/// `makeMatrix` builds the 4 on-disk rows as the algebraic inverse of
/// `worldTransform`'s own (corrected) formula — real, verified round-trip
/// coverage, but round-tripping through inverse formulas of the *same*
/// relationship can't by itself catch a *systematic* error shared by both
/// directions (this file's own history: two earlier versions of both
/// `worldTransform` and this exact helper independently made matching
/// mistakes — first a straight row-to-column copy, then a partial
/// transpose that negated the wrong components — so encode/decode agreed
/// with each other while both disagreed with the real reference format;
/// every test here passed anyway both times).
/// `testNinetyDegreeYRotationMatchesHandComputedRawBytes` and
/// `testNinetyDegreeZRotationWithNonUniformScaleMatchesHandComputedRawBytes`
/// below exist specifically to close that gap: both build their input from
/// literal numbers hand-derived directly from the reference tool's own
/// *two-step* construction (`SMViewer.cs`/`RMViewer.cs` `LoadSceneryModel`:
/// the row-vector matrix assembly, *then* the `Matrix4.CreateScale(-1,1,1)`
/// post-multiply the earlier "fixed" version of this file missed entirely),
/// with no shared helper and no `simd_quatf`/`simd_float3x3` construction
/// on the input side at all — the one test shape in this file that
/// couldn't fail the same way twice.
final class SceneryModelPlacementTransformTests: XCTestCase {
    /// Builds the 4 on-disk rows from a known rotation/scale/translation,
    /// using the inverse of `SceneryModelPlacement.worldTransform`'s
    /// (corrected) formula: `worldTransform` computes `col_j` (j=X,Y,Z) as
    /// the plain, unnegated `(row0.j, row1.j, row2.j)`, and position as
    /// `(-row3.x, row3.y, row3.z)`. Inverting: `row0.j = col_j.x`,
    /// `row1.j = col_j.y`, `row2.j = col_j.z`, `row3 = (-translation.x,
    /// translation.y, translation.z)`.
    private func makeMatrix(rotation: simd_quatf, scale: SIMD3<Float>, translation: SIMD3<Float>) -> [SIMD4<Float>] {
        let basis = simd_float3x3(rotation)
        let col0 = basis.columns.0 * scale.x
        let col1 = basis.columns.1 * scale.y
        let col2 = basis.columns.2 * scale.z
        let row0 = SIMD4<Float>(col0.x, col1.x, col2.x, 0)
        let row1 = SIMD4<Float>(col0.y, col1.y, col2.y, 0)
        let row2 = SIMD4<Float>(col0.z, col1.z, col2.z, 0)
        let row3 = SIMD4<Float>(-translation.x, translation.y, translation.z, 1)
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
    /// `simd_quatf`), at world position (5,6,7).
    ///
    /// Solving through the reference tool's *actual two-step* construction
    /// by hand (not the reduced formula `worldTransform` itself uses):
    /// Step 1 builds `M11=-R0.X, M12=R1.X, M13=R2.X, M14=R0.W` (and the
    /// same pattern for rows 2/3, plus `M41=R3.X` for translation). Step 2
    /// (`modelMatrix *= Matrix4.CreateScale(-1,1,1)`) negates only the
    /// matrix's first column (`M11,M21,M31,M41`), which cancels the `-R0.*`
    /// from Step 1 back to `+R0.*` and instead flips `M41` to `-R3.X`. In
    /// the reference's row-vector convention, local +X maps to row 1 of
    /// the FINAL matrix (`M11,M12,M13`) = `(R0.X, R1.X, R2.X)`; local +Y to
    /// row 2 = `(R0.Y, R1.Y, R2.Y)`; local +Z to row 3 = `(R0.Z, R1.Z,
    /// R2.Z)`; translation to row 4 = `(-R3.X, R3.Y, R3.Z)`. Solving each
    /// against the target vectors above:
    ///   col0=(0,0,-2)  -> R0.X=0,  R1.X=0, R2.X=-2
    ///   col1=(0,2,0)   -> R0.Y=0,  R1.Y=2, R2.Y=0
    ///   col2=(2,0,0)   -> R0.Z=2,  R1.Z=0, R2.Z=0
    ///   position=(5,6,7) -> -R3.X=5 (R3.X=-5), R3.Y=6, R3.Z=7
    func testNinetyDegreeYRotationMatchesHandComputedRawBytes() throws {
        let row0 = SIMD4<Float>(0, 0, 2, 0)
        let row1 = SIMD4<Float>(0, 2, 0, 0)
        let row2 = SIMD4<Float>(-2, 0, 0, 0)
        let row3 = SIMD4<Float>(-5, 6, 7, 1)
        let transform = try XCTUnwrap(placement(matrix: [row0, row1, row2, row3]).worldTransform)

        XCTAssertEqual(transform.position, SIMD3(5, 6, 7), accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(2, 2, 2), accuracy: 0.0001)
        // Direction only, scale divided out by simd_quatf acting on a unit vector.
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, -1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 1, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 0, 1)), SIMD3<Float>(1, 0, 0), accuracy: 0.0001)
    }

    /// Second, independent hand-derivation — different axis (Z, not Y) and
    /// non-uniform scale, to catch a bug that only shows up when rotation
    /// and non-uniform scale interact (the first hand-derived test above
    /// uses uniform scale, which can't distinguish a correct per-column
    /// scale recovery from an accidentally-uniform one).
    ///
    /// A 90° rotation about Z with scale (3,1,1) applied in local space
    /// before rotation: local +X (scaled to length 3) rotates to world
    /// (0,3,0); local +Y (length 1) rotates to world (-1,0,0); local +Z
    /// (length 1, unaffected by a Z-axis rotation) stays world (0,0,1).
    /// Translation zero, kept separate from the rotation/scale check above.
    /// Solving through the same two-step process:
    ///   col0=(0,3,0)  -> R0.X=0,  R1.X=3, R2.X=0
    ///   col1=(-1,0,0) -> R0.Y=-1, R1.Y=0, R2.Y=0
    ///   col2=(0,0,1)  -> R0.Z=0,  R1.Z=0, R2.Z=1
    func testNinetyDegreeZRotationWithNonUniformScaleMatchesHandComputedRawBytes() throws {
        let row0 = SIMD4<Float>(0, -1, 0, 0)
        let row1 = SIMD4<Float>(3, 0, 0, 0)
        let row2 = SIMD4<Float>(0, 0, 1, 0)
        let row3 = SIMD4<Float>(0, 0, 0, 1)
        let transform = try XCTUnwrap(placement(matrix: [row0, row1, row2, row3]).worldTransform)

        XCTAssertEqual(transform.position, .zero, accuracy: 0.0001)
        XCTAssertEqual(transform.scale, SIMD3(3, 1, 1), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 1, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(-1, 0, 0), accuracy: 0.0001)
        XCTAssertEqual(transform.rotation.act(SIMD3<Float>(0, 0, 1)), SIMD3<Float>(0, 0, 1), accuracy: 0.0001)
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
