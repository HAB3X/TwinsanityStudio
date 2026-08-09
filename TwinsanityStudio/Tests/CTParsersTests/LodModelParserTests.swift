import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class LodModelParserTests: XCTestCase {
    func testParsesThreeLevelLodModel() throws {
        var w = BinaryWriter()
        w.writeUInt32(4098) // header — matches the reference tool's own real default
        w.writeUInt8(3)     // modelsAmount
        w.writeUInt32(0)    // zero
        for _ in 0..<4 { w.writeUInt32(1641631945) } // lodDistances
        w.writeUInt32(111); w.writeUInt32(222); w.writeUInt32(333) // lodModelIDs

        var cursor = BinaryCursor(data: w.data)
        let lod = try LodModelParser.parse(&cursor, recordID: 7)

        XCTAssertEqual(lod.header, 4098)
        XCTAssertEqual(lod.lodDistances.count, 4)
        XCTAssertEqual(lod.lodModelIDs, [111, 222, 333])
        XCTAssertEqual(cursor.position, w.data.count)
    }

    func testSingleLevelLodModel() throws {
        var w = BinaryWriter()
        w.writeUInt32(4098)
        w.writeUInt8(1)
        w.writeUInt32(0)
        for _ in 0..<4 { w.writeUInt32(0) }
        w.writeUInt32(999)

        var cursor = BinaryCursor(data: w.data)
        let lod = try LodModelParser.parse(&cursor, recordID: 1)
        XCTAssertEqual(lod.lodModelIDs, [999])
        XCTAssertEqual(cursor.position, w.data.count)
    }
}
