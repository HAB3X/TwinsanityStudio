import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers

/// "Scenery Placement" (editing an *existing* placement, not creating a
/// new one -- see `SceneryModelPlacement.matrixFileOffset`'s doc comment
/// for the scope this stops at). Real round-trip test against a real
/// disc file, matching this codebase's established writer discipline:
/// `parse(write(parse(x))) == parse(x)`.
final class SceneryDataWriterTests: XCTestCase {
    private static let bhURL = URL(fileURLWithPath: "/Users/marcuschandler/Documents/Crash Twinsanity/Games Files/PS2 FILES/CRASH6/CRASH.BH")

    func testWriteModelMatrixRoundTripsThroughParserOnRealFile() throws {
        guard FileManager.default.fileExists(atPath: Self.bhURL.path) else {
            throw XCTSkip("Real disc image not present")
        }
        let index = try BDArchiveParser.readIndex(bhURL: Self.bhURL)
        guard let entry = index.entries.first(where: { $0.name == "Levels/Earth/Hub/hubb.sm2" }) else {
            throw XCTSkip("hubb.sm2 not found in this archive")
        }
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var sceneryNode: ChunkNode?
        var found: SceneryAsset?
        func walk(_ node: ChunkNode) {
            if found == nil, case .scenery(let scenery) = node.payload, !scenery.placements.isEmpty {
                found = scenery
                sceneryNode = node
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        let scenery = try XCTUnwrap(found, "expected a real SceneryData with placements in hubb.sm2")
        let node = try XCTUnwrap(sceneryNode)
        let placement = try XCTUnwrap(scenery.placements.first { $0.matrixFileOffset != nil })
        let matrixOffset = try XCTUnwrap(placement.matrixFileOffset)

        // A deliberately different, real, hand-chosen matrix -- not just
        // re-writing the same bytes back (which would trivially "round
        // trip" even with a byte-order bug).
        let editedMatrix: [SIMD4<Float>] = [
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(42.5, -17.25, 8.0, 1),
        ]
        let encoded = SceneryDataWriter.writeModelMatrix(editedMatrix)
        XCTAssertEqual(encoded.count, 64, "4 rows * 4 floats * 4 bytes")

        // Patch just those 64 bytes into a full copy of the record's own
        // bytes, at the record-relative offset the parser captured, then
        // re-parse the WHOLE record through the real parser -- proving
        // the offset is correct, not just that encode/decode round-trip
        // in isolation.
        var recordBytes = data.subdata(in: (data.startIndex + node.fileOffset)..<(data.startIndex + node.fileOffset + node.byteSize))
        recordBytes.replaceSubrange(matrixOffset..<(matrixOffset + 64), with: encoded)

        var cursor = BinaryCursor(data: recordBytes)
        let reparsed = try SceneryDataParser.parse(&cursor, recordID: node.recordID)
        let reparsedPlacement = try XCTUnwrap(reparsed.placements.first { $0.matrixFileOffset == matrixOffset })

        for i in 0..<4 {
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].x, editedMatrix[i].x, accuracy: 0.0001)
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].y, editedMatrix[i].y, accuracy: 0.0001)
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].z, editedMatrix[i].z, accuracy: 0.0001)
            XCTAssertEqual(reparsedPlacement.modelMatrix[i].w, editedMatrix[i].w, accuracy: 0.0001)
        }

        // Every *other* placement's matrix must be untouched -- proves
        // the patch didn't shift or corrupt anything else in the record.
        for original in scenery.placements where original.matrixFileOffset != matrixOffset {
            guard let otherOffset = original.matrixFileOffset,
                  let reparsedOther = reparsed.placements.first(where: { $0.matrixFileOffset == otherOffset })
            else { continue }
            XCTAssertEqual(reparsedOther.modelMatrix, original.modelMatrix, "unrelated placement's matrix must be byte-identical after the patch")
        }
    }
}
