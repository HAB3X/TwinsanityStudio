import XCTest
import CTCore
import CTModels
import CTParsers
@testable import CTExport

final class ArchiveRepackagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSyntheticArchive(entries: [(name: String, bytes: [UInt8])]) throws -> ArchiveIndex {
        let bhURL = tempDir.appendingPathComponent("orig.BH")
        let bdURL = tempDir.appendingPathComponent("orig.BD")
        var bh = BinaryWriter()
        bh.writeInt32(0x501)
        var bd = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            bh.writeInt32(Int32(nameBytes.count))
            bh.writeBytes(nameBytes)
            bh.writeUInt32(UInt32(bd.count))
            bh.writeUInt32(UInt32(entry.bytes.count))
            bd.append(contentsOf: entry.bytes)
        }
        try bh.data.write(to: bhURL)
        try bd.write(to: bdURL)
        return try BDArchiveParser.readIndex(bhURL: bhURL)
    }

    func testReplacesNamedEntryAndPreservesOthersUnchanged() throws {
        let index = try writeSyntheticArchive(entries: [
            ("keep.txt", Array("original".utf8)),
            ("swap.txt", Array("old-data".utf8))
        ])

        let newBH = tempDir.appendingPathComponent("out.BH")
        let newBD = tempDir.appendingPathComponent("out.BD")
        try ArchiveRepackager.repackage(
            index: index,
            replacements: ["swap.txt": Data("NEW-DATA!!".utf8)],
            outputBH: newBH,
            outputBD: newBD
        )

        let rebuilt = try BDArchiveParser.readIndex(bhURL: newBH)
        XCTAssertEqual(rebuilt.entries.count, 2)

        let keep = try XCTUnwrap(rebuilt.entries.first { $0.name == "keep.txt" })
        XCTAssertEqual(String(data: try BDArchiveParser.readEntryData(keep, index: rebuilt), encoding: .utf8), "original")

        let swap = try XCTUnwrap(rebuilt.entries.first { $0.name == "swap.txt" })
        XCTAssertEqual(String(data: try BDArchiveParser.readEntryData(swap, index: rebuilt), encoding: .utf8), "NEW-DATA!!")
    }

    func testAppendsNewEntriesNotPresentInOriginal() throws {
        let index = try writeSyntheticArchive(entries: [("a.txt", Array("a".utf8))])
        let newBH = tempDir.appendingPathComponent("out2.BH")
        let newBD = tempDir.appendingPathComponent("out2.BD")
        try ArchiveRepackager.repackage(index: index, replacements: ["b.txt": Data("b".utf8)], outputBH: newBH, outputBD: newBD)

        let rebuilt = try BDArchiveParser.readIndex(bhURL: newBH)
        XCTAssertEqual(Set(rebuilt.entries.map(\.name)), ["a.txt", "b.txt"])
    }

    func testRefusesToOverwriteExistingOutput() throws {
        let index = try writeSyntheticArchive(entries: [("a.txt", [1])])
        let newBH = tempDir.appendingPathComponent("out3.BH")
        let newBD = tempDir.appendingPathComponent("out3.BD")
        try Data().write(to: newBH)
        XCTAssertThrowsError(try ArchiveRepackager.repackage(index: index, replacements: [:], outputBH: newBH, outputBD: newBD))
    }
}
