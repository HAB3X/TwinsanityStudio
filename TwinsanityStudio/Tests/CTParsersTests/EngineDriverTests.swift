import XCTest
@testable import CTCore
@testable import CTModels

final class EngineDriverTests: XCTestCase {
    func testRegistryHasBothRealDrivers() {
        XCTAssertEqual(EngineDriverRegistry.all.count, 2)
        XCTAssertTrue(EngineDriverRegistry.all.contains { $0.id == "twinsanity" })
        XCTAssertTrue(EngineDriverRegistry.all.contains { $0.id == "wrath-of-cortex" })
    }

    func testTwinsanityExtensionsResolveToTwinsanityDriver() {
        for ext in ["RM2", "SM2", "RMX", "SMX", "rm2"] {
            XCTAssertEqual(EngineDriverRegistry.driver(forExtension: ext)?.id, "twinsanity", "\(ext) should resolve to the Twinsanity driver")
        }
    }

    func testWrathOfCortexExtensionsResolveToWrathOfCortexDriver() {
        for ext in ["CRT", "WMP", "crt", "wmp"] {
            XCTAssertEqual(EngineDriverRegistry.driver(forExtension: ext)?.id, "wrath-of-cortex", "\(ext) should resolve to the Wrath of Cortex driver")
        }
    }

    func testUnrecognizedExtensionResolvesToNoDriver() {
        XCTAssertNil(EngineDriverRegistry.driver(forExtension: "TXT"))
    }

    func testWrathOfCortexDriverIsHonestlyScopedToPS2() {
        let driver = WrathOfCortexEngineDriver()
        XCTAssertEqual(driver.supportedPlatforms, [.ps2], "the GameCube variant isn't ported — this must not silently claim otherwise")
    }
}
