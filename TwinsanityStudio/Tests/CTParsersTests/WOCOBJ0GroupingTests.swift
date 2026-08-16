import XCTest
@testable import CTParsers

/// `WOCContainerParser.groupOBJ0ChunksIntoEntries` -- a third, dedicated
/// investigation found the real rule after two earlier ones failed: a
/// `UInt32LE` flag 112 bytes before each chunk's own marker marks entry
/// boundaries. Validated 15/15 against real files by that investigation;
/// these tests independently re-verify a sample of that same claim
/// directly against real disc bytes (not just trusting the report) plus
/// confirm the honest `nil` fallback on files where the prerequisite
/// `walkOBJ0Chunks` walk itself is known-unreliable.
final class WOCOBJ0GroupingTests: XCTestCase {
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    /// Real files where the underlying chunk walk stays reliable (one
    /// constant marker-to-chunk-start distance) -- grouped entry count
    /// must exactly match OBJ0's own leading-count field.
    func testGroupedEntryCountMatchesOBJ0LeadingCountOnCleanFiles() throws {
        let samples = [
            "A/AIRSHIP/AIRSHIP.GSC",
            "A/FARM/FARM.GSC",
            "A/DROID/DROID.GSC",
        ]
        var checked = 0
        for relativePath in samples {
            let decoded = try loadAndDecompressRealGSC(relativePath)
            let file = try WOCContainerParser.parse(decoded)
            guard let obj0 = file.sections.first(where: { $0.tag == "OBJ0" }) else { continue }
            let leadingCount = try WOCContainerParser.leadingCount(obj0.payload)
            guard let groups = WOCContainerParser.groupOBJ0ChunksIntoEntries(obj0.payload) else {
                XCTFail("\(relativePath): expected a clean grouping, got nil (marker-reuse bug detected?)")
                continue
            }
            XCTAssertEqual(groups.count, leadingCount, "\(relativePath): grouped entry count should match OBJ0's own leading count")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no real sample files were available to check")
    }

    /// `CASTLE_C.GSC`/`HUB.GSC` are the two files confirmed to trigger
    /// `walkOBJ0Chunks`'s marker-reuse bug (heterogeneous per-chunk header
    /// sizes) -- grouping must honestly refuse (`nil`), not silently
    /// return a wrong count.
    func testHeterogeneousFilesReturnNilRatherThanWrongGrouping() throws {
        let samples = [
            "A/CASTLE_C/CASTLE_C.GSC",
            "B/HUB/HUB.GSC",
        ]
        var checked = 0
        for relativePath in samples {
            let decoded = try loadAndDecompressRealGSC(relativePath)
            let file = try WOCContainerParser.parse(decoded)
            guard let obj0 = file.sections.first(where: { $0.tag == "OBJ0" }) else { continue }
            let groups = WOCContainerParser.groupOBJ0ChunksIntoEntries(obj0.payload)
            XCTAssertNil(groups, "\(relativePath): expected the marker-reuse bug to be detected and grouping refused")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "no real sample files were available to check")
    }
}
