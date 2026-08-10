import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// Pins the real, hand-traced byte layout of `ParticleData.cs`'s `Load` for
/// the two versions this codebase actually supports (28 Demo, 30 Final).
/// Every scalar field below is written with a distinct, monotonically
/// increasing value, so any read-order misalignment shows up as a mismatched
/// value rather than an accidental pass.
final class ParticleDataParserTests: XCTestCase {
    /// Sequential distinct float generator — the same value both written to
    /// the stream and captured as the "expected" value, so write-order and
    /// assert-order are provably the same order.
    private struct ValueGen {
        var counter: Float = 0
        mutating func next() -> Float { counter += 1; return counter }
    }

    private static func writeFixedName(_ w: inout BinaryWriter, _ text: String) {
        var bytes = Array(text.utf8)
        bytes.append(0)
        while bytes.count < 16 { bytes.append(0xFF) } // junk after the null terminator — must be discarded, not read as part of the name.
        precondition(bytes.count == 16)
        w.writeBytes(bytes)
    }

    private static func writeGradient8(_ w: inout BinaryWriter, _ gen: inout ValueGen) -> (time: [Float], value: [Float]) {
        var time: [Float] = []
        var value: [Float] = []
        for _ in 0..<8 {
            let t = gen.next(); w.writeFloat32(t); time.append(t)
            let v = gen.next(); w.writeFloat32(v); value.append(v)
        }
        return (time, value)
    }

    private static func writeColorGradient(_ w: inout BinaryWriter, _ gen: inout ValueGen) -> [SIMD4<Float>] {
        var result: [SIMD4<Float>] = []
        for _ in 0..<8 {
            let x = gen.next(), y = gen.next(), z = gen.next(), a = gen.next()
            w.writeFloat32(x); w.writeFloat32(y); w.writeFloat32(z); w.writeFloat32(a)
            result.append(SIMD4(x, y, z, a))
        }
        return result
    }

    private struct ExpectedDefinition {
        var name = "Fire"
        var genRate: Int16 = 0
        var genSort: UInt8 = 0
        var cutOnRadius: Float = 0
        var cutOffRadius: Float = 0
        var drawCutOff: Float = 0
        var velocity: Float = 0
        var randomEmitX: Float = 0
        var randomEmitY: Float = 0
        var randomEmitZ: Float = 0
        var randomStartX: Float = 0
        var randomStartY: Float = 0
        var randomStartZ: Float = 0
        var gravity: Float = 0
        var particleLifeTime: Float = 0
        var minSize: Float = 0
        var maxSize: Float = 0
        var collisionNumSpheres: UInt8 = 0
        var drawFlag: UInt8 = 0
        var padAmount: Int32 = 0
        var particleGhostsNum: Int16 = 0
        var starRadialPoints: Int16 = 0
        var rampTime: Float = 0
        var texturePage: Int32 = 0
        var scaleFactor: Float = 0
        var unkVec3: SIMD4<Float> = SIMD4(0, 0, 0, 0)
        var colorGradient: [SIMD4<Float>] = []
        var alphaGradientValue: [Float] = []
        var collisionValue: [Float] = []
    }

