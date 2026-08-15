import XCTest
import Foundation
@testable import CTParsers

final class WOCPadParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption -- 40 + count*20 == fileSize
    /// on every file checked, not just an even division.
    func testRealPADFilesConsumeExactlyTheWholeFile() throws {
        let samples: [(path: String, expectedCount: Int, expectedMagic: UInt32)] = [
            ("A/VOLCANO/VOLCANO.PAD", 1384, 35998),
            ("A/CASTLE/CASTLE.PAD", 1819, 7198),
            ("A/GARDEN/GARDEN.PAD", 1625, 35998),
        ]
        for sample in samples {
            let data = try loadReal(sample.path)
            let file = try WOCPadParser.parse(data)
            XCTAssertEqual(file.records.count, sample.expectedCount, "record count for \(sample.path)")
            XCTAssertEqual(file.magic, sample.expectedMagic, "magic for \(sample.path)")
            XCTAssertTrue(file.records.allSatisfy { $0.count == 20 })
        }
    }
}
