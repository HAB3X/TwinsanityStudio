import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class GraphicsInfoParserTests: XCTestCase {
    /// Builds a minimal but fully valid `GraphicsInfo` record: 2 joints (a
    /// root and one child), no exit points, no model links, matching
    /// `GraphicsInfo.Load`'s exact field order.
    func testParsesJointsAndBuildsSkeletonTree() throws {
        var w = BinaryWriter()
        var header = [UInt8](repeating: 0, count: 16)
        header[0] = 2 // jointCount
        header[1] = 0 // exitPointCount
        header[5] = 0 // modelLinkCount
        header[8] = 0 // collisionDataCount
        w.writeBytes(header)

        // Coord1, Coord2 (bounding volume) — 2 x 16 bytes
        for _ in 0..<8 { w.writeFloat32(0) }

        // Joint 0 (root): reactJointID, jointIndex=0, parentJointIndex=0, childAmt=1, childAmt2=0
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(1); w.writeUInt32(0)
        for _ in 0..<20 { w.writeFloat32(0) } // 5 x Pos (4 floats each)

        // Joint 1 (child of 0): jointIndex=1, parentJointIndex=0, childAmt=0
        w.writeUInt32(0); w.writeUInt32(1); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        for _ in 0..<20 { w.writeFloat32(0) }

        // SkinTransform[jointCount=2]: 4 x Pos each
        for _ in 0..<2 { for _ in 0..<16 { w.writeFloat32(0) } }

        w.writeUInt32(42)  // skinID
        w.writeUInt32(43)  // blendSkinID
        // collisionDataCount == 0: nothing further to write

        var cursor = BinaryCursor(data: w.data)
        let skeleton = try GraphicsInfoParser.parse(&cursor, recordID: 5)

        XCTAssertEqual(skeleton.joints.count, 2)
        XCTAssertEqual(skeleton.skinID, 42)
        XCTAssertEqual(skeleton.blendSkinID, 43)
        XCTAssertEqual(skeleton.skinTransforms.count, 2)

        let tree = try XCTUnwrap(skeleton.buildTree())
        XCTAssertEqual(tree.joint.jointIndex, 0)
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].joint.jointIndex, 1)
    }

    func testZeroJointsProducesEmptySkeletonWithNoTree() throws {
        var w = BinaryWriter()
        w.writeBytes([UInt8](repeating: 0, count: 16)) // all counts zero
        for _ in 0..<8 { w.writeFloat32(0) } // Coord1, Coord2
        w.writeUInt32(0) // skinID
        w.writeUInt32(0) // blendSkinID

        var cursor = BinaryCursor(data: w.data)
        let skeleton = try GraphicsInfoParser.parse(&cursor, recordID: 0)
        XCTAssertTrue(skeleton.joints.isEmpty)
        XCTAssertNil(skeleton.buildTree())
    }
}
