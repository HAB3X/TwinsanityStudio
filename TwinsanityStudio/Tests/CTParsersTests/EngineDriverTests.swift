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

    /// "Pluggable Engine Driver System" (roadmap 5.3): `WorkspaceViewModel.
    /// open(url:)` dispatches on this instead of hardcoding a specific
    /// driver ID — this pins the real, currently-declared capability of
    /// each driver so that dispatch logic has something concrete to test
    /// against, and so a future third driver can't silently regress
    /// Twinsanity's own main-tree ingestion just by being added to the
    /// registry.
    func testTwinsanityDriverIngestsIntoMainWorkspaceTree() {
        guard case .mainWorkspaceTree = TwinsanityEngineDriver().ingestionCapability else {
            return XCTFail("Twinsanity's own files must ingest into the main workspace tree")
        }
    }

    func testWrathOfCortexDriverIsStandaloneOnlyWithARealLoadHint() {
        guard case .standaloneOnly(let loadHint) = WrathOfCortexEngineDriver().ingestionCapability else {
            return XCTFail("Wrath of Cortex files aren't chunk-headered — they have no main-tree shape to ingest into")
        }
        XCTAssertFalse(loadHint.isEmpty)
    }
}
