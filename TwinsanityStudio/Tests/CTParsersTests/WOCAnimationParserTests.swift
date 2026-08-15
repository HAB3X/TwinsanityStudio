import XCTest
import Foundation
@testable import CTParsers

final class WOCAnimationParserTests: XCTestCase {
    private func loadReal(_ relativePath: String) throws -> Data {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Confirmed by exact byte consumption -- the parser throws rather
    /// than returning partial/garbage data if it doesn't land exactly on
    /// EOF, so a successful parse here is itself the verification.
    func testRealSimpleAnimationFiles() throws {
        let data = try loadReal("A/AVALANCH/AVALANCH.ANM")
        let entries = try WOCAnimationParser.parse(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "avalanche")
        XCTAssertEqual(entries[0].subEntries.map(\.name), ["AVA_MID", "AVA_SML", "AVA_LRG", "AVA_LRG"])
    }

    func testRealCastleAnimationFile() throws {
        let data = try loadReal("A/CASTLE/CASTLE.ANM")
        let entries = try WOCAnimationParser.parse(data)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "ball_04")
        XCTAssertEqual(entries[0].subEntries.map(\.name), ["BALL"])
    }

    /// The confirmed simple-case template does NOT generalize to real
    /// skeletal-animation files -- this documents that boundary with a
    /// real file rather than leaving it as an unverified claim.
    func testRealSkeletalAnimationFileIsNotHandledByThisParser() throws {
        let data = try loadReal("A/TSUNAMI/TOONARMY.ANM")
        XCTAssertThrowsError(try WOCAnimationParser.parse(data))
    }
}
