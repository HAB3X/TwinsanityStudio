import XCTest
@testable import CTCore
@testable import CTModels
@testable import CTParsers
@testable import CTStudioApp

/// "Save Level Overrides…" (Part 4D), exercised through the real,
/// self-contained flow a user actually drives — `WorkspaceViewModel.
/// open(url:)` on a real `.rm2` file on disk, then `patchedFileBytes(
/// applyingPrefixPatches:insertingNewInstances:levelNode:)` — rather than
/// calling `ChunkSectionInserter` directly (already covered by
/// `ChunkSectionInserterTests`). This is specifically checking the glue:
/// finding the right file root and `.objectInstance` collection from a
/// node the workspace actually produced, not synthetic fixtures.
@MainActor
final class LevelInsertionIntegrationTests: XCTestCase {
    private func makeSection(children: [(id: UInt32, bytes: Data)]) -> Data {
        var writer = BinaryWriter()
        writer.writeUInt32(TwinsMagic.v1)
        writer.writeInt32(Int32(children.count))
        let contentSize = children.reduce(0) { $0 + $1.bytes.count }
        writer.writeUInt32(UInt32(contentSize))
        var offset = 12 + children.count * 12
        for child in children {
            writer.writeUInt32(UInt32(offset))
            writer.writeInt32(Int32(child.bytes.count))
            writer.writeUInt32(child.id)
            offset += child.bytes.count
        }
        for child in children {
            writer.writeBytes(child.bytes)
        }
        return writer.data
    }

    private func findFirst(_ node: ChunkNode, sectionType: SectionType) -> ChunkNode? {
        if node.sectionType == sectionType { return node }
        for child in node.children {
            if let found = findFirst(child, sectionType: sectionType) { return found }
        }
        return nil
    }

    func testSaveLevelOverridesInsertsNewInstanceThroughRealWorkspaceFlow() throws {
        let originalInstance = WorldPlacementWriter.writeNewInstance(objectID: 3, position: SIMD4<Float>(1, 2, 3, 1), rotationDegrees: .zero)
        let objectInstanceCollection = makeSection(children: [(id: 100, bytes: originalInstance)])
        let instanceContainer = makeSection(children: [(id: 6, bytes: objectInstanceCollection)])
        // `WorkspaceViewModel.findFileRoot` recognizes a file root by its
        // having a direct `.graphics`/`.code`-family child — a real .rm2
        // always has both; this fixture only needs the empty `.code`
        // section (top-level id 10) to satisfy that check.
        let emptyCodeSection = makeSection(children: [])
        let fileBytes = makeSection(children: [(id: 0, bytes: instanceContainer), (id: 10, bytes: emptyCodeSection)])

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID().uuidString).rm2")
        try fileBytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let workspace = WorkspaceViewModel()
        workspace.open(url: tempURL)
        XCTAssertEqual(workspace.rootNodes.count, 1, "a standalone .rm2 open should be synchronous — no scan/wait needed")

        let fileRoot = try XCTUnwrap(workspace.rootNodes.first)
        let instanceLeaf = try XCTUnwrap(findFirst(fileRoot, sectionType: .objectInstance)?.children.first)
        XCTAssertTrue(workspace.canSaveEdits(for: instanceLeaf), "a standalone-opened file should report as save-able")

        let newRecord = WorldPlacementWriter.writeNewInstance(objectID: 77, position: SIMD4<Float>(5, 5, 5, 1), rotationDegrees: .zero)
        let patched = try XCTUnwrap(workspace.patchedFileBytes(
            applyingPrefixPatches: [],
            insertingNewInstances: [(id: 999, encoded: newRecord)],
            levelNode: instanceLeaf
        ))

        let reparsed = try RM2Parser.parse(data: patched, fileKind: .rm2, fileName: "synthetic.rm2")
        let reparsedCollection = try XCTUnwrap(findFirst(reparsed, sectionType: .objectInstance))
        XCTAssertEqual(reparsedCollection.children.count, 2)

        guard case .instance(let original)? = reparsedCollection.children.first(where: { $0.recordID == 100 })?.payload else {
            return XCTFail("pre-existing instance record didn't survive a save with no transform edits")
        }
        XCTAssertEqual(original.objectID, 3)

        guard case .instance(let inserted)? = reparsedCollection.children.first(where: { $0.recordID == 999 })?.payload else {
            return XCTFail("newly inserted record didn't decode after going through the real WorkspaceViewModel save path")
        }
        XCTAssertEqual(inserted.objectID, 77)
        XCTAssertEqual(inserted.position, SIMD4<Float>(5, 5, 5, 1))
    }
}
