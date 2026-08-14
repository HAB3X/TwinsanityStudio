import XCTest
@testable import CTParsers

/// "Native ISO & BIN/CUE Disc Image Mounting" (Task 7) — builds a real,
/// spec-compliant (ECMA-119) synthetic ISO-9660 image byte-for-byte (the
/// same "construct real bytes, verify the reader round-trips them"
/// discipline every other parser in this package is tested with) and
/// verifies `ISO9660Reader` parses it correctly, both as a plain `.iso`
/// and re-framed as raw `.bin`/`.cue` sectors.
final class DiscImageTests: XCTestCase {
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
        var rest: [UInt8] = [0] // Extended Attribute Record length
        rest += bothEndian32(lba)
        rest += bothEndian32(size)
        rest += [UInt8](repeating: 0, count: 7) // recording date/time
        rest.append(isDirectory ? 0x02 : 0x00) // file flags
        rest.append(0) // file unit size
        rest.append(0) // interleave gap size
        rest += bothEndian16(1) // volume sequence number
        rest.append(UInt8(identifier.count)) // LEN_FI
        rest += identifier
        var total = 1 + rest.count // +1 for the LEN_DR byte itself
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

    /// A real, minimal but spec-compliant ISO-9660 image:
    /// sectors 0-15 reserved, 16 = PVD, 17 = terminator, 18 = root
    /// directory (., .., TEST.TXT;1, SUBDIR), 19 = SUBDIR's own directory
    /// (., .., NESTED.TXT;1), 20 = TEST.TXT's real content, 21 =
    /// NESTED.TXT's real content.
    private func buildSyntheticISOSectors() -> [[UInt8]] {
        let testContent = Array("Hello, ISO 9660!".utf8)
        let nestedContent = Array("Nested file content.".utf8)

        var sectors: [[UInt8]] = (0..<22).map { _ in makeSector([]) }

        var pvd: [UInt8] = [1] // type = Primary Volume Descriptor
        pvd += Array("CD001".utf8)
        pvd.append(1) // version
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
        root += directoryRecord(lba: 20, size: UInt32(testContent.count), isDirectory: false, identifier: Array("TEST.TXT;1".utf8))
        root += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: Array("SUBDIR".utf8))
        sectors[18] = makeSector(root)

        var subdir: [UInt8] = []
        subdir += directoryRecord(lba: 19, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [0])
        subdir += directoryRecord(lba: 18, size: UInt32(Self.sectorSize), isDirectory: true, identifier: [1])
        subdir += directoryRecord(lba: 21, size: UInt32(nestedContent.count), isDirectory: false, identifier: Array("NESTED.TXT;1".utf8))
        sectors[19] = makeSector(subdir)

        sectors[20] = makeSector(testContent)
        sectors[21] = makeSector(nestedContent)

