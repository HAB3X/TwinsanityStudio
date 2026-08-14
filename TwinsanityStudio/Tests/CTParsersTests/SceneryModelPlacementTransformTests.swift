import XCTest
import simd
@testable import CTModels

/// Verifies `SceneryModelPlacement.worldTransform`'s decomposition against
/// hand-built matrices — independent of any GUI/visual check, which this
/// build can't automate. Each matrix is constructed with the *inverse* of
/// the reference tool's own real, working construction (`RMViewer.cs`/
/// `SMViewer.cs` `LoadScenery`: row 0's XYZ negated, rows 0/1/2 become
/// columns 1/2/3, row 3 is translation) from a known rotation/scale/
/// translation, then decoded back — round-tripping through the same
/// formula the fix itself uses, the way `SoundBankWriterTests` round-trips
/// `MBWriter`/`SoundBankParser`.
final class SceneryModelPlacementTransformTests: XCTestCase {
    /// Builds the 4 on-disk rows from a known rotation/scale/translation,
    /// using the inverse of `SceneryModelPlacement.worldTransform`'s
    /// formula.
    private func makeMatrix(rotation: simd_quatf, scale: SIMD3<Float>, translation: SIMD3<Float>) -> [SIMD4<Float>] {
        let basis = simd_float3x3(rotation)
        let col0 = basis.columns.0 * scale.x
        let col1 = basis.columns.1 * scale.y
        let col2 = basis.columns.2 * scale.z
        let row0 = SIMD4<Float>(-col0.x, -col0.y, -col0.z, 0)
        let row1 = SIMD4<Float>(col1.x, col1.y, col1.z, 0)
        let row2 = SIMD4<Float>(col2.x, col2.y, col2.z, 0)
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
