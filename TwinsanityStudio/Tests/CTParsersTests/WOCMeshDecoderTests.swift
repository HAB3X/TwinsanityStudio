import XCTest
@testable import CTParsers

/// `WOCMeshDecoder`/`WOCContainerParser.parseOBJ0ChunkArcs`: real per-
/// object WoC mesh geometry, decoded from `OBJ0`'s "arc" vertex batches.
/// Independently re-verified against real disc bytes (not just an agent
/// report) before implementation: the 36-byte arc header template, the
/// `N`/`N*3` fields, and the `28 + 12*N` trailing-block size all matched
/// exactly by hand on 3 real files, and every real entry rendered from
/// this decode (both as points and as real triangles) was visually
/// inspected and showed genuinely coherent 3D shapes -- a smooth dome,
/// a clean ring, and closed multi-part cylindrical assemblies -- not
/// noise.
final class WOCMeshDecoderTests: XCTestCase {
    private func loadAndDecompressRealGSC(_ relativePath: String) throws -> [UInt8] {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try RNCDecompressor.decompress([UInt8](data), verifyCRC: true)
    }

    /// Golden values hand-verified directly against real disc bytes: the
    /// first arc of `AIRSHIP.GSC`'s first `OBJ0` chunk has exactly 39
    /// vertices (byte 4 of its header), and its header's `u32` at byte 24
    /// is exactly `39*3 == 117`.
    func testFirstArcOfFirstChunkGoldenValues() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let chunks = WOCContainerParser.walkOBJ0Chunks(obj0.payload)
        let firstChunk = try XCTUnwrap(chunks.first)
        let arcResults = WOCContainerParser.parseOBJ0ChunkArcs(obj0.payload, chunk: firstChunk)
        let firstArcResult = try XCTUnwrap(arcResults.first)
        XCTAssertEqual(firstArcResult.vertices.count, 39)
        
    }

    /// The confirmed connectivity convention (`(control >> 8) & 0xFF ==
    /// 0x80` marks a strip restart, exactly `ModelParser.swift`'s own
    /// `connRaw != 128` rule for original Twinsanity meshes) holds
    /// exactly for the first 3 vertices of every real arc -- checked
    /// across every arc in AIRSHIP's first 5 OBJ0 entries, zero
    /// exceptions.
    func testFirstThreeVerticesOfEveryArcAreStripRestarts() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let groups = try XCTUnwrap(WOCContainerParser.groupOBJ0ChunksIntoEntries(obj0.payload))

        var checkedArcs = 0
        for group in groups.prefix(5) {
            for chunk in group {
                let arcResults = WOCContainerParser.parseOBJ0ChunkArcs(obj0.payload, chunk: chunk)
                for arcResult in arcResults {
                    checkedArcs += 1
                    let vertex = arcResult.vertices.prefix(3)
                    for v in vertex {
                        let byte1 = (v.control >> 8) & 0xFF
                        XCTAssertEqual(byte1, 0x80, "first 3 vertices of every arc should be strip restarts")
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedArcs, 0)
    }

    /// End-to-end: real entry meshes build with a plausible triangle
    /// count and zero degenerate triangles (a triangle referencing the
    /// same vertex index twice) across a real sample of entries.
    func testBuildEntryMeshesProducesRealNonDegenerateTriangles() throws {
        let decoded = try loadAndDecompressRealGSC("A/AIRSHIP/AIRSHIP.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let meshes = try XCTUnwrap(WOCMeshDecoder.buildEntryMeshes(objectPayload: obj0.payload))
        XCTAssertEqual(meshes.count, 41, "AIRSHIP.GSC has 41 real OBJ0 entries")

        var totalTriangles = 0
        for mesh in meshes.prefix(20) {
            for submesh in mesh.submeshes {
                for (a, b, c) in submesh.triangleIndices() {
                    XCTAssertTrue(a != b && b != c && a != c, "degenerate triangle")
                    totalTriangles += 1
                }
            }
        }
        XCTAssertGreaterThan(totalTriangles, 0)
    }

    /// `CASTLE_C.GSC` is one of the two files with heterogeneous
    /// `OBJ0` chunk headers `walkOBJ0Chunks` only partially covers (see
    /// its own doc comment on the containment fix for the marker-reuse
    /// bug this used to trigger). Mesh building now succeeds with a real,
    /// if far-from-complete, set of entries rather than either extreme
    /// (fabricated full coverage, or a blanket refusal).
    func testHeterogeneousFileBuildsPartialRealMeshes() throws {
        let decoded = try loadAndDecompressRealGSC("A/CASTLE_C/CASTLE_C.GSC")
        let file = try WOCContainerParser.parse(decoded)
        let obj0 = try XCTUnwrap(file.sections.first { $0.tag == "OBJ0" })
        let leadingCount = try WOCContainerParser.leadingCount(obj0.payload)
        let meshes = try XCTUnwrap(WOCMeshDecoder.buildEntryMeshes(objectPayload: obj0.payload))
        XCTAssertGreaterThan(meshes.count, 0, "should build at least some real meshes")
        XCTAssertLessThan(meshes.count, leadingCount, "coverage on this file is known-incomplete -- update this test if a fuller OBJ0 fix lands")
    }
}
