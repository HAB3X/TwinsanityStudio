import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class WrathOfCortexParserTests: XCTestCase {
    /// Matches `TWOC_File_CRT.Load` exactly: header, group count, then per
    /// group the first crate inline with the group header, followed by
    /// `crateCount - 1` more crates.
    func testParsesCrateFileWithMultipleGroups() throws {
        var w = BinaryWriter()
        w.writeUInt32(4) // header
        w.writeUInt16(2) // groupCount

        // Group 0: 2 crates
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3) // first crate pos
        w.writeUInt16(100) // group id
        w.writeUInt16(2)   // crateCount
        w.writeUInt16(0)   // unkFlags
        w.writeFloat32(0); w.writeFloat32(90); w.writeFloat32(0) // rotation
        w.writeBytes([UInt8](repeating: 0, count: 10)) // first crate unkFlags
        w.writeUInt8(6); w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255) // types: Fruit
        w.writeBytes([UInt8](repeating: 0, count: 14)) // first crate unkFlags2
        // second crate in group 0
        w.writeFloat32(4); w.writeFloat32(5); w.writeFloat32(6)
        w.writeBytes([UInt8](repeating: 0, count: 10))
        w.writeUInt8(9); w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255) // types: TNT
        w.writeBytes([UInt8](repeating: 0, count: 14))

        // Group 1: 1 crate (just the inline first crate, crateCount=1)
        w.writeFloat32(7); w.writeFloat32(8); w.writeFloat32(9)
        w.writeUInt16(101)
        w.writeUInt16(1)
        w.writeUInt16(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeBytes([UInt8](repeating: 0, count: 10))
        w.writeUInt8(0); w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255) // types: Wireframe
        w.writeBytes([UInt8](repeating: 0, count: 14))

        let file = try WrathOfCortexParser.parseCrateFile(w.data)

        XCTAssertEqual(file.header, 4)
        XCTAssertEqual(file.groups.count, 2)
        XCTAssertEqual(file.groups[0].id, 100)
        XCTAssertEqual(file.groups[0].crates.count, 2)
        XCTAssertEqual(file.groups[0].crates[0].position, SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(file.groups[0].crates[0].type, .fruit)
        XCTAssertEqual(file.groups[0].crates[1].position, SIMD3<Float>(4, 5, 6))
        XCTAssertEqual(file.groups[0].crates[1].type, .tnt)
        XCTAssertEqual(file.groups[1].crates.count, 1)
        XCTAssertEqual(file.groups[1].crates[0].type, .wireframe)
        XCTAssertEqual(file.totalCrateCount, 3)
    }

    func testParsesWumpaFile() throws {
        var w = BinaryWriter()
        w.writeUInt32(2)
        w.writeFloat32(1); w.writeFloat32(2); w.writeFloat32(3)
        w.writeFloat32(-1); w.writeFloat32(-2); w.writeFloat32(-3)

        let file = try WrathOfCortexParser.parseWumpaFile(w.data)
        XCTAssertEqual(file.positions.count, 2)
        XCTAssertEqual(file.positions[0], SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(file.positions[1], SIMD3<Float>(-1, -2, -3))
    }

    func testUnrecognizedCrateTypeIsNilNotFabricated() throws {
        var w = BinaryWriter()
        w.writeUInt32(4)
        w.writeUInt16(1)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeUInt16(0)
        w.writeUInt16(1)
        w.writeUInt16(0)
        w.writeFloat32(0); w.writeFloat32(0); w.writeFloat32(0)
        w.writeBytes([UInt8](repeating: 0, count: 10))
        w.writeUInt8(200); w.writeUInt8(255); w.writeUInt8(255); w.writeUInt8(255) // not a real CrateType
        w.writeBytes([UInt8](repeating: 0, count: 14))

        let file = try WrathOfCortexParser.parseCrateFile(w.data)
        XCTAssertNil(file.groups[0].crates[0].type)
        XCTAssertEqual(file.groups[0].crates[0].rawType, 200)
    }
}