    /// Writes one full `ParticleSystemDefinition`, in the exact field order
    /// `ParticleDataParser.parseDefinition` reads, for either version.
    /// `genSortValue` lets a caller pin `.normal` (0) to exercise the
    /// version-28 computed-`unkVec3` path.
    private static func writeDefinition(_ w: inout BinaryWriter, isFinal: Bool, genSortValue: UInt8 = 6) -> ExpectedDefinition {
        var gen = ValueGen()
        var expected = ExpectedDefinition()

        writeFixedName(&w, expected.name)
        expected.genRate = 42
        w.writeInt16(expected.genRate)
        w.writeUInt16(100) // maxParticleCount
        w.writeUInt16(0) // unkUShort3
        w.writeUInt16(1); w.writeUInt16(2); w.writeUInt16(3); w.writeUInt16(4) // emitter over/off time (+random)
        expected.genSort = genSortValue
        w.writeUInt8(expected.genSort)
        w.writeUInt8(0) // unkByte3
        w.writeUInt8(2) // textureFilter (.modulation)
        w.writeUInt8(0) // unkByte5
        w.writeFloat32(gen.next()) // unkFloat1
        expected.cutOnRadius = gen.next(); w.writeFloat32(expected.cutOnRadius)
        expected.cutOffRadius = gen.next(); w.writeFloat32(expected.cutOffRadius)
        expected.drawCutOff = gen.next(); w.writeFloat32(expected.drawCutOff)
        w.writeFloat32(gen.next()) // unkFloat5
        w.writeFloat32(gen.next()) // unkFloat6
        expected.velocity = gen.next(); w.writeFloat32(expected.velocity)
        expected.randomEmitX = gen.next(); w.writeFloat32(expected.randomEmitX)
        expected.randomEmitY = gen.next(); w.writeFloat32(expected.randomEmitY)
        expected.randomEmitZ = gen.next(); w.writeFloat32(expected.randomEmitZ)
        expected.randomStartX = gen.next(); w.writeFloat32(expected.randomStartX)
        expected.randomStartY = gen.next(); w.writeFloat32(expected.randomStartY)
        expected.randomStartZ = gen.next(); w.writeFloat32(expected.randomStartZ)
        for _ in 0..<12 { w.writeFloat32(gen.next()) } // unkFloat8...unkFloat19
        expected.gravity = gen.next(); w.writeFloat32(expected.gravity)
        expected.particleLifeTime = gen.next(); w.writeFloat32(expected.particleLifeTime)
        w.writeUInt16(0) // unkUShort8
        w.writeUInt8(0); w.writeUInt8(0) // unkByte6/7
        w.writeFloat32(gen.next()) // unkFloat22
        w.writeFloat32(gen.next()); w.writeFloat32(gen.next()); w.writeFloat32(gen.next()); w.writeFloat32(gen.next()) // jibber x4

        expected.colorGradient = writeColorGradient(&w, &gen)
        let alpha = writeGradient8(&w, &gen)
        expected.alphaGradientValue = alpha.value

        w.writeFloat32(gen.next()); w.writeFloat32(gen.next()) // distortion x/y
        expected.minSize = gen.next(); w.writeFloat32(expected.minSize)
        expected.maxSize = gen.next(); w.writeFloat32(expected.maxSize)
        _ = writeGradient8(&w, &gen) // sizeWidth
        _ = writeGradient8(&w, &gen) // sizeHeight
        w.writeFloat32(gen.next()); w.writeFloat32(gen.next()) // min/maxRotation
        _ = writeGradient8(&w, &gen) // rotation
        _ = writeGradient8(&w, &gen) // unkGradient1
        _ = writeGradient8(&w, &gen) // unkGradient2
        w.writeFloat32(gen.next()); w.writeFloat32(gen.next()); w.writeFloat32(gen.next()); w.writeFloat32(gen.next()) // texture start/end x/y
        let collision = writeGradient8(&w, &gen)
        expected.collisionValue = collision.value
        expected.collisionNumSpheres = 3
        w.writeUInt8(expected.collisionNumSpheres)
        expected.drawFlag = 1
        w.writeUInt8(expected.drawFlag)

        if !isFinal {
            expected.padAmount = 2
            w.writeInt32(expected.padAmount)
            w.writeBytes([UInt8](repeating: 0, count: Int(expected.padAmount) * 24))
        }

        expected.particleGhostsNum = 7
        w.writeInt32(Int32(expected.particleGhostsNum))
        w.writeFloat32(gen.next()) // ghostSeparation
        expected.starRadialPoints = 5
        w.writeInt32(Int32(expected.starRadialPoints))
        w.writeFloat32(gen.next()) // starRadiusRatio
        expected.rampTime = gen.next(); w.writeFloat32(expected.rampTime)
        expected.texturePage = 2
        w.writeInt32(expected.texturePage)
        expected.scaleFactor = gen.next(); w.writeFloat32(expected.scaleFactor)

        if isFinal {
            let x = gen.next(), y = gen.next(), z = gen.next(), vw = gen.next()
            w.writeFloat32(x); w.writeFloat32(y); w.writeFloat32(z); w.writeFloat32(vw)
            expected.unkVec3 = SIMD4(x, y, z, vw)
        }

        return expected
    }