        return sectors
    }

    func testReadsRootDirectoryFromPlainISOImage() throws {
        let sectors = buildSyntheticISOSectors()
        let flatData = Data(sectors.flatMap { $0 })
        let source = PlainISOSource(data: flatData)

        let root = try ISO9660Reader.readRootDirectory(from: source)
        let names = Set(root.children.map(\.name))
        XCTAssertEqual(names, ["TEST.TXT", "SUBDIR"], "'.' and '..' must be skipped, and the real ;1 version suffix stripped")

        guard let testFile = root.children.first(where: { $0.name == "TEST.TXT" }) else {
            return XCTFail("TEST.TXT missing")
        }
        XCTAssertFalse(testFile.isDirectory)
        let content = ISO9660Reader.readFile(testFile, from: source)
        XCTAssertEqual(content.map { String(data: $0, encoding: .utf8) }, "Hello, ISO 9660!")

        guard let subdir = root.children.first(where: { $0.name == "SUBDIR" }) else {
            return XCTFail("SUBDIR missing")
        }
        XCTAssertTrue(subdir.isDirectory)
        XCTAssertEqual(subdir.children.map(\.name), ["NESTED.TXT"])
        let nestedContent = ISO9660Reader.readFile(subdir.children[0], from: source)
        XCTAssertEqual(nestedContent.map { String(data: $0, encoding: .utf8) }, "Nested file content.")
    }

    /// Same real logical content, re-framed as raw MODE1/2352 `.bin`
    /// sectors (arbitrary non-zero sync/header/ECC bytes surrounding each
    /// real 2048-byte payload, to prove the reader only ever looks at the
    /// real user-data offset and ignores the rest) — proves the whole
    /// real CueSheetParser -> BinCueLogicalSource -> ISO9660Reader
    /// pipeline round-trips identically to the plain-.iso path.
    func testReadsSameImageThroughBinCueMode1Framing() throws {
        let logicalSectors = buildSyntheticISOSectors()
        var rawBin: [UInt8] = []
        for sector in logicalSectors {
            rawBin += [UInt8](repeating: 0xAA, count: 16) // sync + header stand-in
            rawBin += sector
            rawBin += [UInt8](repeating: 0xBB, count: 2352 - 16 - Self.sectorSize) // EDC/zero/ECC stand-in
        }
        let binData = Data(rawBin)

        let cue = try CueSheetParser.parse(contents: "FILE \"disc.bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n")
        XCTAssertEqual(cue.binFileName, "disc.bin")
        XCTAssertEqual(cue.framing, .mode1_2352)

        let source = BinCueLogicalSource(binData: binData, framing: cue.framing)
        let root = try ISO9660Reader.readRootDirectory(from: source)
        guard let testFile = root.children.first(where: { $0.name == "TEST.TXT" }) else {
            return XCTFail("TEST.TXT missing through bin/cue framing")
        }
        let content = ISO9660Reader.readFile(testFile, from: source)
        XCTAssertEqual(content.map { String(data: $0, encoding: .utf8) }, "Hello, ISO 9660!")
    }

    func testCueParserRejectsUnsupportedTrackMode() {
        XCTAssertThrowsError(try CueSheetParser.parse(contents: "FILE \"disc.bin\" BINARY\nTRACK 01 MODE2/2336\n")) { error in
            XCTAssertEqual(error as? CueSheetParser.ParseError, .unsupportedTrackMode("MODE2/2336"))
        }
    }

    func testCueParserRequiresAFileLine() {
        XCTAssertThrowsError(try CueSheetParser.parse(contents: "TRACK 01 MODE1/2352\n")) { error in
            XCTAssertEqual(error as? CueSheetParser.ParseError, .missingFileLine)
        }
    }

    func testNonISOImageThrowsRatherThanReturningAnEmptyTree() {
        let garbage = Data(repeating: 0x42, count: 22 * Self.sectorSize)
        XCTAssertThrowsError(try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: garbage))) { error in
            XCTAssertEqual(error as? ISO9660Error, .notAnISO9660Image)
        }
    }

    // MARK: - ISO9660Writer

    func testReplaceFileInPlaceSameSizeUpdatesContentOnly() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        guard let testFile = root.children.first(where: { $0.name == "TEST.TXT" }) else { return XCTFail("TEST.TXT missing") }
        XCTAssertEqual(testFile.lba, 20)

        let replacement = Data("Goodbye ISO 9660".utf8)  // same length as "Hello, ISO 9660!" (16 bytes)
        XCTAssertEqual(replacement.count, 16)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertEqual(newImage.count, originalImage.count, "in-place same-size replacement must not change the image's total length")

        let newRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: newImage))
        let newTestFile = try XCTUnwrap(newRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(newTestFile.lba, 20, "same-size replacement must not relocate the file")
        XCTAssertEqual(ISO9660Reader.readFile(newTestFile, from: PlainISOSource(data: newImage)), replacement)

        // The sibling directory (SUBDIR/NESTED.TXT) must be completely untouched.
        let subdir = try XCTUnwrap(newRoot.children.first(where: { $0.name == "SUBDIR" }))
        let nested = try XCTUnwrap(subdir.children.first(where: { $0.name == "NESTED.TXT" }))
        XCTAssertEqual(ISO9660Reader.readFile(nested, from: PlainISOSource(data: newImage)).map { String(data: $0, encoding: .utf8) }, "Nested file content.")
    }

    func testReplaceFileInPlaceSmallerPadsAndShrinksSizeField() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        let replacement = Data("Hi".utf8)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertEqual(newImage.count, originalImage.count, "still fits inside the originally-reserved single sector")

        let newRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: newImage))
        let newTestFile = try XCTUnwrap(newRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertEqual(newTestFile.size, 2, "the directory record's size field must shrink to the real new content length, not the zero-padded sector size")
        XCTAssertEqual(ISO9660Reader.readFile(newTestFile, from: PlainISOSource(data: newImage)), replacement)
    }

    func testReplaceFileLargerAppendsPastEndAndRelocates() throws {
        let sectors = buildSyntheticISOSectors()
        let originalImage = Data(sectors.flatMap { $0 })
        let root = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: originalImage))
        let testFile = try XCTUnwrap(root.children.first(where: { $0.name == "TEST.TXT" }))

        // Larger than the single sector TEST.TXT originally occupied.
        let replacement = Data(repeating: 0x58, count: Self.sectorSize + 500)
        let newImage = try ISO9660Writer.replacingFile(testFile, with: replacement, in: originalImage)
        XCTAssertGreaterThan(newImage.count, originalImage.count, "must grow the image to fit the relocated file")

        let newRoot = try ISO9660Reader.readRootDirectory(from: PlainISOSource(data: newImage))
        let newTestFile = try XCTUnwrap(newRoot.children.first(where: { $0.name == "TEST.TXT" }))
        XCTAssertGreaterThanOrEqual(newTestFile.lba, 22, "must relocate past the original image's own sectors")
        XCTAssertEqual(newTestFile.size, UInt32(replacement.count))
        XCTAssertEqual(ISO9660Reader.readFile(newTestFile, from: PlainISOSource(data: newImage)), replacement)

        // The sibling directory (SUBDIR/NESTED.TXT, at the old LBAs) must still read correctly.
        let subdir = try XCTUnwrap(newRoot.children.first(where: { $0.name == "SUBDIR" }))
        let nested = try XCTUnwrap(subdir.children.first(where: { $0.name == "NESTED.TXT" }))
        XCTAssertEqual(ISO9660Reader.readFile(nested, from: PlainISOSource(data: newImage)).map { String(data: $0, encoding: .utf8) }, "Nested file content.")
    }

    func testReplaceFileThrowsWhenEntryDoesntFitTheSuppliedImage() {
        let bogusEntry = ISO9660Entry(name: "GHOST.TXT", isDirectory: false, lba: 999, size: 4, directoryRecordAbsoluteOffset: 999_999)
        let tinyImage = Data(repeating: 0, count: Self.sectorSize)
        XCTAssertThrowsError(try ISO9660Writer.replacingFile(bogusEntry, with: Data("x".utf8), in: tinyImage)) { error in
            XCTAssertEqual(error as? ISO9660WriterError, .entryOutOfBounds)
        }
    }
}
