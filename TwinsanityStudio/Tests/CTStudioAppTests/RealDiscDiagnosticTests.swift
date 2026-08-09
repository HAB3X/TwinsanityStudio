import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// Real-disc regression coverage for the "Forge Mode bug fix" pass —
/// confirms bug reports ("actors show up as squares," "levels fail to
/// load") against actual game data rather than guessing, and pins the
/// fix (`AssetResolver.resolveInstanceObject`'s `Startup/Default.rm2`
/// fallback — see its own doc comment) so a future change can't silently
/// regress it. Skips everywhere the disc image isn't mounted, same as
/// `ModelViewerRendererTests.testRenderRealModelToOffscreenSnapshot`.
final class RealDiscDiagnosticTests: XCTestCase {
    private func loadDefaultAssetIndex(_ index: ArchiveIndex) throws -> GraphicsAssetIndex {
        let entry = try XCTUnwrap(index.entries.first { $0.name.caseInsensitiveCompare("Startup/Default.rm2") == .orderedSame })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let fileRoot = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entry.name)
        return AssetResolver.buildIndex(fileRoot: fileRoot)
    }

    /// Fast (~a few seconds), single-level check: before the
    /// `Startup/Default.rm2` fallback existed, this level (`hubd.rm2`)
    /// resolved only 82/131 Instance records to real geometry — every
    /// unresolved crate/gem falling back to the amber marker even though
    /// it's a perfectly ordinary, visual, common prop. With the fallback,
    /// 126/131 resolve; the handful still unresolved are genuinely
    /// non-visual game-logic objects (an ambient sound emitter, a
    /// co-op-only proxy, a controller, a player-mode flag setter) —
    /// confirmed by name via `DefaultObjectID`, not assumed.
    func testCommonSharedObjectsResolveViaDefaultRM2Fallback() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let entry = try XCTUnwrap(index.entries.first { $0.name == "Levels/Earth/Hub/hubd.rm2" })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let fileRoot = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entry.name)
        let assetIndex = AssetResolver.buildIndex(fileRoot: fileRoot)
        let defaultIndex = try loadDefaultAssetIndex(index)

        var instanceNodes: [(node: ChunkNode, instance: PlacedInstance)] = []
        func walk(_ node: ChunkNode) {
            if case .instance(let placed) = node.payload { instanceNodes.append((node, placed)) }
            for child in node.children { walk(child) }
        }
        walk(fileRoot)
        XCTAssertEqual(instanceNodes.count, 131, "fixture level's instance count changed — re-verify the expectations below still apply")

        var unresolvedNames: Set<String> = []
        var resolvedCount = 0
        for (_, instance) in instanceNodes {
            let selector = instance.unknownUInt32List2.first ?? 0
            if AssetResolver.resolveInstanceObject(objectID: instance.objectID, instanceSelector: selector, index: assetIndex, defaultIndex: defaultIndex) != nil {
                resolvedCount += 1
            } else {
                unresolvedNames.insert(DefaultObjectID.names[instance.objectID] ?? "UNKNOWN_ID_\(instance.objectID)")
            }
        }

        XCTAssertGreaterThanOrEqual(resolvedCount, 120, "the Default.rm2 fallback should resolve the overwhelming majority of this level's instances")
        // Real crates that were the exact symptom of the missing fallback
        // — must not regress back to unresolved.
        XCTAssertFalse(unresolvedNames.contains("BASICCRATE"))
        XCTAssertFalse(unresolvedNames.contains("NITROCRATE"))
        XCTAssertFalse(unresolvedNames.contains("TNTCRATE"))
        XCTAssertFalse(unresolvedNames.contains("GEM_GREEN"))
    }

    /// Slow (whole-archive, ~5 minutes) — real evidence for two separate
    /// bug reports at once: "some levels are not loading correctly" (0
    /// parse failures across all 269 real level files says this isn't a
    /// structural-parse problem) and "actors are missing" (91% of all
    /// 9779 real Instance records across the archive resolve to real
    /// geometry with the Default.rm2 fallback, up from 51% without it).
    /// Excluded from routine fast-suite runs by name, same convention as
    /// `WorkspaceViewModelIntegrationTests`.
    func testWholeArchiveParsesCleanlyWithHighInstanceResolution() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let levelEntries = index.entries.filter { $0.name.lowercased().hasSuffix(".rm2") || $0.name.lowercased().hasSuffix(".sm2") }
        let defaultIndex = try loadDefaultAssetIndex(index)

        var parseFailures: [(name: String, error: String)] = []
        var totalInstances = 0
        var resolvedInstances = 0

        for entry in levelEntries {
            do {
                let data = try BDArchiveParser.readEntryData(entry, index: index)
                let fileKind: TwinsFileKind = entry.name.lowercased().hasSuffix(".sm2") ? .sm2 : .rm2
                let fileRoot = try RM2Parser.parse(data: data, fileKind: fileKind, fileName: entry.name)
                let assetIndex = AssetResolver.buildIndex(fileRoot: fileRoot)

                var instanceNodes: [(node: ChunkNode, instance: PlacedInstance)] = []
                func walk(_ node: ChunkNode) {
                    if case .instance(let placed) = node.payload { instanceNodes.append((node, placed)) }
                    for child in node.children { walk(child) }
                }
                walk(fileRoot)

                totalInstances += instanceNodes.count
                for (_, instance) in instanceNodes {
                    let selector = instance.unknownUInt32List2.first ?? 0
                    if AssetResolver.resolveInstanceObject(objectID: instance.objectID, instanceSelector: selector, index: assetIndex, defaultIndex: defaultIndex) != nil {
                        resolvedInstances += 1
                    }
                }
            } catch {
                parseFailures.append((entry.name, "\(error)"))
            }
        }

        for f in parseFailures.prefix(20) {
            print("DIAG: parse failure — \(f.name): \(f.error)")
        }
        XCTAssertTrue(parseFailures.isEmpty, "\(parseFailures.count)/\(levelEntries.count) real level files failed to parse structurally")
        let resolutionPercent = totalInstances > 0 ? resolvedInstances * 100 / totalInstances : 0
        print("DIAG: \(resolvedInstances)/\(totalInstances) instances resolved (\(resolutionPercent)%)")
        XCTAssertGreaterThanOrEqual(resolutionPercent, 85, "instance resolution rate regressed — expected the Default.rm2 fallback to keep this in the high 80s/90s")
    }
}