    func testVersion30DefinitionOnlyRoundTrips() throws {
        var w = BinaryWriter()
        w.writeUInt32(30) // version
        w.writeUInt32(1) // particleTypeCount
        let expected = Self.writeDefinition(&w, isFinal: true)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ParticleDataParser.parse(&cursor, recordID: 9, size: w.count)

        XCTAssertEqual(asset.version, 30)
        XCTAssertEqual(asset.particleTypes.count, 1)
        XCTAssertTrue(asset.particleInstances.isEmpty)
        let def = asset.particleTypes[0]
        XCTAssertEqual(def.name, expected.name)
        XCTAssertEqual(def.genRate, expected.genRate)
        XCTAssertEqual(def.resolvedGenSort, .radial)
        XCTAssertEqual(def.cutOnRadius, expected.cutOnRadius)
        XCTAssertEqual(def.cutOffRadius, expected.cutOffRadius)
        XCTAssertEqual(def.drawCutOff, expected.drawCutOff)
        XCTAssertEqual(def.velocity, expected.velocity)
        XCTAssertEqual(def.randomStartZ, expected.randomStartZ)
        XCTAssertEqual(def.gravity, expected.gravity)
        XCTAssertEqual(def.particleLifeTime, expected.particleLifeTime)
        XCTAssertEqual(def.colorGradient, expected.colorGradient)
        XCTAssertEqual(def.alphaGradientValue, expected.alphaGradientValue)
        XCTAssertEqual(def.minSize, expected.minSize)
        XCTAssertEqual(def.maxSize, expected.maxSize)
        XCTAssertEqual(def.collisionValue, expected.collisionValue)
        XCTAssertEqual(def.collisionNumSpheres, expected.collisionNumSpheres)
        XCTAssertEqual(def.drawFlag, expected.drawFlag)
        XCTAssertEqual(def.padAmount, 0, "version 30 never stores padAmount on disk")
        XCTAssertEqual(def.particleGhostsNum, expected.particleGhostsNum)
        XCTAssertEqual(def.starRadialPoints, expected.starRadialPoints)
        XCTAssertEqual(def.rampTime, expected.rampTime)
        XCTAssertEqual(def.texturePage, expected.texturePage)
        XCTAssertEqual(def.scaleFactor, expected.scaleFactor)
        XCTAssertEqual(def.unkVec3, expected.unkVec3, "version 30 stores unkVec3 for real, read straight off disk")
        XCTAssertEqual(cursor.position, w.count)
    }

    func testVersion28DefinitionHasPadAmountAndSkipsStoredUnkVec3() throws {
        var w = BinaryWriter()
        w.writeUInt32(28) // version
        w.writeUInt32(1) // particleTypeCount
        // GenSort != .normal here, so the computed-unkVec3 fallback should hit its "else" (10,10,10,0) branch.
        let expected = Self.writeDefinition(&w, isFinal: false, genSortValue: ParticleSystemDefinition.GenSort.radial.rawValue)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ParticleDataParser.parse(&cursor, recordID: 3, size: w.count)

        XCTAssertEqual(asset.version, 28)
        let def = asset.particleTypes[0]
        XCTAssertEqual(def.padAmount, expected.padAmount, "version 28 (Demo) is the only version that stores padAmount on disk")
        XCTAssertEqual(def.scaleFactor, expected.scaleFactor, "fields after the version-28-only padAmount+skip must still line up")
        XCTAssertEqual(def.texturePage, expected.texturePage)
        XCTAssertEqual(def.unkVec3, SIMD4<Float>(10, 10, 10, 0), "non-.normal GenSort on version 28 falls back to the reference's hardcoded default, not disk data")
        XCTAssertEqual(cursor.position, w.count)
    }

    func testVersion28NormalGenSortComputesUnkVec3FromMotionFields() throws {
        var w = BinaryWriter()
        w.writeUInt32(28)
        w.writeUInt32(1)
        let expected = Self.writeDefinition(&w, isFinal: false, genSortValue: ParticleSystemDefinition.GenSort.normal.rawValue)

        var cursor = BinaryCursor(data: w.data)
        let asset = try ParticleDataParser.parse(&cursor, recordID: 3, size: w.count)
        let def = asset.particleTypes[0]

        let f1 = expected.maxSize * 0.0001
        let expectedX = ((expected.velocity + expected.randomEmitX) * expected.particleLifeTime + expected.randomStartX + f1) * 0.75
        let expectedY = ((expected.velocity + expected.randomEmitY) * expected.particleLifeTime + expected.randomStartY + f1) * 0.75
        let expectedZ = ((expected.velocity + expected.randomEmitZ) * expected.particleLifeTime + expected.randomStartZ + f1) * 0.75

        XCTAssertEqual(def.unkVec3.x, expectedX, accuracy: 0.0001)
        XCTAssertEqual(def.unkVec3.y, expectedY, accuracy: 0.0001)
        XCTAssertEqual(def.unkVec3.z, expectedZ, accuracy: 0.0001)
        XCTAssertEqual(def.unkVec3.w, 0)
    }

