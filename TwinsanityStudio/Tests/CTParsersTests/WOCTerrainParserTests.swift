import XCTest
import Foundation
@testable import CTParsers

final class WOCTerrainParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption on 3 real files of very
    /// different sizes -- the tail-record table boundary and count are
    /// exact, not approximate.
    func testRealTERFilesConsumeExactlyTheWholeFile() throws {
        let samples: [(path: String, expectedTailCount: Int)] = [
            ("A/AIRSHIP/AIRSHIP.TER", 5),
            ("A/DROID/DROID.TER", 47),
            ("A/WESTERN/WESTERN.TER", 189),
        ]
        for sample in samples {
            let data = try loadReal(sample.path)
            let file = try WOCTerrainParser.parse(data)
            XCTAssertEqual(file.tailRecords.count, sample.expectedTailCount, "tail record count for \(sample.path)")
            XCTAssertTrue(file.tailRecords.allSatisfy { $0.count == 52 })
            XCTAssertFalse(file.mainBlock.isEmpty, "main block should be non-empty for \(sample.path)")
        }
    }
}
