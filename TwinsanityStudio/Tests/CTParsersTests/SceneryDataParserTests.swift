import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class SceneryDataParserTests: XCTestCase {
    func testNoTreeMarkerLeavesRootNil() throws {
        var w = BinaryWriter()
        w.writeUInt32(0) // headerUnk1 — no skydome/lights flags
        w.writeUInt32(0) // chunk name length
        w.writeUInt32(0) // headerUnk2
        w.writeUInt32(0) // headerUnk3 — not the 0x160A tree marker
        w.writeUInt8(0)  // headerUnk4

        XCTAssertEqual(w.count, 17)

        var cursor = BinaryCursor(data: w.data)
        let scenery = try SceneryDataParser.parse(&cursor, recordID: 1)

        XCTAssertNil(scenery.root)
        XCTAssertTrue(scenery.placements.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// Byte count cross-checked by hand against `SceneryData.GetSize()` +
    /// its `CountScenery`/`CountSceneryModel` helpers
    /// (`Twinsanity/Items/SceneryData.cs`): 17 (header) + 4 (unkVar5) +
    /// 116 (one empty `SceneryGroup`: 4 + 80 unk-vectors + 32 type tags).
    func testMinimalSceneryTreeWithNoPlacements() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0x160A) // headerUnk3 — has a scenery tree
        w.writeUInt8(0)
        w.writeUInt32(99) // unkVar5

        // SceneryModelGroup: header != 0x1613, so no placements, just the
        // always-present 5-vector trailer.
        w.writeUInt32(0)
        for _ in 0..<5 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }

        // 8 child type tags, all "empty" (anything but 0x1600/0x1605).
        for _ in 0..<8 { w.writeInt32(3) }

        XCTAssertEqual(w.count, 17 + 4 + 116)

        var cursor = BinaryCursor(data: w.data)
        let scenery = try SceneryDataParser.parse(&cursor, recordID: 2)

        guard let root = scenery.root else { return XCTFail("Expected a decoded scenery tree") }
        XCTAssertEqual(root.model.header, 0)
        XCTAssertTrue(root.model.placements.isEmpty)
        XCTAssertEqual(root.links.count, 8)
        for link in root.links {
            guard case .empty = link else { return XCTFail("Expected every link to be .empty") }
        }
        XCTAssertTrue(scenery.placements.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testSceneryTreeWithOnePlacementAndOneNestedGroup() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeUInt32(0x160A)
        w.writeUInt8(0)
        w.writeUInt32(0)

        // Root's own model: header == 0x1613, one placement.
        w.writeUInt32(0x1613)
        w.writeUInt16(1) // modelCount
        w.writeUInt16(0) // specialModelCount
        w.writeFloat32(-1); w.writeFloat32(-1); w.writeFloat32(-1); w.writeFloat32(1) // bbox min
        w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1)    // bbox max
        w.writeUInt32(555) // ModelID
        // 4x4 matrix, row 3 (translation) = (10, 20, 30, 1).
        w.writeFloat32(1); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeFloat32(0); w.writeFloat32(1); w.writeFloat32(0); w.writeFloat32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1); w.writeFloat32(0)
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1)
        for _ in 0..<5 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // UnkPos[5]

        // 8 type tags: first is a nested group (0x1600), rest empty.
        w.writeInt32(0x1600)
        for _ in 0..<7 { w.writeInt32(3) }

        // The nested group itself: empty model group + 8 empty tags.
        w.writeUInt32(0)
        for _ in 0..<5 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        for _ in 0..<8 { w.writeInt32(3) }

        var cursor = BinaryCursor(data: w.data)
        let scenery = try SceneryDataParser.parse(&cursor, recordID: 3)

        XCTAssertEqual(scenery.placements.count, 1)
        let placement = scenery.placements[0]
        XCTAssertEqual(placement.modelID, 555)
        XCTAssertFalse(placement.isSpecial)
        XCTAssertEqual(placement.translation, SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(cursor.position, w.count)
    }
}