    func testInstanceRoundTripsAfterDefinitions() throws {
        var w = BinaryWriter()
        w.writeUInt32(30) // version
        w.writeUInt32(0) // particleTypeCount — zero definitions, go straight to instances
        w.writeUInt32(1) // instanceCheck / particleInstanceCount

        w.writeFloat32(10); w.writeFloat32(20); w.writeFloat32(30) // position xyz (w is hardcoded, not read)
        w.writeInt16(1); w.writeInt16(2) // gravityRotX/Y
        w.writeInt16(3); w.writeInt16(4) // emitRotX/Y
        w.writeInt16(5) // unkShort5
        w.writeUInt32(999) // offset
        Self.writeFixedName(&w, "Inst")
        w.writeInt32(1) // switchType
        w.writeInt32(-1) // switchID
        w.writeFloat32(2.5) // switchValue
        w.writeInt16(6); w.writeInt16(7) // unkShort6/7
        w.writeFloat32(1.5) // planeOffset
        w.writeFloat32(0.9) // bounceFactor
        w.writeInt16(4) // groupID

        var cursor = BinaryCursor(data: w.data)
        let asset = try ParticleDataParser.parse(&cursor, recordID: 5, size: w.count)

        XCTAssertTrue(asset.particleTypes.isEmpty)
        XCTAssertEqual(asset.particleInstances.count, 1)
        let inst = asset.particleInstances[0]
        XCTAssertEqual(inst.position, SIMD4<Float>(10, 20, 30, 1))
        XCTAssertEqual(inst.gravityRotX, 1)
        XCTAssertEqual(inst.gravityRotY, 2)
        XCTAssertEqual(inst.emitRotX, 3)
        XCTAssertEqual(inst.emitRotY, 4)
        XCTAssertEqual(inst.unkShort5, 5)
        XCTAssertEqual(inst.offset, 999)
        XCTAssertEqual(inst.name, "Inst")
        XCTAssertEqual(inst.switchType, 1)
        XCTAssertEqual(inst.switchID, -1)
        XCTAssertEqual(inst.switchValue, 2.5)
        XCTAssertEqual(inst.unkShort6, 6)
        XCTAssertEqual(inst.unkShort7, 7)
        XCTAssertEqual(inst.planeOffset, 1.5)
        XCTAssertEqual(inst.bounceFactor, 0.9)
        XCTAssertEqual(inst.groupID, 4)
        XCTAssertEqual(cursor.position, w.count)
    }

    func testRecordWithNoInstanceDataExitsEarly() throws {
        var w = BinaryWriter()
        w.writeUInt32(30)
        w.writeUInt32(0) // zero definitions
        // No trailing bytes at all: declared size exactly matches what's been consumed so far.

        var cursor = BinaryCursor(data: w.data)
        let asset = try ParticleDataParser.parse(&cursor, recordID: 1, size: w.count)
        XCTAssertTrue(asset.particleTypes.isEmpty)
        XCTAssertTrue(asset.particleInstances.isEmpty)
    }

    func testUnsupportedVersionThrows() {
        var w = BinaryWriter()
        w.writeUInt32(21) // Twins Proto — not a real shipped Crash Twinsanity version this codebase supports.

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try ParticleDataParser.parse(&cursor, recordID: 1, size: w.count)) { error in
            guard case ParticleDataParser.ParticleDataParseError.unsupportedVersion(let version) = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(version, 21)
        }
    }

    func testHugeDeclaredTypeCountThrowsInsteadOfOverAllocating() {
        var w = BinaryWriter()
        w.writeUInt32(30)
        w.writeUInt32(UInt32.max)

        var cursor = BinaryCursor(data: w.data)
        XCTAssertThrowsError(try ParticleDataParser.parse(&cursor, recordID: 1, size: w.count)) { error in
            XCTAssertTrue(error is BinaryCursorError)
        }
    }
}
