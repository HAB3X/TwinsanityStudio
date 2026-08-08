import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class WorldPlacementParserTests: XCTestCase {
    func testParsePosition() throws {
        var w = BinaryWriter()
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3); w.writeFloat32(1)

        var cursor = BinaryCursor(data: w.data)
        let position = try WorldPlacementParser.parsePosition(&cursor, recordID: 5)

        XCTAssertEqual(position.id, 5)
        XCTAssertEqual(position.point, SIMD4<Float>(1, 2, 3, 1))
    }

    /// Empty-lists case should read exactly 90 bytes — matching the
    /// reference tool's `Instance.GetSize()` base constant
    /// (`Twinsanity/Items/Instances/Instance.cs:127`), which was written
    /// independently of the read path and so is a useful cross-check.
    func testParseInstanceEmptyListsConsumesExactly90Bytes() throws {
        var w = BinaryWriter()
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1) // Pos
        w.writeUInt16(1000); w.writeUInt16(11) // RotX, COMRotX
        w.writeUInt16(2000); w.writeUInt16(22) // RotY, COMRotY
        w.writeUInt16(3000); w.writeUInt16(33) // RotZ, COMRotZ
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // InstanceIDs: dup count, count, SomeNum1
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // PositionIDs
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10) // PathIDs
        w.writeUInt16(7)    // ObjectID
        w.writeInt16(-1)    // RefList
        w.writeInt16(-1)    // ScriptID
        w.writeUInt32(0)    // PHeader
        w.writeUInt32(0x6)  // Flags
        w.writeInt32(0); w.writeInt32(0); w.writeInt32(0) // three empty unknown lists

        XCTAssertEqual(w.count, 90)

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 3)

        XCTAssertEqual(instance.position, SIMD4<Float>(10, 20, 30, 1))
        XCTAssertEqual(instance.rotationRaw, SIMD3<UInt16>(1000, 2000, 3000))
        XCTAssertEqual(instance.comRotationRaw, SIMD3<UInt16>(11, 22, 33))
        XCTAssertEqual(instance.objectID, 7)
        XCTAssertEqual(instance.refList, -1)
        XCTAssertEqual(instance.scriptID, -1)
        XCTAssertEqual(instance.flags, 0x6)
        XCTAssertTrue(instance.childInstanceIDs.isEmpty)
        XCTAssertTrue(instance.childPositionIDs.isEmpty)
        XCTAssertTrue(instance.childPathIDs.isEmpty)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testParseInstancePopulatedIDLists() throws {
        var w = BinaryWriter()
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)
        w.writeUInt16(0); w.writeUInt16(0)

        w.writeInt32(2); w.writeInt32(2); w.writeInt32(10)
        w.writeUInt16(101); w.writeUInt16(102)

        w.writeInt32(1); w.writeInt32(1); w.writeInt32(10)
        w.writeUInt16(201)

        w.writeInt32(0); w.writeInt32(0); w.writeInt32(10)

        w.writeUInt16(42)
        w.writeInt16(5)
        w.writeInt16(9)
        w.writeUInt32(0)
        w.writeUInt32(0)
        w.writeInt32(1); w.writeUInt32(0xDEAD_BEEF)
        w.writeInt32(1); w.writeFloat32(1.5)
        w.writeInt32(2); w.writeUInt32(1); w.writeUInt32(2)

        var cursor = BinaryCursor(data: w.data)
        let instance = try WorldPlacementParser.parseInstance(&cursor, recordID: 1)

        XCTAssertEqual(instance.childInstanceIDs, [101, 102])
        XCTAssertEqual(instance.childPositionIDs, [201])
        XCTAssertEqual(instance.childPathIDs, [])
        XCTAssertEqual(instance.objectID, 42)
        XCTAssertEqual(instance.refList, 5)
        XCTAssertEqual(instance.scriptID, 9)
        XCTAssertEqual(instance.unknownUInt32List, [0xDEAD_BEEF])
        XCTAssertEqual(instance.unknownFloatList, [1.5])
        XCTAssertEqual(instance.unknownUInt32List2, [1, 2])
        XCTAssertEqual(cursor.position, w.count)
    }

    /// Zero-instance case should read exactly 80 bytes — matching
    /// `Trigger.GetSize()`'s base constant (`Trigger.cs:270`).
    func testParseTriggerConsumesExactly80BytesWithNoInstances() throws {
        var w = BinaryWriter()
        w.writeUInt32(50)   // Header
        w.writeUInt32(1)    // Enabled
        w.writeFloat32(0.3) // SomeFloat
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // rotation quaternion
        w.writeFloat32(5); w.writeFloat32(6); w.writeFloat32(7); w.writeFloat32(1) // position
        w.writeFloat32(2); w.writeFloat32(2); w.writeFloat32(2); w.writeFloat32(1) // size
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10) // dup count, count, SectionHead
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4) // Arg1..4

        XCTAssertEqual(w.count, 80)

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 9)

        XCTAssertEqual(trigger.header, 50)
        XCTAssertEqual(trigger.enabledMask, 1)
        XCTAssertEqual(trigger.someFloat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(trigger.rotationQuaternion, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(trigger.position, SIMD4<Float>(5, 6, 7, 1))
        XCTAssertEqual(trigger.size, SIMD4<Float>(2, 2, 2, 1))
        XCTAssertTrue(trigger.instanceIDs.isEmpty)
        XCTAssertEqual(trigger.arg1, 1)
        XCTAssertEqual(trigger.arg2, 2)
        XCTAssertEqual(trigger.arg3, 3)
        XCTAssertEqual(trigger.arg4, 4)
        XCTAssertEqual(trigger.rotationAngleDegrees, 0, accuracy: 0.01)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testParseTriggerWithInstances() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)
        w.writeUInt32(0b111)
        w.writeFloat32(0)
        // 180-degree rotation about an arbitrary axis: w == cos(90°) == 0.
        w.writeFloat32(1); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1); w.writeFloat32(1)
        w.writeInt32(3); w.writeInt32(3); w.writeUInt32(10)
        w.writeUInt16(11); w.writeUInt16(22); w.writeUInt16(33)
        w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0); w.writeUInt16(0)

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 2)

        XCTAssertEqual(trigger.instanceIDs, [11, 22, 33])
        XCTAssertEqual(trigger.rotationAngleDegrees, 180, accuracy: 0.01)
        XCTAssertEqual(cursor.position, w.count)
    }
}
