import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

final class BDArchiveParserTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeSyntheticArchive(named base: String, entries: [(name: String, bytes: [UInt8])]) throws -> (bh: URL, bd: URL) {
        let bhURL = tempDir.appendingPathComponent("\(base).BH")
        let bdURL = tempDir.appendingPathComponent("\(base).BD")

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
        return (bhURL, bdURL)
    }

    func testCounterpartURLResolutionForAllCaseVariants() throws {
        let bhUpper = try BDArchiveParser.counterpartURL(for: URL(fileURLWithPath: "/tmp/Foo.BH"))
        XCTAssertEqual(bhUpper.bd.lastPathComponent, "Foo.BD")

        let bdLower = try BDArchiveParser.counterpartURL(for: URL(fileURLWithPath: "/tmp/foo.bd"))
        XCTAssertEqual(bdLower.bh.lastPathComponent, "foo.bh")

        let noExt = try BDArchiveParser.counterpartURL(for: URL(fileURLWithPath: "/tmp/foo"))
        XCTAssertEqual(noExt.bh.lastPathComponent, "foo.BH")
        XCTAssertEqual(noExt.bd.lastPathComponent, "foo.BD")
    }

    func testReadIndexParsesAllEntries() throws {
        let (bh, _) = try writeSyntheticArchive(named: "test1", entries: [
            ("readme.txt", Array("hello".utf8)),
            ("data/level.RM2", [1, 2, 3, 4, 5])
        ])
        let index = try BDArchiveParser.readIndex(bhURL: bh)
        XCTAssertEqual(index.entries.count, 2)
        XCTAssertEqual(index.entries[0].name, "readme.txt")
        XCTAssertEqual(index.entries[0].size, 5)
        XCTAssertEqual(index.entries[1].name, "data/level.RM2")
        XCTAssertEqual(index.entries[1].offset, 5)
        XCTAssertEqual(index.entries[1].size, 5)
    }

    func testReadEntryDataReturnsExactBytes() throws {
        let payload: [UInt8] = [10, 20, 30, 40, 50]
        let (bh, _) = try writeSyntheticArchive(named: "test2", entries: [("thing.bin", payload)])
        let index = try BDArchiveParser.readIndex(bhURL: bh)
        let data = try BDArchiveParser.readEntryData(index.entries[0], index: index)
        XCTAssertEqual([UInt8](data), payload)
    }

    func testExtractAllRecreatesDirectoryStructure() throws {
        let (bh, _) = try writeSyntheticArchive(named: "test3", entries: [
            ("nested/dir/file.txt", Array("contents".utf8))
        ])
        let index = try BDArchiveParser.readIndex(bhURL: bh)
        let outDir = tempDir.appendingPathComponent("extracted")
        try BDArchiveParser.extractAll(index: index, to: outDir)

        let extractedFile = outDir.appendingPathComponent("nested/dir/file.txt")
        let contents = try String(contentsOf: extractedFile, encoding: .utf8)
        XCTAssertEqual(contents, "contents")
    }

    func testExtractSelectedOnlyWritesNamedEntries() throws {
        let (bh, _) = try writeSyntheticArchive(named: "test3b", entries: [
            ("keep/this.txt", Array("kept".utf8)),
            ("skip/that.txt", Array("skipped".utf8))
        ])
        let index = try BDArchiveParser.readIndex(bhURL: bh)
        let outDir = tempDir.appendingPathComponent("extracted_selected")
        try BDArchiveParser.extractSelected(index: index, entryNames: ["keep/this.txt"], to: outDir)

        let keptContents = try String(contentsOf: outDir.appendingPathComponent("keep/this.txt"), encoding: .utf8)
        XCTAssertEqual(keptContents, "kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.appendingPathComponent("skip/that.txt").path))
    }

    func testExtractSelectedIgnoresUnknownNames() throws {
        let (bh, _) = try writeSyntheticArchive(named: "test3c", entries: [
            ("real.txt", Array("data".utf8))
        ])
        let index = try BDArchiveParser.readIndex(bhURL: bh)
        let outDir = tempDir.appendingPathComponent("extracted_unknown")
        XCTAssertNoThrow(try BDArchiveParser.extractSelected(index: index, entryNames: ["nonexistent.txt"], to: outDir))
    }

    func testCompileAllRoundTripsThroughReadIndex() throws {
        let sourceDir = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("top-level".utf8).write(to: sourceDir.appendingPathComponent("a.txt"))
        try Data("nested".utf8).write(to: sourceDir.appendingPathComponent("sub/b.txt"))

        let bhURL = tempDir.appendingPathComponent("rebuilt.BH")
        let bdURL = tempDir.appendingPathComponent("rebuilt.BD")
        try BDArchiveParser.compileAll(from: sourceDir, bhURL: bhURL, bdURL: bdURL)

        let index = try BDArchiveParser.readIndex(bhURL: bhURL)
        XCTAssertEqual(index.entries.count, 2)
        let names = Set(index.entries.map(\.name))
        XCTAssertTrue(names.contains("a.txt"))
        XCTAssertTrue(names.contains("sub/b.txt"))

        for entry in index.entries {
            let data = try BDArchiveParser.readEntryData(entry, index: index)
            let expected = entry.name == "a.txt" ? "top-level" : "nested"
            XCTAssertEqual(String(data: data, encoding: .utf8), expected)
        }
    }
}
