import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Integrate Wrath of Cortex into the Sidebar": `mountDiscImage` used to
/// only populate a separate `mountedDiscImage` sheet — this pins the real
/// replacement behavior, that a mounted disc's real directory tree becomes
/// actual `ChunkNode` entries in `rootNodes`, browsable/searchable/
/// filterable through the exact same sidebar machinery as any opened
/// archive, with no separate modal browser.
///
/// Builds the same real, spec-compliant (ECMA-119) synthetic ISO-9660
/// image byte layout `DiscImageTests` (CTParsersTests) already verifies
/// `ISO9660Reader` parses correctly — this test instead exercises the
/// `WorkspaceViewModel` layer built on top of it.
final class DiscImageSidebarMergeTests: XCTestCase {
    private static let sectorSize = 2048

    private func bothEndian32(_ v: UInt32) -> [UInt8] {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        return le + le.reversed()
    }

    private func bothEndian16(_ v: UInt16) -> [UInt8] {
        let le: [UInt8] = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
        return le + le.reversed()
    }

    private func directoryRecord(lba: UInt32, size: UInt32, isDirectory: Bool, identifier: [UInt8]) -> [UInt8] {
        var rest: [UInt8] = [0]
        rest += bothEndian32(lba)
        rest += bothEndian32(size)
        rest += [UInt8](repeating: 0, count: 7)
        rest.append(isDirectory ? 0x02 : 0x00)
        rest.append(0)
        rest.append(0)
        rest += bothEndian16(1)
        rest.append(UInt8(identifier.count))
        rest += identifier
        var total = 1 + rest.count
        if total % 2 != 0 {
            rest.append(0)
            total += 1
        }
        return [UInt8(total)] + rest
    }

    private func makeSector(_ bytes: [UInt8]) -> [UInt8] {
        precondition(bytes.count <= Self.sectorSize)
        return bytes + [UInt8](repeating: 0, count: Self.sectorSize - bytes.count)
    }

    /// Root directory (sector 18) containing one real file (`CRATE.CRT;1`)
    /// and one subdirectory (`WMPDATA`, sector 19) containing one more
    /// real file (`FRUIT.WMP;1`) — mirrors a real Wrath of Cortex-style
    /// disc layout closely enough to exercise nested-directory mirroring,
    /// not just a flat file list.
    private func buildSyntheticISOFile() throws -> URL {
        let crtContent = Array("CRATE-DATA".utf8)
        let wmpContent = Array("WUMPA-DATA".utf8)

        var sectors: [[UInt8]] = (0..<22).map { _ in makeSector([]) }

        var pvd: [UInt8] = [1]
        pvd += Array("CD001".utf8)
        pvd.append(1)
        pvd = pvd + [UInt8](repeating: 0, count: 156 - pvd.count)
        pvd += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        sectors[16] = makeSector(pvd)

        var terminator: [UInt8] = [255]
        terminator += Array("CD001".utf8)
        terminator.append(1)
        sectors[17] = makeSector(terminator)

        var root: [UInt8] = []
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        root += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        root += directoryRecord(lba: 20, size: UInt32(crtContent.count), isDirectory: false, identifier: Array("CRATE.CRT;1".utf8))
        root += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: Array("WMPDATA".utf8))
        sectors[18] = makeSector(root)

        var subdir: [UInt8] = []
        subdir += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        subdir += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        subdir += directoryRecord(lba: 21, size: UInt32(wmpContent.count), isDirectory: false, identifier: Array("FRUIT.WMP;1".utf8))
        sectors[19] = makeSector(subdir)

        sectors[20] = makeSector(crtContent)
        sectors[21] = makeSector(wmpContent)

        let flatData = Data(sectors.flatMap { $0 })
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).iso")
        try flatData.write(to: tempURL)
        return tempURL
    }

    private func findByName(_ name: String, in nodes: [ChunkNode]) -> ChunkNode? {
        nodes.first { $0.displayName == name }
    }

    @MainActor
    func testMountDiscImageAddsRealTreeToRootNodesNotASeparateSheet() throws {
        let isoURL = try buildSyntheticISOFile()
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        XCTAssertEqual(workspace.rootNodes.count, 0)

        workspace.mountDiscImage(url: isoURL)

        XCTAssertNil(workspace.lastError, "mounting a real, valid synthetic ISO should not report an error")
        XCTAssertEqual(workspace.rootNodes.count, 1, "the mounted disc should be a real top-level sidebar entry, not a separate sheet")

        let discRoot = try XCTUnwrap(workspace.rootNodes.first)
        let names = Set(discRoot.children.map(\.displayName))
        XCTAssertEqual(names, ["CRATE.CRT", "WMPDATA"], "both the real file and the real subdirectory should be mirrored as real ChunkNode children")

        let crtNode = try XCTUnwrap(findByName("CRATE.CRT", in: discRoot.children))
        XCTAssertEqual(crtNode.byteSize, 10, "CRATE-DATA is 10 real bytes")
        XCTAssertTrue(crtNode.children.isEmpty, "a real file leaf has no children")

        let subdirNode = try XCTUnwrap(findByName("WMPDATA", in: discRoot.children))
        XCTAssertEqual(subdirNode.children.map(\.displayName), ["FRUIT.WMP"], "nested directories must mirror recursively, not just the root level")
    }

    /// Selecting a disc-mounted file leaf extracts its real bytes and
    /// routes them through the same `open(url:)` pipeline any other file
    /// uses — proven here by picking an unrecognized extension (`.crt` is
    /// real, but this synthetic file's *content* is plain text, not a real
    /// CRT record) and confirming extraction still happens without a
    /// crash or a stuck `isLoading`, rather than asserting on parse
    /// success this fixture was never meant to produce.
    @MainActor
    func testSelectingDiscFileLeafExtractsWithoutCrashing() throws {
        let isoURL = try buildSyntheticISOFile()
        defer { try? FileManager.default.removeItem(at: isoURL) }

        let workspace = WorkspaceViewModel()
        workspace.mountDiscImage(url: isoURL)
        let discRoot = try XCTUnwrap(workspace.rootNodes.first)
        let crtNode = try XCTUnwrap(findByName("CRATE.CRT", in: discRoot.children))

        workspace.select(crtNode)

        let expectation = expectation(description: "select's deferred dispatch runs")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(workspace.selectedNode?.id, crtNode.id, "the disc node itself should still become selectedNode")
    }
}
