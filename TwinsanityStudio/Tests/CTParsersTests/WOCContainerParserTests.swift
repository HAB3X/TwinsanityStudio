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

    func testRealINSTInstancesHavePlausibleTransforms() throws {
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
                XCTAssertEqual(instance.matrix.15, 1.0, "homogeneous w should be 1.0 for instance \(i) in \(sample.path)")
                XCTAssertEqual(instance.unknownTail2, 0, "unknownTail2 for \(sample.path) instance \(i)")
            }
            // unknownTail1 is NOT always zero (verified: don't assert it is) --
            // it's zero for the vast majority of real instances but a real
            // minority carry a nonzero, pointer-shaped value.
        }
    }

    /// The definitive real-data test for `Instance.objectIndex`: a broad
    /// sweep (see `WOCContainerParser`'s doc comment) found that an
    /// earlier, narrower 2-file check had accidentally verified the WRONG
    /// property (that this field equals the instance's own array
    /// position) -- true only because those 2 small files happen to place
    /// every object exactly once. `CASTLE_A.GSC` is a real file with heavy
    /// prop reuse (2111 instances, only 408 distinct objects) where the
    /// old property is false for the overwhelming majority of instances,
    /// but the real property -- every value is a valid `OBJ0` index, and
    /// the set of distinct values is exactly `0..<OBJ0.count` -- still
    /// holds exactly.
    func testRealINSTObjectIndexIsExactlyTheOBJ0IndexRange() throws {
        let samples = ["A/AIRSHIP/AIRSHIP.GSC", "A/FARM/FARM.GSC", "A/CASTLE_A/CASTLE_A.GSC"]
        for path in samples {
            let decoded = try loadAndDecompressRealGSC(path)
            let file = try WOCContainerParser.parse(decoded)
            let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" }, "no OBJ0 in \(path)")
            let obj0Count = try WOCContainerParser.leadingCount(obj0.payload)
            let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST in \(path)")
            let instances = try WOCContainerParser.parseInstances(inst.payload)

            let distinctIndices = Set(instances.map(\.objectIndex))
            XCTAssertEqual(distinctIndices, Set(0..<UInt32(obj0Count)), "objectIndex values should exactly cover 0..<OBJ0.count for \(path)")
            XCTAssertTrue(instances.allSatisfy { $0.objectIndex < UInt32(obj0Count) }, "no objectIndex should be out of OBJ0's bounds for \(path)")
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

    func testRealIABLRecordWidthIsConsistentAcrossLevels() throws {
        let samples: [(path: String, expectedCount: Int)] = [
            ("A/FARM/FARM.GSC", 21),
            ("A/CASTLE_C/CASTLE_C.GSC", 163),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let iabl = try XCTUnwrap(file.sections.first { $0.tag == "IABL" }, "no IABL in \(sample.path)")
            let records = try WOCContainerParser.parseAttributeBlock(iabl.payload)
            XCTAssertEqual(records.count, sample.expectedCount, "record count for \(sample.path)")
            for record in records {
                XCTAssertEqual(record.rawBytes.count, 96, "record width for \(sample.path)")
            }
        }
    }

    /// Independently re-verified (not just trusting the agent report that
    /// found this) on `DROID.GSC`: `ALIB`'s zero-sentinel record and
    /// `IABL`'s alibIndex cross-reference agree exactly -- the one ALIB
    /// index no IABL record ever points at is exactly the one ALIB record
    /// with a zero-offset (empty) sentinel.
    func testRealALIBZeroSentinelMatchesIABLUnreferencedIndex() throws {
        let path = "A/DROID/DROID.GSC"
        let decoded = try loadAndDecompressRealGSC(path)
        let file = try WOCContainerParser.parse(decoded)
        let alib = try XCTUnwrap(file.sections.first { $0.tag == "ALIB" })
        let iabl = try XCTUnwrap(file.sections.first { $0.tag == "IABL" })

        let alibRecords = try WOCContainerParser.parseAttributeLibrary(alib.payload)
        let iablRecords = try WOCContainerParser.parseAttributeBlock(iabl.payload)

        XCTAssertEqual(alibRecords.count, 10)
        let emptyIndices = Set(alibRecords.enumerated().filter { $0.element.isEmpty }.map { $0.offset })
        XCTAssertEqual(emptyIndices, [6])

        for record in iablRecords {
            XCTAssertLessThan(Int(record.alibIndex), alibRecords.count, "IABL alibIndex should be in-bounds")
        }
        let referenced = Set(iablRecords.map { Int($0.alibIndex) })
        let unreferenced = Set(0..<alibRecords.count).subtracting(referenced)
        XCTAssertEqual(unreferenced, emptyIndices, "ALIB's empty-sentinel records should exactly match IABL's unreferenced indices")
    }

    /// Confirmed by an independent spot-check before shipping (this
    /// project's discipline: verify even agent-reported findings): `SPEC`
    /// is a curated, strictly-ascending pointer-list into `INST`, and each
    /// `SPEC` record's transform matrix is byte-for-byte identical to the
    /// `INST` record it references.
    func testRealSPECReferencesINSTWithByteIdenticalMatrices() throws {
        let samples = ["A/AIRSHIP/AIRSHIP.GSC", "A/FARM/FARM.GSC", "A/JUNGLE_A/JUNGLE_A.GSC"]
        for path in samples {
            let decoded = try loadAndDecompressRealGSC(path)
            let file = try WOCContainerParser.parse(decoded)
            let spec = try XCTUnwrap(file.sections.first { $0.tag == "SPEC" }, "no SPEC in \(path)")
            let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" }, "no INST in \(path)")
            let specRecords = try WOCContainerParser.parseSpecRecords(spec.payload)
            let instances = try WOCContainerParser.parseInstances(inst.payload)
            XCTAssertFalse(specRecords.isEmpty, "expected nonempty SPEC in \(path)")

            var previousIndex: Int64 = -1
            for record in specRecords {
                let refIndex = Int(record.referencedInstanceIndex)
                XCTAssertGreaterThan(Int64(refIndex), previousIndex, "SPEC referencedInstanceIndex should be strictly increasing in \(path)")
                previousIndex = Int64(refIndex)
                XCTAssertLessThan(refIndex, instances.count, "SPEC should reference a valid INST index in \(path)")
                let referenced = instances[refIndex]
                XCTAssertTrue(matricesEqual(record.matrix, referenced.matrix), "SPEC record's matrix should byte-match INST[\(refIndex)] in \(path)")
            }
        }
    }

    private func matricesEqual(
        _ a: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float),
        _ b: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
    ) -> Bool {
        a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3 &&
        a.4 == b.4 && a.5 == b.5 && a.6 == b.6 && a.7 == b.7 &&
        a.8 == b.8 && a.9 == b.9 && a.10 == b.10 && a.11 == b.11 &&
        a.12 == b.12 && a.13 == b.13 && a.14 == b.14 && a.15 == b.15
    }

    /// `TST0` turned out to be a completely different kind of structure
    /// from every other section: a serialized PS2 Graphics Synthesizer
    /// texture-upload command stream, not a record table. This pins the
    /// first real texture entry found in `AIRSHIP.GSC` by the scan.
    func testRealTST0FirstTextureEntry() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let entries = WOCContainerParser.scanTextureEntries(tst0.payload)

        // The scan is a heuristic (documented as such), not guaranteed to
        // find every texture the section's leading count field declares --
        // but every entry it DOES find must be internally consistent.
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertGreaterThan(entry.width, 0)
            XCTAssertGreaterThan(entry.height, 0)
            XCTAssertEqual(entry.texelDataRange.count, entry.width * entry.height * entry.bytesPerPixel)
        }

        let first = entries[0]
        XCTAssertEqual(first.width, 128)
        XCTAssertEqual(first.height, 64)
        XCTAssertEqual(first.bytesPerPixel, 4)
        XCTAssertEqual(first.texelDataRange.count, 32768)
    }

    /// `SST0` is always the last section (a footer). Confirmed here: its
    /// outer blob-length field correctly splits the payload, and in
    /// files that have the 12-byte trailer variant, the trailer's last
    /// field echoes this section's own outer container length back.
    func testRealSST0FooterEchoesOwnSectionLength() throws {
        let decoded = try loadAndDecompressRealGSC("A/FARM/FARM.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let sst0 = try XCTUnwrap(file.sections.first { $0.tag == "SST0" })
        let (_, _, trailer) = try WOCContainerParser.parseFooterHeader(sst0.payload)
        XCTAssertEqual(trailer.count, 12)
        let echoedLength = trailer.suffix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(echoedLength, sst0.length, "SST0 trailer should echo its own section length")
    }

    /// Real-data regression for `obj0ChunkLength`: walking AIRSHIP.GSC's
    /// entire OBJ0 payload with the confirmed `chunkLength == lengthField
    /// + 128` formula, locating each chunk by scanning forward for the
    /// recurring `0x6C010056` marker, consumes the payload EXACTLY --
    /// 222 chunks, zero drift. (This exact naive-scan walk is known NOT
    /// to be safe on other files -- see `obj0ChunkLength`'s doc comment --
    /// so this test intentionally only covers the one file where it's
    /// confirmed clean, rather than a broader sweep that would fail.)
    /// The validated `walkOBJ0Chunks` covers AIRSHIP.GSC exactly and gets
    /// very close (>99.9%) on 3 other real files of very different sizes
    /// -- unlike the naive marker scan this replaced, which diverged
    /// catastrophically on 2 of these same files (see `walkOBJ0Chunks`'s
    /// doc comment for that story).
    func testRealOBJ0ChunkWalkCoversMultipleFilesNearlyExactly() throws {
        let samples: [(path: String, expectedChunks: Int, minCoverageFraction: Double)] = [
            ("A/AIRSHIP/AIRSHIP.GSC", 222, 1.0),
            ("A/FARM/FARM.GSC", 745, 0.999),
            ("A/CASTLE_C/CASTLE_C.GSC", 1975, 0.999),
        ]
        for sample in samples {
            let decoded = try loadAndDecompressRealGSC(sample.path)
            let file = try WOCContainerParser.parse(decoded)
            let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
            let chunks = WOCContainerParser.walkOBJ0Chunks(obj0.payload)
            XCTAssertEqual(chunks.count, sample.expectedChunks, "chunk count for \(sample.path)")
            let covered = chunks.reduce(0) { $0 + $1.length }
            let fraction = Double(8 + covered) / Double(obj0.payload.count)
            XCTAssertGreaterThanOrEqual(fraction, sample.minCoverageFraction, "coverage fraction for \(sample.path)")
        }
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

    /// End-to-end regression: decompress a real WoC level and decode every
    /// section this module currently understands, checking that they
    /// agree with each other exactly where they're supposed to (NTBL
    /// names, MS00/IABL/INST/SPEC record counts, the INST<->OBJ0 index
    /// relationship, SPEC<->INST matrix identity, and a real texture).
    /// This is the safety net for the whole pipeline: if any single piece
    /// regresses, this test is the one most likely to catch it, since it
    /// exercises them all together against one real file rather than in
    /// isolation.
    func testRealAirshipGSCFullPipelineIsInternallyConsistent() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        XCTAssertEqual(file.sections.map(\.tag), ["NTBL", "TST0", "MS00", "OBJ0", "INST", "SPEC", "SST0"])

        let ntbl = try XCTUnwrap(file.sections.first { $0.tag == "NTBL" })
        let (names, _) = try WOCContainerParser.parseNameTable(ntbl.payload)
        XCTAssertEqual(names, ["target_red", "target_red_a", "target_white", "target_white_a", "cannon"])

        let ms00 = try XCTUnwrap(file.sections.first { $0.tag == "MS00" })
        let (ms00Records, ms00Width) = try WOCContainerParser.parseMeshSet(ms00.payload)
        XCTAssertEqual(ms00Records.count, 57)
        XCTAssertEqual(ms00Width, 464)

        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let obj0Count = try WOCContainerParser.leadingCount(obj0.payload)
        XCTAssertEqual(obj0Count, 41)

        let inst = try XCTUnwrap(file.sections.first { $0.tag == "INST" })
        let instances = try WOCContainerParser.parseInstances(inst.payload)
        XCTAssertEqual(instances.count, 41)
        XCTAssertEqual(Set(instances.map(\.objectIndex)), Set(0..<UInt32(obj0Count)))

        let spec = try XCTUnwrap(file.sections.first { $0.tag == "SPEC" })
        let specRecords = try WOCContainerParser.parseSpecRecords(spec.payload)
        XCTAssertEqual(specRecords.count, 5)
        for record in specRecords {
            let referenced = instances[Int(record.referencedInstanceIndex)]
            XCTAssertTrue(matricesEqual(record.matrix, referenced.matrix))
        }

        let tst0 = try XCTUnwrap(file.sections.first { $0.tag == "TST0" })
        let textures = WOCContainerParser.scanTextureEntries(tst0.payload)
        XCTAssertFalse(textures.isEmpty)
        XCTAssertEqual(textures[0].width, 128)
        XCTAssertEqual(textures[0].height, 64)
    }

    /// Tests that the updated scanTextureEntries function correctly finds
    /// texture entries by advancing 4 bytes after each candidate, ensuring
    /// that all marker==76 positions are checked.
    func testScanTextureEntriesFindsAllMarkerPositions() throws {
        // Create a mock TST0 payload with texture entries
        // TST0 format: [16-byte header][texture entry 1][texture entry 2]...
        // Texture entry format: [20-byte trailer][172-byte header][size-byte texel data]
        // Trailer ends with marker==76 at its last 4 bytes

        var payload = [UInt8](repeating: 0, count: 16) // 16-byte TST0 header (count, reserved, word2, word3)

        // Add first texture entry
        // Trailer: [sizePlus, size, fmtA, fmtB, marker==76]
        let size1 = 64  // 8x8 texture with 1 byte per pixel
        let sizePlus1 = UInt32(size1) + 0xC4  // size + 0xC4
        let fmtA1 = 1   // indexed texture
        let fmtB1 = 1   // indexed texture
        let marker1: [UInt8] = [76, 0, 0, 0]  // marker==76 (little-endian)

        var trailer1 = [UInt8]()
        trailer1.append(contentsOf: withUnsafeBytes(of: sizePlus1.littleEndian) { Array($0) })
        trailer1.append(contentsOf: withUnsafeBytes(of: UInt32(size1).littleEndian) { Array($0) })
        trailer1.append(contentsOf: withUnsafeBytes(of: UInt32(fmtA1).littleEndian) { Array($0) })
        trailer1.append(contentsOf: withUnsafeBytes(of: UInt32(fmtB1).littleEndian) { Array($0) })
        trailer1.append(contentsOf: marker1)

        // Header: 172 bytes
        // We need to set up the header so that:
        // - Width is at headerStart + 124 (byte 124 of header)
        // - Height is at headerStart + 128 (byte 128 of header)
        // For our 8x8 texture:
        var header1 = [UInt8](repeating: 0, count: 172)
        header1.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(8).littleEndian, toByteOffset: 124, as: UInt32.self)
            ptr.storeBytes(of: UInt32(8).littleEndian, toByteOffset: 128, as: UInt32.self)
        }

        // Texel data: size1 bytes
        let texelData1 = [UInt8](repeating: 42, count: size1)  // arbitrary data

        payload.append(contentsOf: trailer1)
        payload.append(contentsOf: header1)
        payload.append(contentsOf: texelData1)

        // Add second texture entry with some filler/data between entries
        // This tests that we don't skip over markers in filler/header regions
        let fillerBetweenEntries = [UInt8](repeating: 0, count: 32)  // some filler/data

        // Second texture entry
        let size2 = 256  // 16x16 texture with 1 byte per pixel (total 256 bytes)
        let sizePlus2 = UInt32(size2) + 0xC4  // size + 0xC4
        let fmtA2 = 4    // direct-color texture
        let fmtB2 = 2    // direct-color texture (fmtA == 2*fmtB)
        let marker2: [UInt8] = [76, 0, 0, 0]  // marker==76 (little-endian)

        var trailer2 = [UInt8]()
        trailer2.append(contentsOf: withUnsafeBytes(of: sizePlus2.littleEndian) { Array($0) })
        trailer2.append(contentsOf: withUnsafeBytes(of: UInt32(size2).littleEndian) { Array($0) })
        trailer2.append(contentsOf: withUnsafeBytes(of: UInt32(fmtA2).littleEndian) { Array($0) })
        trailer2.append(contentsOf: withUnsafeBytes(of: UInt32(fmtB2).littleEndian) { Array($0) })
        trailer2.append(contentsOf: marker2)

        // Header: 172 bytes
        // Set width to 16, height to 16 for our 16x16 texture
        var header2 = [UInt8](repeating: 0, count: 172)
        header2.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: UInt32(16).littleEndian, toByteOffset: 124, as: UInt32.self)
            ptr.storeBytes(of: UInt32(16).littleEndian, toByteOffset: 128, as: UInt32.self)
        }

        // Texel data: size2 bytes
        let texelData2 = [UInt8](repeating: 128, count: size2)  // arbitrary data

        payload.append(contentsOf: fillerBetweenEntries)
        payload.append(contentsOf: trailer2)
        payload.append(contentsOf: header2)
        payload.append(contentsOf: texelData2)

        // Convert to Data
        let payloadData = Data(payload)

        // Scan for texture entries
        let entries = WOCContainerParser.scanTextureEntries(payloadData)

        // We should find exactly 2 texture entries
        XCTAssertEqual(entries.count, 2, "Should find 2 texture entries")

        // Verify first entry
        XCTAssertEqual(entries[0].width, 8, "First texture width should be 8")
        XCTAssertEqual(entries[0].height, 8, "First texture height should be 8")
        XCTAssertEqual(entries[0].bytesPerPixel, 1, "First texture should be indexed (1 byte per pixel)")
        XCTAssertEqual(entries[0].texelDataRange.count, size1, "First texture should have correct texel data size")

        // Verify second entry
        XCTAssertEqual(entries[1].width, 16, "Second texture width should be 16")
        XCTAssertEqual(entries[1].height, 16, "Second texture height should be 16")
        XCTAssertEqual(entries[1].bytesPerPixel, 4, "Second texture should be direct-color (4 bytes per pixel)")
        XCTAssertEqual(entries[1].texelDataRange.count, size2, "Second texture should have correct texel data size")
    }
}
