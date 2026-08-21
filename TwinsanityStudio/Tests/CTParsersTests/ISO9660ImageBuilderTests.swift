import XCTest
@testable import CTCore
@testable import CTParsers
@testable import CTModels

/// `ISO9660ImageBuilder` — builds a real ECMA-119 image from a directory
/// tree from scratch ("Image Maker" parity — see that type's own doc
/// comment for exactly what is and isn't independently verified here).
/// Every test round-trips the built image back through this package's own
/// `ISO9660Reader`, the same discipline every other writer in this
/// codebase is held to.
final class ISO9660ImageBuilderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func readBack(_ image: Data) throws -> ISO9660Entry {
        try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: image))
    }

    func testFlatDirectoryRoundTrips() throws {
        try Data("hello".utf8).write(to: tempDir.appendingPathComponent("A.TXT"))
        try Data("world!!".utf8).write(to: tempDir.appendingPathComponent("B.TXT"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "TWINSANITY")
        XCTAssertEqual(image.count % 2048, 0, "a real ISO-9660 image is always a whole number of sectors")

        let root = try readBack(image)
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.children.count, 2)

        let a = try XCTUnwrap(root.children.first { $0.name == "A.TXT" })
        XCTAssertFalse(a.isDirectory)
        let source = PlainISOSource(data: image)
        XCTAssertEqual(ISO9660Reader.readFile(a, from: source), Data("hello".utf8))

        let b = try XCTUnwrap(root.children.first { $0.name == "B.TXT" })
        XCTAssertEqual(ISO9660Reader.readFile(b, from: source), Data("world!!".utf8))
    }

    func testNestedDirectoriesRoundTrip() throws {
        let sub = tempDir.appendingPathComponent("EARTH")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let subsub = sub.appendingPathComponent("HUB")
        try FileManager.default.createDirectory(at: subsub, withIntermediateDirectories: true)
        try Data("beach level".utf8).write(to: subsub.appendingPathComponent("BEACH.RM2"))
        try Data("root file".utf8).write(to: tempDir.appendingPathComponent("SYSTEM.CNF"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "TEST")
        let root = try readBack(image)

        XCTAssertEqual(root.children.count, 2) // EARTH/ and SYSTEM.CNF
        let earth = try XCTUnwrap(root.children.first { $0.name == "EARTH" })
        XCTAssertTrue(earth.isDirectory)
        let hub = try XCTUnwrap(earth.children.first { $0.name == "HUB" })
        XCTAssertTrue(hub.isDirectory)
        let beach = try XCTUnwrap(hub.children.first { $0.name == "BEACH.RM2" })
        XCTAssertFalse(beach.isDirectory)

        let source = PlainISOSource(data: image)
        XCTAssertEqual(ISO9660Reader.readFile(beach, from: source), Data("beach level".utf8))

        let systemCNF = try XCTUnwrap(root.children.first { $0.name == "SYSTEM.CNF" })
        XCTAssertEqual(ISO9660Reader.readFile(systemCNF, from: source), Data("root file".utf8))
    }

    /// A file whose contents span more than one 2048-byte sector — proves
    /// `sectorCount(for:)`/file-extent placement handles multi-sector
    /// files, not just tiny fixtures.
    func testMultiSectorFileRoundTrips() throws {
        var bigData = Data()
        for i in 0..<5000 { bigData.append(UInt8(i % 256)) } // ~2.4 sectors
        try bigData.write(to: tempDir.appendingPathComponent("BIG.BIN"))

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "TEST")
        let root = try readBack(image)
        let big = try XCTUnwrap(root.children.first { $0.name == "BIG.BIN" })
        XCTAssertEqual(ISO9660Reader.readFile(big, from: PlainISOSource(data: image)), bigData)
    }

    /// A directory with enough children that its own extent spans more
    /// than one sector — exercises the "don't split a directory record
    /// across a sector boundary" placement logic on both the size-
    /// computation pass and the byte-emission pass.
    func testManyFilesForceMultiSectorDirectoryExtent() throws {
        var expectedNames: Set<String> = []
        for i in 0..<120 {
            let name = "FILE\(String(format: "%03d", i)).TXT"
            try Data("contents \(i)".utf8).write(to: tempDir.appendingPathComponent(name))
            expectedNames.insert(name)
        }

        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "MANY")
        let root = try readBack(image)
        XCTAssertEqual(root.children.count, 120)
        XCTAssertEqual(Set(root.children.map(\.name)), expectedNames)

        let source = PlainISOSource(data: image)
        let file50 = try XCTUnwrap(root.children.first { $0.name == "FILE050.TXT" })
        XCTAssertEqual(ISO9660Reader.readFile(file50, from: source), Data("contents 50".utf8))
    }

    func testEmptyDirectoryProducesAValidReadableImage() throws {
        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "EMPTY")
        let root = try readBack(image)
        XCTAssertTrue(root.isDirectory)
        XCTAssertTrue(root.children.isEmpty)
    }

    /// The Primary Volume Descriptor's own Volume Identifier field must
    /// actually carry the label the caller asked for — a real, directly
    /// checkable field this test reads straight from the image bytes
    /// (offset 40, 32 bytes, ECMA-119 8.4.14), since `ISO9660Reader`
    /// itself never surfaces this field.
    func testVolumeLabelIsWrittenToThePrimaryVolumeDescriptor() throws {
        let image = try ISO9660ImageBuilder.buildingImage(from: tempDir, volumeLabel: "MYDISC")
        let pvdStart = 16 * 2048
        let volumeID = image.subdata(in: (image.startIndex + pvdStart + 40)..<(image.startIndex + pvdStart + 40 + 6))
        XCTAssertEqual(String(data: volumeID, encoding: .ascii), "MYDISC")
    }
}
