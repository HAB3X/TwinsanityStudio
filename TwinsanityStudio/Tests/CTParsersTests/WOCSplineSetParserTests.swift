import XCTest
@testable import CTParsers

/// `WOCSplineSetParser` -- decodes `.GSC`'s `SST0` (real handler:
/// `ReadNuIFFGSplineSet`). See `SST0_Spec.md` and this parser's own doc
/// comment for the investigation history. These tests independently
/// re-verify the confirmed structure directly against real disc bytes.
final class WOCSplineSetParserTests: XCTestCase {
    private func loadDecodedContainer(_ relativePath: String) throws -> WOCContainerParser.File {
        let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Real WoC disc image not mounted -- see WOCContainerParserTests for how to mount it")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bytes = [UInt8](data)
        let decoded = RNCDecompressor.isRNCStream(bytes) ? try RNCDecompressor.decompress(bytes, verifyCRC: true) : bytes
        return try WOCContainerParser.parse(decoded)
    }

    /// Golden-value regression, hand-verified against real bytes:
    /// `FARM.GSC`'s `SST0` blob is exactly 68 bytes, `numSplines=1`. The
    /// real bytes (`05 00 00 00 8e 00 00 00 ...`) decode to `len=5`,
    /// `nameOffset=142` -- and `5*12 + 8 == 68` exactly, the byte-exact
    /// fit that confirmed this parser's real record shape.
    func testRealFarmGoldenValues() throws {
        let file = try loadDecodedContainer("A/FARM/FARM.GSC")
        let sst0 = try XCTUnwrap(file.sections.first { $0.tag == "SST0" })
        let spline = try WOCSplineSetParser.parse(sst0.payload)

        XCTAssertEqual(spline.numSplines, 1)
        XCTAssertEqual(spline.splines.count, 1)
        XCTAssertEqual(spline.splines[0].points.count, 5)
        XCTAssertEqual(spline.splines[0].nameOffset, 142)
    }

    /// Full-corpus regression: every real `SST0` blob should parse with
    /// EXACT byte consumption (the `numSplines`-many records, each
    /// `8 + len*12` bytes, sum to exactly `blob.count` with zero
    /// leftover) -- the same bar this codebase's other "confirmed by
    /// exact byte consumption" decoders are held to.
    func testEveryRealSST0BlobConsumesExactly() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: "/Volumes/CRASH/LEVELS") else {
            throw XCTSkip("Real WoC disc image not mounted")
        }
        var allGSC: [String] = []
        for case let p as String in enumerator where p.uppercased().hasSuffix(".GSC") {
            allGSC.append(p)
        }
        guard !allGSC.isEmpty else {
            throw XCTSkip("Real WoC disc image not mounted")
        }

        var checked = 0
        for relativePath in allGSC.sorted() {
            let path = "/Volumes/CRASH/LEVELS/\(relativePath)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            let bytes = [UInt8](data)
            let decoded = RNCDecompressor.isRNCStream(bytes) ? ((try? RNCDecompressor.decompress(bytes, verifyCRC: true)) ?? bytes) : bytes
            guard let file = try? WOCContainerParser.parse(decoded) else { continue }
            guard let sst0 = file.sections.first(where: { $0.tag == "SST0" }) else { continue }
            let (numSplines, blob, _) = try WOCContainerParser.parseFooterHeader(sst0.payload)
            guard numSplines > 0, !blob.isEmpty else { continue }

            let parsed = try WOCSplineSetParser.parse(sst0.payload)
            XCTAssertEqual(parsed.splines.count, Int(numSplines), "\(relativePath): should decode exactly numSplines records")
            let consumed = parsed.splines.reduce(0) { $0 + 8 + $1.points.count * 12 }
            XCTAssertEqual(consumed, blob.count, "\(relativePath): records should consume the blob exactly")
            for spline in parsed.splines {
                for point in spline.points {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite && point.z.isFinite, "\(relativePath): every point should be a real finite value")
                }
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30, "expected close to the full real 41-file SST0 corpus")
    }
}
