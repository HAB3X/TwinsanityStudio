import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class AnimationParserTests: XCTestCase {
    func testParsesBodyTrackAndSkipsEmptyFacialTrack() throws {
        var w = BinaryWriter()

        // Leading `Bitfield: UInt32` (`Animation.cs:12,78`) — read once,
        // before the body track's own packer, and never repeated for the
        // facial track. Its value is opaque/unused by this parser; any
        // value proves it's being consumed rather than shifting every
        // following field 4 bytes early.
        w.writeUInt32(0xDEADBEEF)

        // Body packer: joints=1 (bits[0:7)), transformations=1 i.e. raw*2=2
        // (bits[10:22)), componentsPerFrame=2 (bits[22:32)).
        let joints: UInt32 = 1
        let transformationsRaw: UInt32 = 2 // encodes `transformations * 2`
        let componentsPerFrame: UInt32 = 2
        let bodyPacker = joints | (transformationsRaw << 0xA) | (componentsPerFrame << 0x16)
        w.writeUInt32(bodyPacker)
        w.writeUInt16(3) // totalFrames

        // JointSettings[1]
        w.writeUInt16(0x0001); w.writeUInt16(0x0002); w.writeUInt16(0x0003); w.writeUInt16(0x0004)
        // StaticTransforms[1]
        w.writeInt16(4096) // -> linearValue 1.0
        // AnimatedTransforms[3], 2 components each
        w.writeInt16(100); w.writeInt16(200)
        w.writeInt16(300); w.writeInt16(400)
        w.writeInt16(-4096); w.writeInt16(0)

        // Facial: packer=0, totalFrames=0 -> dataSize computes to 0, no further bytes read.
        w.writeUInt32(0)
        w.writeUInt16(0)

        var cursor = BinaryCursor(data: w.data)
        let animation = try AnimationParser.parse(&cursor, recordID: 9)

        XCTAssertEqual(animation.body.jointSettings.count, 1)
        XCTAssertEqual(animation.body.jointSettings[0].animatedTransformIndex, 0x0004)
        XCTAssertEqual(animation.body.staticTransforms.count, 1)
        XCTAssertEqual(animation.body.staticTransforms[0].linearValue, 1.0, accuracy: 0.0001)
        XCTAssertEqual(animation.body.totalFrames, 3)
        XCTAssertEqual(animation.body.componentsPerFrame, 2)
        XCTAssertEqual(animation.body.frames[0].values, [100, 200])
        XCTAssertEqual(animation.body.frames[2].linearValue(at: 0), -1.0, accuracy: 0.0001)

        XCTAssertEqual(animation.facial.totalFrames, 0)
        XCTAssertTrue(animation.facial.jointSettings.isEmpty)
    }
}
