import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class GameObjectParserTests: XCTestCase {
    func testParseReadsNameAndOGIsSkippingUnkFields() throws {
        var w = BinaryWriter()
        w.writeUInt32(0)              // UnkBitfield — neither optional block present
        w.writeBytes([UInt8](repeating: 0, count: 8)) // ScriptSlots

        let name = "AKUAKUCRATE"
        w.writeInt32(Int32(name.utf8.count))
        w.writeASCIIString(name)

        w.writeInt32(2)               // UI32 count
        w.writeUInt32(111)
        w.writeUInt32(222)

        w.writeInt32(3)               // OGIs count
        w.writeUInt16(10)
        w.writeUInt16(65535)          // "no value" sentinel, preserved as-is
        w.writeUInt16(30)

        // Trailing Anims/Scripts/Objects/Sounds lists this parser doesn't
        // read — present in a real record, but irrelevant to prove the
        // reader stopped exactly where it should have (right after OGIs).
        w.writeInt32(0)

        var cursor = BinaryCursor(data: w.data)
        let gameObject = try GameObjectParser.parse(&cursor, recordID: 7)

        XCTAssertEqual(gameObject.id, 7)
        XCTAssertEqual(gameObject.name, "AKUAKUCRATE")
        XCTAssertEqual(gameObject.ogiIDs, [10, 65535, 30])
        // Cursor should sit immediately after the OGIs list — right before
        // the Anims count this test wrote but the parser doesn't consume.
        XCTAssertEqual(cursor.position, w.data.count - 4)
    }
}
