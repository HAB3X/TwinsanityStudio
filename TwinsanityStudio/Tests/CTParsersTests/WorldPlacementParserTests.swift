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

    /// The "Editing GUI" write path's core correctness guarantee: encoding
    /// a decoded (and possibly edited) `PositionMarker` must produce
    /// exactly the same 16-byte shape the parser reads, so patching it back
    /// into a copy of the original file at the record's known offset never
    /// shifts anything after it.
    func testPositionRoundTripsThroughWriter() throws {
        let original = PositionMarker(id: 9, point: SIMD4<Float>(1.5, -2.25, 3.75, 1))
        let encoded = WorldPlacementWriter.writePosition(original)

        XCTAssertEqual(encoded.count, 16)

        var cursor = BinaryCursor(data: encoded)
        let decoded = try WorldPlacementParser.parsePosition(&cursor, recordID: original.id)

        XCTAssertEqual(decoded.point, original.point)
        XCTAssertEqual(cursor.position, 16)
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

    /// "Make Trigger/Camera inspectors writable": `writeTriggerOrCameraPrefix`'s
    /// output, followed by whatever `parseTrigger` expects next (the
    /// variable-length tail), must parse back out to exactly the edited
    /// header/enabledMask/someFloat/rotation/position/size — proving the
    /// prefix writer's field order/widths genuinely match the parser's,
    /// not just "looks right by inspection."
    func testTriggerPrefixRoundTripsThroughWriter() throws {
        let encodedPrefix = WorldPlacementWriter.writeTriggerOrCameraPrefix(
            header: 42,
            enabledMask: 0b101,
            someFloat: 1.25,
            rotationQuaternion: SIMD4<Float>(0, 0.7071, 0, 0.7071),
            position: SIMD4<Float>(10, -20, 30, 1),
            size: SIMD4<Float>(2, 3, 4, 1)
        )
        XCTAssertEqual(encodedPrefix.count, 60)

        var w = BinaryWriter()
        w.writeBytes(encodedPrefix)
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10) // empty instanceIDs list
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4) // Arg1..4

        var cursor = BinaryCursor(data: w.data)
        let trigger = try WorldPlacementParser.parseTrigger(&cursor, recordID: 1)

        XCTAssertEqual(trigger.header, 42)
        XCTAssertEqual(trigger.enabledMask, 0b101)
        XCTAssertEqual(trigger.someFloat, 1.25, accuracy: 0.0001)
        XCTAssertEqual(trigger.rotationQuaternion, SIMD4<Float>(0, 0.7071, 0, 0.7071))
        XCTAssertEqual(trigger.position, SIMD4<Float>(10, -20, 30, 1))
        XCTAssertEqual(trigger.size, SIMD4<Float>(2, 3, 4, 1))
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

    /// Empty-instances, non-Demo, both slots `.none` (3) case should read
    /// exactly 187 bytes — independently cross-checked by hand against
    /// `Camera.GetSize()`'s formula (`Camera.cs:723-803`), which the
    /// reference tool's *write* path derives with no relation to how this
    /// read path was transcribed.
    func testParseCameraNoneSlotsConsumesExactly187BytesNonDemo() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)   // Header
        w.writeUInt32(1)   // Enabled
        w.writeFloat32(0.3) // SomeFloat
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) } // Coords
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10) // dup count, count, SectionHead
        w.writeUInt32(0xCAFE) // CamHeader
        w.writeUInt16(7)      // UnkShort (non-Demo)
        w.writeFloat32(1)     // UnkFloat1
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // UnkCoords1
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) // UnkCoords2
        w.writeFloat32(0); w.writeFloat32(0) // UnkFloat2, UnkFloat3
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0) // UnkUInt1..4
        w.writeInt32(0); w.writeInt32(0) // UnkInt5, UnkInt6
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0) // UnkFloat4..7
        w.writeUInt32(0)  // UnkUInt7
        w.writeInt32(0)   // UnkInt8
        w.writeUInt32(0)  // UnkUInt9
        w.writeFloat32(0) // UnkFloat8
        w.writeUInt32(3)  // CameraType1 = none
        w.writeUInt32(3)  // CameraType2 = none
        w.writeUInt8(9)   // UnkByte (non-Demo)

        XCTAssertEqual(w.count, 187)

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 4, isDemo: false)

        XCTAssertEqual(camera.camHeader, 0xCAFE)
        XCTAssertEqual(camera.unkShort, 7)
        XCTAssertEqual(camera.unkByte, 9)
        XCTAssertEqual(camera.cameraType1, .none)
        XCTAssertEqual(camera.cameraType2, .none)
        XCTAssertNil(camera.subtype1)
        XCTAssertNil(camera.subtype2)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testParseCameraDemoOmitsUnkShortAndUnkByte() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0) // CamHeader
        // No UnkShort for Demo.
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(3); w.writeUInt32(3)
        // No UnkByte for Demo.

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 1, isDemo: true)

        XCTAssertNil(camera.unkShort)
        XCTAssertNil(camera.unkByte)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// Point (0x1C02) is the simplest sub-camera with an actual payload —
    /// a good spot-check that slot dispatch and trailing-field parsing work.
    func testParseCameraWithPointSubtype() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(0x1C02) // CameraType1 = point
        w.writeUInt32(3)      // CameraType2 = none
        w.writeUInt8(0)
        // Point payload:
        w.writeUInt32(99)
        w.writeFloat32(1.5)
        w.writeFloat32(2.5)
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1)

        var cursor = BinaryCursor(data: w.data)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 2, isDemo: false)

        XCTAssertEqual(camera.cameraType1, .point)
        guard case .point(let point) = camera.subtype1 else {
            return XCTFail("Expected a .point subtype")
        }
        XCTAssertEqual(point.unkInt, 99)
        XCTAssertEqual(point.unkFloat1, 1.5, accuracy: 0.0001)
        XCTAssertEqual(point.unkVector, SIMD4<Float>(10, 20, 30, 1))
        XCTAssertNil(camera.subtype2)
        XCTAssertEqual(cursor.position, w.count)
    }

    /// "Spline & Camera Path Persistence" (roadmap 6.3) — the real
    /// correctness guarantee the write path depends on: each control
    /// point's `controlPointFileOffsets[i]` must point at the exact byte
    /// offset `WorldPlacementParser` itself read that vector from, so that
    /// patching `WorldPlacementWriter.writeCameraControlPoint`'s 16 bytes
    /// in at that offset — and nothing else — round-trips a moved control
    /// point while leaving every other byte in the record (including the
    /// *other* control point and the trailing data) untouched.
    func testCameraPathControlPointOffsetsRoundTripAWriteBack() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(0x1C04) // CameraType1 = path
        w.writeUInt32(3)      // CameraType2 = none
        w.writeUInt8(0)
        // Path payload: unkInt, f1, f2, vectorCount=2, 2 control points, unkInt2=0 (no trailing data).
        w.writeUInt32(7)
        w.writeFloat32(1.25)
        w.writeFloat32(2.5)
        w.writeUInt32(2)
        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30); w.writeFloat32(1) // point 0
        w.writeFloat32(40); w.writeFloat32(50); w.writeFloat32(60); w.writeFloat32(1) // point 1
        w.writeInt32(0)

        let originalBytes = w.data
        var cursor = BinaryCursor(data: originalBytes)
        let camera = try WorldPlacementParser.parseCamera(&cursor, recordID: 9, isDemo: false)

        guard case .path(let path) = camera.subtype1 else {
            return XCTFail("Expected a .path subtype")
        }
        XCTAssertEqual(path.unkVectors, [SIMD4<Float>(10, 20, 30, 1), SIMD4<Float>(40, 50, 60, 1)])
        XCTAssertEqual(path.controlPointFileOffsets.count, 2)

        // The recorded offset for point 0 must land exactly on point 0's
        // real bytes — reading a fresh Vector4 straight from the original
        // buffer at that offset must reproduce the parsed value exactly.
        for (index, offset) in path.controlPointFileOffsets.enumerated() {
            var probe = BinaryCursor(data: originalBytes)
            _ = try probe.seek(to: offset)
            XCTAssertEqual(try probe.readVector4(), path.unkVectors[index], "control point \(index) offset didn't point at its own bytes")
        }

        // Move point 0 and patch just its 16 bytes into a copy of the file.
        let movedPoint0 = SIMD4<Float>(111, 222, 333, 1)
        var patched = originalBytes
        let offset0 = path.controlPointFileOffsets[0]
        patched.replaceSubrange(offset0..<(offset0 + 16), with: WorldPlacementWriter.writeCameraControlPoint(movedPoint0))

        var reparseCursor = BinaryCursor(data: patched)
        let reparsedCamera = try WorldPlacementParser.parseCamera(&reparseCursor, recordID: 9, isDemo: false)
        guard case .path(let reparsedPath) = reparsedCamera.subtype1 else {
            return XCTFail("Expected a .path subtype after patch")
        }
        XCTAssertEqual(reparsedPath.unkVectors[0], movedPoint0)
        // Everything else — the other control point, unkInt/f1/f2 — must be
        // completely untouched by a patch scoped to just one point's bytes.
        XCTAssertEqual(reparsedPath.unkVectors[1], SIMD4<Float>(40, 50, 60, 1))
        XCTAssertEqual(reparsedPath.unkInt, 7)
        XCTAssertEqual(reparsedPath.unkFloat1, 1.25, accuracy: 0.0001)
        XCTAssertEqual(patched.count, originalBytes.count)
    }

    func testParseCameraUnknownSubtypeThrows() throws {
        var w = BinaryWriter()
        w.writeUInt32(0); w.writeUInt32(1); w.writeFloat32(0.3)
        for _ in 0..<3 { w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1) }
        w.writeInt32(0); w.writeInt32(0); w.writeUInt32(10)
        w.writeUInt32(0)
        w.writeUInt16(0)
        w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(1)
        w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0); w.writeUInt32(0)
        w.writeInt32(0); w.writeInt32(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt32(0); w.writeInt32(0); w.writeUInt32(0); w.writeFloat32(0)
        w.writeUInt32(0xDEAD) // unrecognized type code
        w.writeUInt32(3)
        w.writeUInt8(0)

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try WorldPlacementParser.parseCamera(&cursor, recordID: 3, isDemo: false)) { error in
            guard case WorldPlacementParserError.unknownCameraSubtype(let type) = error else {
                return XCTFail("Expected .unknownCameraSubtype, got \(error)")
            }
            XCTAssertEqual(type, 0xDEAD)
        }
    }
}
