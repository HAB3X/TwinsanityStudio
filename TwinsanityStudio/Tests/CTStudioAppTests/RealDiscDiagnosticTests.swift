import XCTest
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers
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

    /// "Animations are still not playing" — real evidence, and a
    /// regression pin for the actual root cause: `skinVertices` used to
    /// infer "did any joint influence apply to this vertex" from the
    /// blended *normal's* magnitude, but `SkinParser` never decodes real
    /// per-vertex normals for skin meshes (`normal: .zero`, a separate,
    /// known gap) — so that check misfired 100% of the time and reverted
    /// every skinned vertex back to bind pose every frame, even though
    /// `AnimationSkeletonBinding` was computing correct, real,
    /// per-joint-varying matrices the whole time. Fixed by tracking
    /// total applied weight instead. Verified two ways against a real
    /// skinned character (`Levels/Earth/Cavern/antfight.rm2`): the actual
    /// GPU vertex buffer changes between frames, and the rendered pixels
    /// (same offscreen-render technique `ModelViewerRendererTests.
    /// testRenderRealModelToOffscreenSnapshot` uses) visibly differ.
    func testAnimationVisiblyDeformsARealCharacter() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal device available")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        // A real skinned character with a substantial multi-joint
        // animation, found via an archive-wide scan — an animation's
        // `componentsPerFrame` needs to be reasonably large (this one
        // touches most of the skeleton) for the deformation to be
        // visually obvious; some real animations in this game only drive
        // one minor joint the visible mesh isn't even weighted to.
        let entry = try XCTUnwrap(index.entries.first { $0.name == "Levels/Earth/Cavern/antfight.rm2" })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entry.name)
        let assetIndex = AssetResolver.buildIndex(fileRoot: root)
        var best: (skeleton: SkeletonAsset, asset: ResolvedModelAsset, animation: AnimationAsset)?
        for skeleton in assetIndex.skeletons.values {
            guard skeleton.skinID != 0, assetIndex.skins[skeleton.skinID] != nil else { continue }
            guard let resolved = AssetResolver.resolveSkeleton(skeleton, displayName: "probe", index: assetIndex) else { continue }
            guard let animation = resolved.availableAnimations
                .filter({ $0.body.totalFrames > 1 && $0.body.totalFrames < 2000 })
                .max(by: { $0.body.componentsPerFrame < $1.body.componentsPerFrame })
            else { continue }
            if best == nil || animation.body.componentsPerFrame > best!.animation.body.componentsPerFrame {
                best = (skeleton, resolved, animation)
            }
        }
        let probe = try XCTUnwrap(best, "no real skinned+animated character with any multi-frame animation found in the fixture level")

        let renderer = try XCTUnwrap(ModelViewerRenderer(asset: probe.asset))
        XCTAssertTrue(renderer.hasGeometry)

        renderer.applySkeletalPose(skeleton: probe.skeleton, track: probe.animation.body, frameIndex: 0)
        let verts0 = renderer.debugAllSkinnedVertexPositions()
        guard let frame0Image = renderer.renderOffscreen(width: 256, height: 256) else {
            return XCTFail("renderOffscreen returned nil at frame 0")
        }
        let lastFrame = probe.animation.body.totalFrames - 1
        renderer.applySkeletalPose(skeleton: probe.skeleton, track: probe.animation.body, frameIndex: lastFrame)
        let vertsLast = renderer.debugAllSkinnedVertexPositions()
        guard let frameLastImage = renderer.renderOffscreen(width: 256, height: 256) else {
            return XCTFail("renderOffscreen returned nil at frame \(lastFrame)")
        }

        let verticesMoved = zip(verts0, vertsLast).filter { simd_distance($0, $1) > 0.0001 }.count
        print("DIAG: \(verticesMoved)/\(verts0.count) vertices moved between frame 0 and frame \(lastFrame)")
        XCTAssertGreaterThan(verticesMoved, verts0.count / 4, "fewer than a quarter of vertices moved — the skeletal deform isn't reaching the GPU buffer")

        let differingPixels = Self.countDifferingPixels(frame0Image, frameLastImage)
        XCTAssertGreaterThan(differingPixels, 0, "frame 0 and the last frame rendered pixel-identical — the skeletal deform isn't visibly doing anything")
    }

    private static func countDifferingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        guard let dataA = a.dataProvider?.data as Data?, let dataB = b.dataProvider?.data as Data?,
              a.width == b.width, a.height == b.height
        else { return -1 }
        let bytesPerPixel = 4
        let bytesPerRow = a.bytesPerRow
        var differing = 0
        let step = 4
        var y = 0
        while y < a.height {
            var x = 0
            while x < a.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < dataA.count, offset + 2 < dataB.count else { x += step; continue }
                if dataA[offset] != dataB[offset] || dataA[offset + 1] != dataB[offset + 1] || dataA[offset + 2] != dataB[offset + 2] {
                    differing += 1
                }
                x += step
            }
            y += step
        }
        return differing
    }
}

