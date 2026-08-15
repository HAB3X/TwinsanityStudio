import XCTest
import Foundation
@testable import CTParsers

final class WOCContainerParserTests: XCTestCase {
    private func synthSection(tag: String, payload: [UInt8]) -> [UInt8] {
        var bytes = Array(tag.utf8)
        let length = UInt32(8 + payload.count)
        bytes.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Array($0) })
        bytes.append(contentsOf: payload)
        return bytes
    }

    func testParsesSyntheticSectionChain() throws {
        var bytes = Array("NU20".utf8)
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(0xFFFFFFFF).littleEndian) { Array($0) }) // negatedByteCount, unchecked
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(6).littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        bytes.append(contentsOf: synthSection(tag: "AAA0", payload: [1, 2, 3, 4]))
        bytes.append(contentsOf: synthSection(tag: "BBB0", payload: [5, 6]))

        let file = try WOCContainerParser.parse(bytes)
        XCTAssertEqual(file.formatVersion, 6)
        XCTAssertEqual(file.reserved, 0)
        XCTAssertEqual(file.sections.count, 2)
        XCTAssertEqual(file.sections[0].tag, "AAA0")
        XCTAssertEqual([UInt8](file.sections[0].payload), [1, 2, 3, 4])
        XCTAssertEqual(file.sections[1].tag, "BBB0")
        XCTAssertEqual([UInt8](file.sections[1].payload), [5, 6])
    }

    func testStopsChainAtNonTagBytesRatherThanThrowing() throws {
        var bytes = Array("NU20".utf8)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 12))
        bytes.append(contentsOf: synthSection(tag: "AAA0", payload: [1]))
        bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x03, 0x00, 0x00, 0x00, 0x00]) // not a valid 4-char ASCII tag, but a full 8 bytes

        let file = try WOCContainerParser.parse(bytes)
        XCTAssertEqual(file.sections.count, 1)
    }

    func testRejectsBadMagic() {
        let bytes = Array("XXXX".utf8) + [UInt8](repeating: 0, count: 12)
        XCTAssertThrowsError(try WOCContainerParser.parse(bytes)) { error in
            XCTAssertEqual(error as? WOCContainerParser.ParseError, .badMagic)
        }
    }

    func testParsesNameTablePayload() throws {
        let names = "target_red\0target_red_a\0cannon\0".utf8.map { $0 }
        var payload = withUnsafeBytes(of: UInt32(names.count).littleEndian) { Array($0) }
        payload.append(contentsOf: names)
        payload.append(contentsOf: [0xAA, 0xBB, 0xCC]) // unparsed trailer

        let (parsedNames, trailer) = try WOCContainerParser.parseNameTable(Data(payload))
        XCTAssertEqual(parsedNames, ["target_red", "target_red_a", "cannon"])
        XCTAssertEqual([UInt8](trailer), [0xAA, 0xBB, 0xCC])
    }

    // MARK: - Real WoC disc data

    /// Real WoC .GSC files, decompressed via `RNCDecompressor`, walked as a
    /// real-data regression for `WOCContainerParser`: confirms the section
    /// chain accounts for exactly 100% of the decompressed byte count with
    /// no gaps, and that `NTBL`'s declared string-blob length matches its
    /// actual decoded names -- both were verified by hand against a real
    /// disc image before being written as fixed test assertions (see
    /// `WOCContainerParser`'s doc comment for how these were derived).
    private static let discLevelsRoot = "/Volumes/CRASH/LEVELS"

    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "\(Self.discLevelsRoot)/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted at \(Self.discLevelsRoot) -- mount Games Files/PS2 FILES/Crash Bandicoot - The Wrath of Cortex .../*[ISO9660].iso via `hdiutil attach` to run this test")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    func testRealAirshipGSCSectionChainCoversWholeFile() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)

        XCTAssertEqual(file.formatVersion, 6)
        XCTAssertEqual(file.reserved, 0)
        XCTAssertEqual(file.negatedByteCount, UInt32((UInt64(0x1_0000_0000) - UInt64(decoded.count)) & 0xFFFF_FFFF))

        let tags = file.sections.map(\.tag)
        XCTAssertEqual(tags, ["NTBL", "TST0", "MS00", "OBJ0", "INST", "SPEC", "SST0"])

        let consumed = 16 + file.sections.reduce(0) { $0 + Int($1.length) }
        XCTAssertEqual(consumed, decoded.count, "section chain should account for every byte of the decompressed file")
    }

    func testRealAirshipGSCNameTable() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let ntbl = try XCTUnwrap(file.sections.first { $0.tag == "NTBL" })
        let (names, _) = try WOCContainerParser.parseNameTable(ntbl.payload)
        XCTAssertEqual(names, ["target_red", "target_red_a", "target_white", "target_white_a", "cannon"])
    }

    func testRealMS00RecordWidthIsConsistentAcrossLevels() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", 57),
            ("A/FARM/FARM.GSC", 69),
            ("A/CASTLE_C/CASTLE_C.GSC", 89),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let ms00 = try XCTUnwrap(file.sections.first { $0.tag == "MS00" }, "no MS00 in \(sample.path)")
            let (records, width) = try WOCContainerParser.parseMeshSet(ms00.payload)
            XCTAssertEqual(records.count, sample.expectedCount, "record count for \(sample.path)")
            XCTAssertEqual(width, 464, "record width for \(sample.path)")
        }
    }

    func testRealINSTInstancesHaveSelfConsistentIndicesAndPlausibleTransforms() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", 41),
            ("A/FARM/FARM.GSC", 523),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST in \(sample.path)")
            let instances = try WOCContainerParser.parseInstances(inst.payload)
            XCTAssertEqual(instances.count, sample.expectedCount, "instance count for \(sample.path)")
            for (i, instance) in instances.enumerated() {
                XCTAssertEqual(instance.index, UInt32(i), "instance \(i) index field should equal its own array position, for \(sample.path)")
                XCTAssertEqual(instance.matrix.15, 1.0, "homogeneous w should be 1.0 for instance \(i) in \(sample.path)")
                XCTAssertEqual(instance.unknownTail2, 0, "unknownTail2 for \(sample.path) instance \(i)")
            }
            // unknownTail1 is NOT always zero (verified: don't assert it is) --
            // it's zero for the vast majority of real instances but a real
            // minority carry a nonzero, pointer-shaped value.
        }
    }

    /// Golden-value regression for `parseVertexQuadwords`: the first few
    /// quadwords of `OBJ0`'s first entry in the real `AIRSHIP.GSC`,
    /// hand-derived from the raw disc bytes (see `WOCContainerParser`'s
    /// doc comment for how this region was found and visually confirmed
    /// to be a real curved-surface vertex strip, not noise).
    func testRealOBJ0FirstEntryVertexQuadwords() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })

        // Entry 0 starts right after OBJ0's own count(u32)+pad(u32) header;
        // its vertex-quadword block was found to start at byte 168 within
        // the entry (i.e. byte offset 8 + 168 = 176 into OBJ0's payload).
        let quadwords = try WOCContainerParser.parseVertexQuadwords(obj0.payload, byteOffset: 8 + 168, count: 3)

        XCTAssertEqual(quadwords.count, 3)
        XCTAssertEqual(quadwords[0].position.x, 0.08512221, accuracy: 0.0001)
        XCTAssertEqual(quadwords[0].position.y, -0.09876884, accuracy: 0.0001)
        XCTAssertEqual(quadwords[0].position.z, 0.09516593, accuracy: 0.0001)
        XCTAssertEqual(quadwords[1].position.x, 0.08734421, accuracy: 0.0001)
        XCTAssertEqual(quadwords[1].position.y, -0.09876884, accuracy: 0.0001)
        XCTAssertEqual(quadwords[1].position.z, 0.09080503, accuracy: 0.0001)
        XCTAssertEqual(quadwords[2].position.x, 0.07061075, accuracy: 0.0001)
        XCTAssertEqual(quadwords[2].position.y, -0.09510566, accuracy: 0.0001)
        XCTAssertEqual(quadwords[2].position.z, 0.09045087, accuracy: 0.0001)
    }

    func testRealCastleCGSCSectionChainCoversWholeFile() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)

        // CASTLE_C additionally has TAS0 and IABL/ALIB, absent from AIRSHIP --
        // confirming the section set genuinely varies per level rather than
        // AIRSHIP's chain being the universal one.
        let tags = file.sections.map(\.tag)
        XCTAssertEqual(tags, ["NTBL", "TST0", "MS00", "TAS0", "OBJ0", "INST", "IABL", "ALIB", "SPEC", "SST0"])

        let consumed = 16 + file.sections.reduce(0) { $0 + Int($1.length) }
        XCTAssertEqual(consumed, decoded.count)
    }
}