extension RealDiscDiagnosticTests {
    /// "Collision Mask Alignment" — real evidence this data exists and
    /// decodes to genuine, non-degenerate geometry, not just bytes that
    /// happen not to throw. A first hand-inspected sample looked like
    /// clean 8-corner axis-aligned boxes, but the full set found here
    /// includes other corner counts and some genuinely non-axis-aligned
    /// spreads too (probably oriented boxes, or a different shape this
    /// build doesn't have a confirmed interpretation for) — so this only
    /// asserts what's actually true of every sample: real, decoded,
    /// non-empty, non-degenerate coordinates, and that `collisionBoxEdges`
    /// (which just takes the overall min/max — a safe, honest
    /// "encompasses every point" box regardless of the source shape)
    /// produces a valid box for each one.
    func testGraphicsInfoCollisionDataDecodesToRealGeometry() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let entry = try XCTUnwrap(index.entries.first { $0.name == "Levels/Earth/Cavern/antfight.rm2" })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entry.name)
        let assetIndex = AssetResolver.buildIndex(fileRoot: root)

        let withCollisionData = assetIndex.skeletons.values.filter { !$0.collisionData.isEmpty }
        print("DIAG: \(assetIndex.skeletons.count) skeletons, \(withCollisionData.count) with non-empty collisionData")
        XCTAssertGreaterThan(withCollisionData.count, 0, "expected at least one real GraphicsInfo in this level to carry collision data")

        for skeleton in withCollisionData {
            for collisionEntry in skeleton.collisionData {
                XCTAssertGreaterThan(collisionEntry.positions.count, 0)
                let edges = ModelViewerRenderer.collisionBoxEdges(corners: collisionEntry.positions)
                XCTAssertEqual(edges.count, 12)
                // Every real value seen so far is small and finite (world-
                // scale local-space coordinates) — catches a byte-offset
                // parsing error reading garbage as huge/NaN floats, without
                // over-claiming a specific shape.
                for position in collisionEntry.positions {
                    XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
                    XCTAssertLessThan(simd_length(SIMD3(position.x, position.y, position.z)), 1000)
                }
            }
        }
    }

    /// "Chunk-Based Architecture" (Part 2) research pass — is `ChunkLinks`
    /// real, non-empty, sane data in actual `.SM2` chunk files, and what do
    /// real `path`/`flags` values look like? Exploratory: prints findings
    /// rather than asserting a specific shape up front, the same caution
    /// `testGraphicsInfoCollisionDataDecodesToRealGeometry`'s history is a
    /// reminder of (an 89-failure over-claim from a too-small sample).
    func testChunkLinksDecodeAcrossRealSM2Files() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let sm2Entries = index.entries.filter { $0.name.lowercased().hasSuffix(".sm2") }
        print("DIAG: \(sm2Entries.count) .sm2 entries in archive")
        XCTAssertGreaterThan(sm2Entries.count, 0, "expected at least one real .SM2 chunk file in this archive")

        var filesWithLinks = 0
        var totalLinks = 0
        var linksWithWall = 0
        var linksWithTree = 0
        var samplePaths: [String] = []
        var parseFailures = 0

        for entry in sm2Entries {
            guard let data = try? BDArchiveParser.readEntryData(entry, index: index),
                  let root = try? RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)
            else { parseFailures += 1; continue }

            func walk(_ node: ChunkNode) {
                if case .chunkLinks(let asset) = node.payload {
                    if !asset.links.isEmpty { filesWithLinks += 1 }
                    for link in asset.links {
                        totalLinks += 1
                        if link.hasWall { linksWithWall += 1 }
                        if link.hasTree { linksWithTree += 1 }
                        if samplePaths.count < 25 { samplePaths.append("\(entry.name) -> \(link.path) [type=\(link.type) flags=0x\(String(link.flags, radix: 16)) wall=\(link.hasWall) tree=\(link.treeNodes.count)]") }
                    }
                }
                for child in node.children { walk(child) }
            }
            walk(root)
        }

        print("DIAG: \(filesWithLinks)/\(sm2Entries.count) .sm2 files have non-empty ChunkLinks, \(totalLinks) total links, \(linksWithWall) with wall, \(linksWithTree) with tree, \(parseFailures) parse failures")
        for line in samplePaths { print("DIAG: \(line)") }

        // Confirmed findings, now asserted: real `.SM2` chunk files
        // overwhelmingly carry non-empty `ChunkLinks` (129/134 in a full
        // archive sweep), the boundary-wall flag is common, and every real
        // `path` seen looks like a genuine lowercase/backslash chunk file
        // reference (e.g. `levels\earth\cavern\tunnel01`) — never empty,
        // never containing stray null bytes from a misaligned read.
        XCTAssertEqual(parseFailures, 0, "ChunkLinks decoding broke structural parsing for at least one real .SM2 file")
        XCTAssertGreaterThan(filesWithLinks, sm2Entries.count / 2, "expected most real .SM2 chunk files to carry non-empty ChunkLinks")
        XCTAssertGreaterThan(linksWithWall, 0, "expected at least one real boundary wall in this archive")
        for line in samplePaths {
            XCTAssertFalse(line.contains("-> ["), "a link's path decoded as empty")
        }
    }

    /// "Load & Stitch" (Part 2) — does a real `ChunkLink.path` actually
    /// resolve to a real archive entry using the exact matching rule
    /// `WorkspaceViewModel.loadChunkLinkPlacements` uses (normalize `\` to
    /// `/`, append `.sm2` if missing, case-insensitive compare)? Real
    /// paths were confirmed lowercase/backslash-separated/no-extension by
    /// `testChunkLinksDecodeAcrossRealSM2Files`; this confirms the other
    /// half — that the resolution rule built from that observation
    /// actually finds the neighbor file in the same archive, not just that
    /// the string looks plausible.
    func testChunkLinkPathsResolveToRealArchiveEntries() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let entry = try XCTUnwrap(index.entries.first { $0.name == "Levels/Earth/Cavern/nitrocav.sm2" })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .sm2, fileName: entry.name)

        var links: [ChunkLink] = []
        func walk(_ node: ChunkNode) {
            if case .chunkLinks(let asset) = node.payload { links.append(contentsOf: asset.links) }
            for child in node.children { walk(child) }
        }
        walk(root)
        XCTAssertGreaterThan(links.count, 0, "nitrocav.sm2 should have real ChunkLinks — used in testChunkLinksDecodeAcrossRealSM2Files")

        var resolvedCount = 0
        for link in links {
            let normalizedPath = link.path.replacingOccurrences(of: "\\", with: "/")
            let targetName = normalizedPath.lowercased().hasSuffix(".sm2") ? normalizedPath : normalizedPath + ".sm2"
            let matched = index.entries.first { candidate in
                candidate.name.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(targetName) == .orderedSame
            }
            if matched != nil { resolvedCount += 1 } else {
                print("DIAG: unresolved chunk link path \"\(link.path)\" (target \"\(targetName)\")")
            }
        }
        print("DIAG: \(resolvedCount)/\(links.count) chunk link paths resolved to a real archive entry")
        XCTAssertEqual(resolvedCount, links.count, "every real ChunkLink in this file should resolve to a real neighboring .sm2 entry in the same archive")
    }

    /// "AgentLab Visual Node Graph" (roadmap 4.2) sanity check — real
    /// `CustomAgent` records actually exist in real level files, so the
    /// graph shell has real data to show rather than always being empty.
    func testCustomAgentRecordsExistInRealLevelFile() throws {
        let bhPath = "/Volumes/CRASH/CRASH6/CRASH.BH"
        guard FileManager.default.fileExists(atPath: bhPath) else {
            throw XCTSkip("Disc image not mounted")
        }
        let index = try BDArchiveParser.readIndex(bhURL: URL(fileURLWithPath: bhPath))
        let entry = try XCTUnwrap(index.entries.first { $0.name == "Levels/Earth/Hub/hubd.rm2" })
        let data = try BDArchiveParser.readEntryData(entry, index: index)
        let root = try RM2Parser.parse(data: data, fileKind: .rm2, fileName: entry.name)

        var customAgentSectionCount = 0
        var leafCount = 0
        func walk(_ node: ChunkNode) {
            if node.sectionType == .customAgent, !node.children.isEmpty {
                customAgentSectionCount += 1
                leafCount += node.children.count
            }
            for child in node.children { walk(child) }
        }
        walk(root)
        print("DIAG: \(customAgentSectionCount) CustomAgent section(s), \(leafCount) real agent records in hubd.rm2")
        XCTAssertGreaterThan(leafCount, 0, "expected at least one real CustomAgent record in this level")
    }
}
